import Foundation

/// Minimal zstd CLI wrapper. dsh (DeepSeek Harness) session logs are
/// zstd-compressed JSONL (`~/.dsh/sessions/**/session.jsonl.zstd`) and Apple's
/// Compression framework has no zstd codec, so we shell out to the zstd binary —
/// same pattern as Auth.swift's /usr/bin/security. The LaunchAgent environment
/// has a minimal PATH, so well-known Homebrew locations are tried first.
enum Zstd {
    private static let candidates = [
        "/opt/homebrew/bin/zstd", // Apple Silicon Homebrew
        "/usr/local/bin/zstd",    // Intel Homebrew
        "/opt/local/bin/zstd",    // MacPorts
    ]

    /// Decompress a .zstd file to a UTF-8 string; nil on any failure
    /// (missing binary, truncated/partial file, invalid frame).
    static func decompress(_ url: URL) -> String? {
        guard let exe = executable() else { return nil }
        // Write to a temp file instead of a pipe: the decompressed JSONL can be
        // several MB, which would fill the 64 KB pipe buffer and deadlock.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hmusage-\(UUID().uuidString).jsonl")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else { return nil }

        let process = Process()
        process.executableURL = exe
        process.arguments = ["-d", "-c", url.path]
        guard let out = try? FileHandle(forWritingTo: tmp) else {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
        process.waitUntilExit()
        try? out.close()

        let text = try? String(contentsOf: tmp, encoding: .utf8)
        try? FileManager.default.removeItem(at: tmp)
        return text
    }

    private static func executable() -> URL? {
        let fm = FileManager.default
        if let p = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: p)
        }
        // Fall back to PATH (interactive terminals / --once runs).
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("zstd")
                if fm.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}
