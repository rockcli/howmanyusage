import Foundation
import Testing
@testable import HowManyUsage

struct ClaudeQuotaTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let account = "11111111-1111-1111-1111-111111111111"
    private let org = "22222222-2222-2222-2222-222222222222"
    private let client = "33333333-3333-3333-3333-333333333333"

    private func key(account: String? = nil, org: String? = nil,
                     scopes: String = "user:inference user:file_upload user:profile") -> String {
        "acct:\(account ?? self.account)|\(client):\(org ?? self.org):https://api.anthropic.com:\(scopes)"
    }

    private func entry(token: String = "fixture-desktop", expiresIn: TimeInterval = 3600) -> [String: Any] {
        ["token": token, "expiresAt": now.addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000,
         "subscriptionType": "pro"]
    }

    private func credential(_ source: ClaudeQuotaSource, expiresIn: TimeInterval = 3600) -> ClaudeQuotaCredential {
        ClaudeQuotaCredential(source: source, accessToken: "fixture-\(source.rawValue)",
            expiresAt: now.addingTimeInterval(expiresIn), subscriptionType: "pro", rateLimitTier: nil)
    }

    @Test func decryptsKnownChromiumFixtureAndRejectsWrongKeyOrFormat() throws {
        // Independent OpenSSL AES-CBC fixture; contains no real credential.
        let encrypted = try #require(Data(base64Encoded: "djEwbT+geJQA17fdhUZj/xbbHQ84kj4N+cbv06BqLsHJ2ho="))
        let plain = try ClaudeDesktopAuth.decrypt(encrypted, password: "fixture-password")
        #expect(String(data: plain, encoding: .utf8) == #"{"fixture":true}"#)
        // CBC padding alone cannot authenticate a key; cache loading also requires valid JSON.
        #expect(throws: (any Error).self) {
            try JSONSerialization.jsonObject(with: ClaudeDesktopAuth.decrypt(encrypted, password: "wrong"))
        }
        #expect(throws: AuthError.self) { try ClaudeDesktopAuth.decrypt(Data("v20unsupported".utf8), password: "fixture-password") }
    }

    @Test func desktopUsesActiveAccountBaseScopeWithoutRefreshToken() throws {
        let cache: [String: Any] = [
            key(): entry(),
            key(scopes: "user:inference user:file_upload user:profile user:sessions:claude_code"):
                entry(token: "code-tab", expiresIn: 7200),
            key(account: "44444444-4444-4444-4444-444444444444"): entry(token: "other-account"),
        ]
        let result = try ClaudeDesktopAuth.select(cache: cache, account: account, now: now)
        #expect(result.accessToken == "fixture-desktop")
        #expect(result.subscriptionType == "pro")
    }

    @Test func desktopRejectsExpiredWrongScopeWrongHostAndAmbiguousOrganization() {
        let invalid: [[String: Any]] = [
            [key(): entry(expiresIn: -1)],
            [key(): NSNull()],
            [key(scopes: "user:profile"): entry()],
            [key().replacingOccurrences(of: "https://api.anthropic.com", with: "https://other.invalid"): entry()],
            [key(): entry(), key(org: "55555555-5555-5555-5555-555555555555"): entry()],
        ]
        for cache in invalid {
            #expect(throws: AuthError.self) { try ClaudeDesktopAuth.select(cache: cache, account: account, now: now) }
        }
    }

    @Test func desktopCanSupplyQuotaWhileCliIsExpired() async throws {
        var loaded: [ClaudeQuotaSource] = []
        let result = try await ClaudeQuota.fetch(now: now, load: { source in
            loaded.append(source)
            return credential(source, expiresIn: source == .desktop ? 3600 : -1)
        }, request: { _ in ["seven_day": ["utilization": 83]] })
        #expect(result.credential.source == .desktop)
        #expect(loaded == [.desktop])
    }

    @Test func cliSuppliesQuotaWhenDesktopMissingExpiredOrRejected() async throws {
        for desktopState in ["missing", "expired", "rejected401", "rejected403"] {
            var requested: [ClaudeQuotaSource] = []
            let result = try await ClaudeQuota.fetch(now: now, load: { source in
                if source == .desktop, desktopState == "missing" { throw AuthError("fixture missing") }
                return credential(source, expiresIn: source == .desktop && desktopState == "expired" ? -1 : 3600)
            }, request: { credential in
                requested.append(credential.source)
                if credential.source == .desktop {
                    throw ClaudeQuota.HTTPError(status: desktopState == "rejected403" ? 403 : 401)
                }
                return ["seven_day": ["utilization": 83]]
            })
            #expect(result.credential.source == .cli)
            #expect(requested == (desktopState.hasPrefix("rejected") ? [.desktop, .cli] : [.cli]))
        }
    }

    @Test func rateLimitAndNetworkFailureDoNotTryAnotherCredential() async throws {
        for status in [429, 503] {
            var loaded: [ClaudeQuotaSource] = []
            do {
                _ = try await ClaudeQuota.fetch(now: now, load: { source in
                    loaded.append(source)
                    return credential(source)
                }, request: { _ in throw ClaudeQuota.HTTPError(status: status) })
                Issue.record("Expected HTTP error")
            } catch let error as ClaudeQuota.HTTPError { #expect(error.status == status) }
            #expect(loaded == [.desktop])
        }
        var requested = 0
        do {
            _ = try await ClaudeQuota.fetch(now: now, load: { credential($0) }, request: { _ in
                requested += 1
                throw URLError(.timedOut)
            })
            Issue.record("Expected timeout")
        } catch let error as URLError { #expect(error.code == .timedOut) }
        #expect(requested == 1)
    }

    @Test func expiredCredentialsNeverIssueRequestOrDemandSignIn() async {
        do {
            _ = try await ClaudeQuota.fetch(now: now, load: { credential($0, expiresIn: -1) }, request: { _ in
                Issue.record("Expired credentials must not be sent")
                return [:]
            })
            Issue.record("Expected unavailable credential")
        } catch {
            #expect(error.localizedDescription.contains("sign-in may still be valid"))
            #expect(!error.localizedDescription.contains("refresh Claude Code sign-in"))
        }
    }
}
