import Foundation

/// Only locally observed statusline deltas. No API requests or transcript byte estimates.
enum ClaudeSpeed {
    static func samples(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/howmanyusage/claude-speed"), now: Date) -> [CodexSpeed.Sample] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return files.filter { $0.pathExtension == "json" }.flatMap { file -> [CodexSpeed.Sample] in
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) < 14400,
                  let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = object["samples"] as? [[String: Any]] else { return [] }
            return rows.compactMap { row in
                guard let id = row["id"] as? String, let model = row["model"] as? String,
                      model.hasPrefix("claude-"), let tokens = row["tokens"] as? Int, tokens > 0,
                      let seconds = row["seconds"] as? Double, (0.5...2).contains(seconds),
                      let timestamp = row["timestamp"] as? Double, timestamp.isFinite else { return nil }
                let date = Date(timeIntervalSince1970: timestamp)
                guard (0...14400).contains(now.timeIntervalSince(date)) else { return nil }
                return CodexSpeed.Sample(responseID: id, model: model, effort: "unknown effort",
                    outputTokens: tokens, seconds: seconds, completedAt: date, outputSeconds: seconds)
            }
        }
    }
}
