import Foundation
import Testing
@testable import HowManyUsage

struct ProviderDetectionTests {
    private func makeTempEnv() throws -> (root: URL, home: URL, apps: URL, bin: URL, env: ProviderDetection.Environment) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("howmanyusage-detect-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let env = ProviderDetection.Environment(
            home: home,
            applicationDirs: [apps],
            binDirs: [bin],
            env: [:]
        )
        return (root, home, apps, bin, env)
    }

    private func makeExecutable(_ name: String, in bin: URL) throws {
        let url = bin.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func touchFile(_ rel: String, in home: URL, contents: String = "{}") throws {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func makeApp(_ name: String, in apps: URL) throws {
        let url = apps.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @Test func emptyMachineDetectsNoProviders() throws {
        let tmp = try makeTempEnv()
        defer { try? FileManager.default.removeItem(at: tmp.root) }
        #expect(ProviderDetection.installedProviders(in: tmp.env).isEmpty)
    }

    @Test func detectsCodexViaCLIAppOrConfig() throws {
        for mode in ["cli", "app", "auth"] {
            let tmp = try makeTempEnv()
            defer { try? FileManager.default.removeItem(at: tmp.root) }
            switch mode {
            case "cli": try makeExecutable("codex", in: tmp.bin)
            case "app": try makeApp("Codex.app", in: tmp.apps)
            default: try touchFile(".codex/auth.json", in: tmp.home)
            }
            #expect(ProviderDetection.installedProviders(in: tmp.env) == ["codex"])
        }
    }

    @Test func detectsClaudeViaCLIDesktopOrCredentials() throws {
        for mode in ["cli", "app", "desktopConfig", "cliCreds"] {
            let tmp = try makeTempEnv()
            defer { try? FileManager.default.removeItem(at: tmp.root) }
            switch mode {
            case "cli": try makeExecutable("claude", in: tmp.bin)
            case "app": try makeApp("Claude.app", in: tmp.apps)
            case "desktopConfig": try touchFile("Library/Application Support/Claude/config.json", in: tmp.home)
            default: try touchFile(".claude/.credentials.json", in: tmp.home)
            }
            #expect(ProviderDetection.installedProviders(in: tmp.env) == ["claude"])
        }
    }

    @Test func detectsAntigravityViaCLIDesktopOrDataDir() throws {
        for mode in ["agy", "app", "daemonDir"] {
            let tmp = try makeTempEnv()
            defer { try? FileManager.default.removeItem(at: tmp.root) }
            switch mode {
            case "agy": try makeExecutable("agy", in: tmp.bin)
            case "app": try makeApp("Antigravity.app", in: tmp.apps)
            default:
                try FileManager.default.createDirectory(
                    at: tmp.home.appendingPathComponent(".gemini/antigravity", isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            #expect(ProviderDetection.installedProviders(in: tmp.env) == ["antigravity"])
        }
    }

    @Test func detectsDeepSeekViaEnvShellRCOrHarness() throws {
        for mode in ["env", "zshrc", "dsh", "pi", "app"] {
            let tmp = try makeTempEnv()
            defer { try? FileManager.default.removeItem(at: tmp.root) }
            var env = tmp.env
            switch mode {
            case "env":
                env = ProviderDetection.Environment(
                    home: tmp.home, applicationDirs: [tmp.apps], binDirs: [tmp.bin],
                    env: ["DEEPSEEK_API_KEY": "sk-12345678901234567890"]
                )
            case "zshrc":
                try touchFile(".zshrc", in: tmp.home, contents: "export DEEPSEEK_API_KEY=\"sk-12345678901234567890\"\n")
            case "dsh": try makeExecutable("dsh", in: tmp.bin)
            case "pi": try makeExecutable("pi", in: tmp.bin)
            default: try makeApp("DeepSeek.app", in: tmp.apps)
            }
            #expect(ProviderDetection.installedProviders(in: env) == ["deepseek"])
        }
    }

    @Test func detectsColabViaSkillCLIOrToken() throws {
        for mode in ["agentsSkill", "claudeSkill", "geminiSkill", "cli", "token"] {
            let tmp = try makeTempEnv()
            defer { try? FileManager.default.removeItem(at: tmp.root) }
            switch mode {
            case "agentsSkill": try touchFile(".agents/skills/colab-operator/SKILL.md", in: tmp.home, contents: "# colab")
            case "claudeSkill": try touchFile(".claude/skills/colab-operator/SKILL.md", in: tmp.home, contents: "# colab")
            case "geminiSkill": try touchFile(".gemini/config/skills/colab-operator/SKILL.md", in: tmp.home, contents: "# colab")
            case "cli": try makeExecutable("colab", in: tmp.bin)
            default: try touchFile(".config/colab-cli/token.json", in: tmp.home)
            }
            #expect(ProviderDetection.installedProviders(in: tmp.env) == ["colab"])
        }
    }

    @Test func fetchAllHonorsOnlyFilterAndPreservesOrder() async {
        let empty = await Providers.fetchAll(only: [], skip: Set(ProviderDetection.allProviderIDs))
        #expect(empty.isEmpty)

        let subset = await Providers.fetchAll(
            only: ["colab", "claude"],
            skip: Set(ProviderDetection.allProviderIDs)
        )
        #expect(subset.map(\.id) == ["claude", "colab"])
    }
}
