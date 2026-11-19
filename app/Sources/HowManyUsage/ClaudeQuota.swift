import Foundation

enum ClaudeQuota {
    struct HTTPError: LocalizedError {
        let status: Int
        var errorDescription: String? { "Claude quota HTTP \(status)" }
    }

    /// Read either client's existing credential; never renew credentials on its behalf.
    static func fetch(
        sources: [ClaudeQuotaSource] = [.desktop, .cli],
        now: Date = Date(),
        load: (ClaudeQuotaSource) throws -> ClaudeQuotaCredential = ClaudeQuotaCredential.load,
        request: (ClaudeQuotaCredential) async throws -> [String: Any] = Providers.requestClaudeQuota
    ) async throws -> (data: [String: Any], credential: ClaudeQuotaCredential) {
        for source in sources {
            guard let credential = try? load(source),
                  credential.expiresAt.timeIntervalSince(now) > 60 else { continue }
            do {
                let data = try await request(credential)
                return (data, credential)
            } catch let error as HTTPError where error.status == 401 || error.status == 403 {
                // Revoked/missing scope: another client's valid login can still serve usage.
                continue
            }
            // Network errors and 429 propagate; switching credentials must not bypass backoff.
        }
        throw AuthError("Claude quota credential unavailable; open Desktop or use the CLI for automatic renewal. Your sign-in may still be valid.")
    }
}
