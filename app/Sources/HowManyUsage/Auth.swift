import Foundation

/// Claude Code OAuth credentials (stored in the macOS keychain as "Claude Code-credentials")
struct ClaudeOAuthTokens {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let refreshTokenExpiresAt: Date?
    let scopes: [String]?
    let subscriptionType: String?
    let rateLimitTier: String?

    /// Remaining validity; refresh well before expiry
    var expiresIn: TimeInterval { expiresAt.timeIntervalSinceNow }
}

/// Credential discovery: reuse the login state of each CLI
enum Auth {
    struct CodexAuth {
        let accessToken: String
        let accountId: String?
    }

    /// Codex: ~/.codex/auth.json
    static func codex() throws -> CodexAuth {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        let data = try Data(contentsOf: url)
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = obj["tokens"] as? [String: Any],
            let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty
        else {
            throw AuthError("~/.codex/auth.json is missing access_token; run `codex login` first")
        }
        return CodexAuth(accessToken: accessToken, accountId: tokens["account_id"] as? String)
    }

    /// Claude Code CLI: macOS keychain OAuth credentials, with its documented
    /// ~/.claude/.credentials.json fallback when Keychain cannot be written.
    /// Read/write via the /usr/bin/security CLI (same as Claude Code itself):
    /// the CLI is trusted by the keychain and never triggers ACL prompts;
    /// calling the Security framework directly does.
    static let claudeKeychainService = "Claude Code-credentials"
    static let claudeOAuthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let claudeOAuthBeta = "oauth-2025-04-20"

    static func claudeTokens() throws -> ClaudeOAuthTokens {
        let raw: String
        if let keychain = try? securityCLI(["find-generic-password", "-s", claudeKeychainService, "-w"]) {
            raw = keychain
        } else {
            let file = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json")
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let mode = attributes[.posixPermissions] as? NSNumber,
                  mode.intValue & 0o077 == 0,
                  let saved = try? String(contentsOf: file, encoding: .utf8) else {
                throw AuthError("Claude quota credential unavailable from Keychain or the CLI fallback file; check Claude Code sign-in. Local Desktop session stats still work.")
            }
            raw = saved
        }
        return try parseClaudeTokens(raw)
    }

    static func parseClaudeTokens(_ raw: String) throws -> ClaudeOAuthTokens {
        guard
            let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
            let oauth = obj["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty,
            let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty
        else {
            throw AuthError("Claude quota credential has no usable OAuth tokens; check Claude Code sign-in")
        }
        let parseDate = { (key: String) -> Date? in
            (oauth[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }
        return ClaudeOAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: parseDate("expiresAt") ?? .distantPast,
            refreshTokenExpiresAt: parseDate("refreshTokenExpiresAt"),
            scopes: oauth["scopes"] as? [String],
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }

    /// Run a security command and return stdout; runs on a background queue to avoid blocking the main thread
    static func securityCLI(_ args: [String]) throws -> String {
        try DispatchQueue.global().sync {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            try process.run()
            process.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw AuthError("security command failed: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return out
        }
    }

    /// DeepSeek: DEEPSEEK_API_KEY env var, or its export in ~/.zshrc (LaunchAgent processes have no shell env)
    static func deepSeek() throws -> String {
        if let env = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !env.isEmpty {
            return env
        }
        let zshrc = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
        if let text = try? String(contentsOf: zshrc, encoding: .utf8) {
            let pattern = #"DEEPSEEK_API_KEY\s*=\s*["']?([A-Za-z0-9_-]{20,})["']?"#
            if let range = text.range(of: pattern, options: .regularExpression) {
                let line = text[range]
                let keyPattern = #"[A-Za-z0-9_-]{20,}"#
                if let k = line.range(of: keyPattern, options: .regularExpression) {
                    let key = String(line[k])
                    if !key.isEmpty { return key }
                }
            }
        }
        throw AuthError("No DeepSeek API key (DEEPSEEK_API_KEY or ~/.zshrc); get one at https://platform.deepseek.com")
    }

    struct ColabAuth: Sendable {
        let accessToken: String?
        let refreshToken: String?
        let tokenURI: String
        let clientID: String?
        let clientSecret: String?
        let expiresAt: Date?
    }

    /// Google Colab CLI: ~/.config/colab-cli/token.json
    static func colab(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> ColabAuth {
        let url = home.appendingPathComponent(".config/colab-cli/token.json")
        guard let data = try? Data(contentsOf: url) else {
            throw AuthError("~/.config/colab-cli/token.json not found; run `colab usage` first")
        }
        return try parseColabAuth(data)
    }

    static func parseColabAuth(_ data: Data) throws -> ColabAuth {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError("~/.config/colab-cli/token.json is invalid JSON")
        }
        let accessToken = (obj["token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let refreshToken = (obj["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard accessToken != nil || refreshToken != nil else {
            throw AuthError("~/.config/colab-cli/token.json has no usable OAuth token")
        }
        let tokenURI = (obj["token_uri"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "https://oauth2.googleapis.com/token"
        let clientID = (obj["client_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let clientSecret = (obj["client_secret"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var expiresAt: Date?
        if let expiry = obj["expiry"] as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            expiresAt = fractional.date(from: expiry) ?? plain.date(from: expiry)
        }
        return ColabAuth(
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenURI: tokenURI,
            clientID: clientID,
            clientSecret: clientSecret,
            expiresAt: expiresAt
        )
    }

}

struct AuthError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
