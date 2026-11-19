import CommonCrypto
import Foundation

enum ClaudeQuotaSource: String, CaseIterable {
    case desktop = "Desktop"
    case cli = "CLI"
}

/// Access tokens only: quota reads never need to retain or rotate refresh tokens.
struct ClaudeQuotaCredential {
    let source: ClaudeQuotaSource
    let accessToken: String
    let expiresAt: Date
    let subscriptionType: String?
    let rateLimitTier: String?

    static func load(_ source: ClaudeQuotaSource) throws -> Self {
        if source == .desktop { return try ClaudeDesktopAuth.credential() }
        let tokens = try Auth.claudeTokens()
        return Self(source: .cli, accessToken: tokens.accessToken, expiresAt: tokens.expiresAt,
                    subscriptionType: tokens.subscriptionType, rateLimitTier: tokens.rateLimitTier)
    }
}

/// Read Desktop's Electron safeStorage OAuth cache without changing its login state.
enum ClaudeDesktopAuth {
    static func credential() throws -> ClaudeQuotaCredential {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/config.json")
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] ?? [:]
        guard let account = config["lastKnownAccountUuid"] as? String,
              UUID(uuidString: account) != nil,
              // V2 is authoritative, including tombstones. Never resurrect a V1 entry.
              let raw = (config["oauth:tokenCacheV2"] ?? config["oauth:tokenCache"]) as? String,
              let encrypted = Data(base64Encoded: raw) else {
            throw AuthError("Desktop quota credential unavailable")
        }
        let password = try Auth.securityCLI([
            "find-generic-password", "-s", "Claude Safe Storage", "-w"
        ]).trimmingCharacters(in: .newlines)
        let data = try decrypt(encrypted, password: password)
        let cache = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return try select(cache: cache, account: account)
    }

    static func select(cache: [String: Any], account: String, now: Date = Date()) throws -> ClaudeQuotaCredential {
        var organizations = Set<String>()
        var candidates: [(credential: ClaudeQuotaCredential, codeScope: Bool)] = []
        for (key, value) in cache {
            let owner = key.components(separatedBy: "|")
            guard owner.count == 2, owner[0].lowercased() == "acct:\(account.lowercased())" else { continue }
            let parts = owner[1].components(separatedBy: ":https://api.anthropic.com:")
            guard parts.count == 2 else { continue }
            let identity = parts[0].components(separatedBy: ":")
            guard identity.count == 2, UUID(uuidString: identity[0]) != nil,
                  UUID(uuidString: identity[1]) != nil else { continue }
            let scopes = Set(parts[1].split(separator: " ").map(String.init))
            guard scopes.contains("user:inference"), scopes.contains("user:profile") else { continue }
            organizations.insert(identity[1].lowercased())
            guard let entry = value as? [String: Any],
                  let token = entry["token"] as? String, !token.isEmpty,
                  let expiry = entry["expiresAt"] as? Double, expiry.isFinite,
                  expiry / 1000 > now.timeIntervalSince1970 + 60 else { continue }
            candidates.append((ClaudeQuotaCredential(
                source: .desktop, accessToken: token, expiresAt: Date(timeIntervalSince1970: expiry / 1000),
                subscriptionType: entry["subscriptionType"] as? String,
                rateLimitTier: entry["rateLimitTier"] as? String
            ), scopes.contains("user:sessions:claude_code")))
        }
        // A persisted account can have several organizations; do not guess which quota to show.
        guard organizations.count == 1, !candidates.isEmpty else {
            throw AuthError("Desktop quota credential unavailable or organization ambiguous")
        }
        // Desktop itself prefers its base-scope credential over the Code-tab credential.
        candidates.sort {
            if $0.codeScope != $1.codeScope { return !$0.codeScope }
            return $0.credential.expiresAt > $1.credential.expiresAt
        }
        return candidates[0].credential
    }

    /// Chromium's macOS v10 safeStorage format: PBKDF2-SHA1 + AES-128-CBC.
    static func decrypt(_ encrypted: Data, password: String) throws -> Data {
        guard encrypted.starts(with: Data("v10".utf8)), encrypted.count > 3,
              (encrypted.count - 3) % kCCBlockSizeAES128 == 0, !password.isEmpty else {
            throw AuthError("Unsupported Desktop credential encryption")
        }
        let pass = Array(password.utf8), salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let derived = pass.withUnsafeBytes { pass in
            salt.withUnsafeBytes { salt in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    pass.baseAddress!.assumingMemoryBound(to: Int8.self), pass.count,
                    salt.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, kCCKeySizeAES128)
            }
        }
        guard derived == kCCSuccess else { throw AuthError("Desktop credential key derivation failed") }
        let payload = Data(encrypted.dropFirst(3)), iv = [UInt8](repeating: 32, count: kCCBlockSizeAES128)
        let capacity = payload.count + kCCBlockSizeAES128
        var plain = [UInt8](repeating: 0, count: capacity), count = 0
        let status = key.withUnsafeBytes { key in
            iv.withUnsafeBytes { iv in
                payload.withUnsafeBytes { bytes in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding), key.baseAddress, kCCKeySizeAES128,
                        iv.baseAddress, bytes.baseAddress, bytes.count, &plain, capacity, &count)
                }
            }
        }
        guard status == kCCSuccess else { throw AuthError("Desktop credential decryption failed") }
        return Data(plain.prefix(count))
    }
}
