import Foundation

/// Detects which supported AI providers are installed or configured on this machine.
/// Providers that have no local CLI, desktop app, skill, or credential/config footprint
/// are omitted from fetching and UI rendering so sharing the app never shows empty placeholders.
enum ProviderDetection {
    static let allProviderIDs: [String] = ["codex", "claude", "antigravity", "deepseek", "colab"]

    struct Environment {
        let home: URL
        let applicationDirs: [URL]
        let binDirs: [URL]
        let env: [String: String]

        static func live(
            home: URL = FileManager.default.homeDirectoryForCurrentUser,
            env: [String: String] = ProcessInfo.processInfo.environment
        ) -> Environment {
            let pathEntries = (env["PATH"] ?? "")
                .split(separator: ":")
                .map { URL(fileURLWithPath: String($0)) }
            // LaunchAgent processes inherit a minimal PATH, so always probe standard macOS install locations.
            let defaultBins = [
                URL(fileURLWithPath: "/opt/homebrew/bin"),
                URL(fileURLWithPath: "/usr/local/bin"),
                home.appendingPathComponent(".local/bin"),
                home.appendingPathComponent(".npm-global/bin"),
                home.appendingPathComponent(".bun/bin"),
                home.appendingPathComponent(".cargo/bin"),
                home.appendingPathComponent(".volta/bin"),
            ]
            var seen = Set<String>()
            var mergedBins: [URL] = []
            for dir in pathEntries + defaultBins {
                let path = dir.standardizedFileURL.path
                if seen.insert(path).inserted {
                    mergedBins.append(dir)
                }
            }
            return Environment(
                home: home,
                applicationDirs: [
                    URL(fileURLWithPath: "/Applications"),
                    home.appendingPathComponent("Applications"),
                ],
                binDirs: mergedBins,
                env: env
            )
        }
    }

    static func installedProviders(in env: Environment = .live()) -> Set<String> {
        var result = Set<String>()
        for id in allProviderIDs where isInstalled(id, in: env) {
            result.insert(id)
        }
        return result
    }

    static func isInstalled(_ id: String, in env: Environment = .live()) -> Bool {
        switch id {
        case "codex":
            return hasCodex(in: env)
        case "claude":
            return hasClaude(in: env)
        case "antigravity":
            return hasAntigravity(in: env)
        case "deepseek":
            return hasDeepSeek(in: env)
        case "colab":
            return hasColab(in: env)
        default:
            return false
        }
    }

    // MARK: - Per-provider detectors

    private static func hasCodex(in env: Environment) -> Bool {
        if hasExecutable("codex", in: env) { return true }
        if hasApp("Codex.app", in: env) { return true }
        return hasAnyRelativePath([
            ".codex/auth.json",
            ".codex/config.toml",
            ".codex/sessions",
            "Library/Application Support/Codex",
        ], in: env)
    }

    private static func hasClaude(in env: Environment) -> Bool {
        if hasExecutable("claude", in: env) { return true }
        if hasApp("Claude.app", in: env) { return true }
        return hasAnyRelativePath([
            ".claude/.credentials.json",
            ".claude/projects",
            ".claude/settings.json",
            ".claude.json",
            "Library/Application Support/Claude/config.json",
            "Library/Application Support/Claude",
        ], in: env)
    }

    private static func hasAntigravity(in env: Environment) -> Bool {
        if hasExecutable("agy", in: env) || hasExecutable("antigravity", in: env) { return true }
        if hasApp("Antigravity.app", in: env) { return true }
        return hasAnyRelativePath([
            ".gemini/antigravity",
            ".gemini/antigravity-ide",
            ".gemini/antigravity-cli",
            "Library/Application Support/Antigravity",
        ], in: env)
    }

    private static func hasDeepSeek(in env: Environment) -> Bool {
        if let key = env.env["DEEPSEEK_API_KEY"], !key.isEmpty { return true }
        if hasDeepSeekKeyInShellRC(in: env) { return true }
        if hasExecutable("dsh", in: env) || hasExecutable("pi", in: env) { return true }
        if hasApp("DeepSeek.app", in: env) { return true }
        return hasAnyRelativePath([
            ".dsh",
            ".pi",
        ], in: env)
    }

    private static func hasColab(in env: Environment) -> Bool {
        if hasExecutable("colab", in: env) { return true }
        return hasAnyRelativePath([
            ".config/colab-cli/token.json",
            ".config/colab-cli",
            // Agent skill installations for colab-operator
            ".agents/skills/colab-operator",
            ".claude/skills/colab-operator",
            ".codex/skills/colab-operator",
            ".gemini/config/skills/colab-operator",
            ".gemini/antigravity/skills/colab-operator",
            ".cursor/skills/colab-operator",
        ], in: env)
    }

    // MARK: - Filesystem helpers

    private static func hasExecutable(_ name: String, in env: Environment) -> Bool {
        let fm = FileManager.default
        for dir in env.binDirs {
            let candidate = dir.appendingPathComponent(name).path
            if fm.isExecutableFile(atPath: candidate) {
                return true
            }
        }
        return false
    }

    private static func hasApp(_ appName: String, in env: Environment) -> Bool {
        let fm = FileManager.default
        for dir in env.applicationDirs {
            let candidate = dir.appendingPathComponent(appName).path
            if fm.fileExists(atPath: candidate) {
                return true
            }
        }
        return false
    }

    private static func hasAnyRelativePath(_ paths: [String], in env: Environment) -> Bool {
        let fm = FileManager.default
        for rel in paths {
            let candidate = env.home.appendingPathComponent(rel).path
            if fm.fileExists(atPath: candidate) {
                return true
            }
        }
        return false
    }

    private static func hasDeepSeekKeyInShellRC(in env: Environment) -> Bool {
        let pattern = #"DEEPSEEK_API_KEY\s*=\s*["']?([A-Za-z0-9_-]{20,})["']?"#
        for rc in [".zshrc", ".zprofile", ".bashrc", ".bash_profile"] {
            let url = env.home.appendingPathComponent(rc)
            if let text = try? String(contentsOf: url, encoding: .utf8),
               text.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }
}
