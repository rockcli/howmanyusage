import Foundation

/// Copy bytes from an open descriptor: truncation/rotation cannot invalidate a mapping.
/// Invalid UTF-8/JSON is isolated to its own line; no transcript is ever changed.
enum LocalJSONL {
    static let maximumLineBytes = 8 * 1_048_576

    @discardableResult
    static func read(_ url: URL, matching: ((String) -> Bool)? = nil, handle: (String, [String: Any]) -> Void) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        var pending = Data()
        var discarding = false
        func emit() {
            guard !discarding, !pending.isEmpty,
                  let text = String(data: pending, encoding: .utf8),
                  matching?(text) != false,
                  let row = try? JSONSerialization.jsonObject(with: pending) as? [String: Any] else { return }
            handle(text, row)
        }
        do {
            // Snapshot the readable extent so an active writer cannot keep this scan alive.
            let end = try file.seekToEnd()
            try file.seek(toOffset: 0)
            var remaining = end
            while remaining > 0 {
                guard let data = try file.read(upToCount: Int(min(remaining, 256 * 1024))), !data.isEmpty else { break }
                remaining -= UInt64(data.count)
                let parts = data.split(separator: 10, omittingEmptySubsequences: false)
                for (index, part) in parts.enumerated() {
                    if !discarding {
                        if part.count > maximumLineBytes - pending.count {
                            pending.removeAll(keepingCapacity: true)
                            discarding = true
                        } else { pending.append(contentsOf: part) }
                    }
                    if index < parts.count - 1 {
                        emit()
                        pending.removeAll(keepingCapacity: true)
                        discarding = false
                    }
                }
            }
            // A complete JSON object without a final newline is valid; a partial tail is skipped.
            emit()
            return true
        } catch { return false }
    }
}
