import Foundation

/// Local observed activity. Missing days remain unknown because session logs can be
/// deleted or unavailable; absence of a record cannot prove absence of activity.
struct UsageHistory: Codable, Sendable {
    struct Day: Codable, Sendable {
        let date: Date
        var codex = 0
        var claude = 0
        var deepseek = 0
        var antigravity = 0
        var prompts = 0
        var observed = false
        var total: Int { UsageNumbers.sum(codex, claude, deepseek, antigravity) }

        init(date: Date, codex: Int = 0, claude: Int = 0, deepseek: Int = 0, antigravity: Int = 0, prompts: Int = 0, observed: Bool = false) {
            self.date = date
            self.codex = codex
            self.claude = claude
            self.deepseek = deepseek
            self.antigravity = antigravity
            self.prompts = prompts
            self.observed = observed
        }

        enum CodingKeys: String, CodingKey {
            case date, codex, claude, deepseek, antigravity, prompts, observed
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date = try c.decode(Date.self, forKey: .date)
            codex = try c.decodeIfPresent(Int.self, forKey: .codex) ?? 0
            claude = try c.decodeIfPresent(Int.self, forKey: .claude) ?? 0
            deepseek = try c.decodeIfPresent(Int.self, forKey: .deepseek) ?? 0
            antigravity = try c.decodeIfPresent(Int.self, forKey: .antigravity) ?? 0
            prompts = try c.decodeIfPresent(Int.self, forKey: .prompts) ?? 0
            observed = try c.decodeIfPresent(Bool.self, forKey: .observed) ?? false
        }
    }
    var days: [Day]
}

enum UsageHistoryScanner {
    static let antigravityBrainDirs = [
        ".gemini/antigravity/brain",
        ".gemini/antigravity-ide/brain",
        ".gemini/antigravity-cli/brain"
    ]

    /// Discover Antigravity transcripts across CLI and client data roots, deduplicating
    /// conversations that exist in multiple roots (e.g. after IDE migration) by conversation ID.
    static func antigravityTranscriptFiles(home: URL, modifiedSince: Date? = nil) -> [URL] {
        let fm = FileManager.default
        var best: [String: (url: URL, modified: Date, size: Int)] = [:]
        for rel in antigravityBrainDirs {
            let brain = home.appendingPathComponent(rel)
            guard let convDirs = try? fm.contentsOfDirectory(
                at: brain,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for convDir in convDirs {
                let convID = convDir.lastPathComponent
                let transcript = convDir.appendingPathComponent(".system_generated/logs/transcript.jsonl")
                guard let values = try? transcript.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate else { continue }
                if let since = modifiedSince, modified < since { continue }
                let size = values.fileSize ?? 0
                if let existing = best[convID] {
                    if modified > existing.modified || (modified == existing.modified && size > existing.size) {
                        best[convID] = (transcript, modified, size)
                    }
                } else {
                    best[convID] = (transcript, modified, size)
                }
            }
        }
        return best.values.sorted { $0.modified > $1.modified }.map(\.url)
    }

    private struct Request: Codable { var date: Date; var tokens: Int }
    private struct FileCache: Codable {
        var modified: Date
        var size: Int
        var coveredFrom: Date
        var days: [UsageHistory.Day]
        var requests: [String: Request]
    }
    private struct Cache: Codable {
        var version = 3
        var files: [String: FileCache] = [:]
    }
    private static func cacheDirectory(_ home: URL) -> URL {
        home.appendingPathComponent(".config/howmanyusage", isDirectory: true)
    }
    static let weeks = 14
    static let dayCount = weeks * 7

    static func loadSnapshot(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> UsageHistory? {
        let path = cacheDirectory(home).appendingPathComponent("usage-history.json")
        guard let data = try? Data(contentsOf: path), let history = try? JSONDecoder().decode(UsageHistory.self, from: data) else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let today = cal.startOfDay(for: now)
        let lookup = Dictionary(history.days.map { ($0.date, $0) }, uniquingKeysWith: { _, last in last })
        return UsageHistory(days: (0..<dayCount).map { offset in
            let day = cal.date(byAdding: .day, value: offset - (dayCount - 1), to: today)!
            return lookup[day] ?? UsageHistory.Day(date: day)
        })
    }
    static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date(),
                     onFileRead: ((URL) -> Void)? = nil,
                     progress: ((UsageHistory) -> Void)? = nil) -> UsageHistory {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today)!
        var days = (0..<dayCount).map { UsageHistory.Day(date: calendar.date(byAdding: .day, value: $0, to: start)!) }
        let emptyDays = days
        let directory = cacheDirectory(home)
        let indexURL = directory.appendingPathComponent("usage-history-index.json")
        let snapshotURL = directory.appendingPathComponent("usage-history.json")
        let oldCache = (try? Data(contentsOf: indexURL)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
        let oldFiles = oldCache?.version == 3 ? (oldCache?.files ?? [:]) : [:]
        var nextFiles: [String: FileCache] = [:]
        var globalRequests: [String: Request] = [:]
        var fileRequests: [String: Request] = [:]
        let hadSnapshot = FileManager.default.fileExists(atPath: snapshotURL.path)
        var lastCheckpoint = Date()
        var lastUpdate = Date.distantPast
        func publish(force: Bool = false) {
            guard progress != nil, force || Date().timeIntervalSince(lastUpdate) >= 1 else { return }
            lastUpdate = Date()
            progress?(UsageHistory(days: days))
        }
        publish(force: true)
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ row: [String: Any]) -> Date? {
            if let s = (row["timestamp"] as? String) ?? (row["created_at"] as? String) { return fractional.date(from: s) ?? plain.date(from: s) }
            if let ms = row["time"] as? NSNumber { return UsageNumbers.date(epoch: ms.doubleValue / 1000) }
            return nil
        }
        func index(_ date: Date) -> Int? {
            guard date >= start, date <= now, let i = calendar.dateComponents([.day], from: start, to: date).day, days.indices.contains(i) else { return nil }
            return i
        }
        func number(_ v: Any?) -> Int { UsageNumbers.count(v) }
        func files(_ path: String, matches: (URL) -> Bool) -> [URL] {
            guard let e = FileManager.default.enumerator(at: home.appendingPathComponent(path), includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
            var result: [(url: URL, modified: Date)] = []
            for case let url as URL in e where matches(url) {
                if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified >= start { result.append((url, modified)) }
            }
            return result.sorted { $0.modified > $1.modified }.map(\.url)
        }
        func records(_ text: String, matching types: [String], _ handle: ([String: Any]) -> Void) {
            for (lineNumber, line) in text.split(separator: "\n").enumerated() {
                _ = lineNumber
                guard types.contains(where: { line.contains($0) }) else { continue }
                if line.contains("assistant/chunk"), !line.contains("\"usage\"") { continue }
                guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                handle(row)
            }
        }
        func records(_ file: URL, matching types: [String], _ handle: ([String: Any]) -> Void) -> Bool {
            LocalJSONL.read(file, matching: { line in types.contains(where: { line.contains($0) }) }) { _, row in
                handle(row)
            }
        }
        func process(_ file: URL, _ parse: () -> Bool) {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate, let size = values.fileSize else { return }
            let key = file.path
            let entry: FileCache
            if let old = oldFiles[key], old.modified == modified, old.size == size, old.coveredFrom <= start {
                entry = old
            } else {
                onFileRead?(file)
                let accumulated = days
                days = emptyDays
                fileRequests = [:]
                let success = parse()
                let parsedDays = days.filter(\.observed)
                days = accumulated
                guard success else { return }
                entry = FileCache(modified: modified, size: size, coveredFrom: start, days: parsedDays, requests: fileRequests)
            }
            nextFiles[key] = entry
            for day in entry.days {
                guard let i = index(day.date) else { continue }
                days[i].codex = UsageNumbers.sum(days[i].codex, day.codex); days[i].claude = UsageNumbers.sum(days[i].claude, day.claude)
                days[i].deepseek = UsageNumbers.sum(days[i].deepseek, day.deepseek); days[i].antigravity = UsageNumbers.sum(days[i].antigravity, day.antigravity)
                days[i].prompts = UsageNumbers.sum(days[i].prompts, day.prompts)
                days[i].observed = days[i].observed || day.observed
            }
            for (id, request) in entry.requests {
                guard let i = index(request.date), request.tokens > (globalRequests[id]?.tokens ?? 0) else { continue }
                if let old = globalRequests[id], let oldIndex = index(old.date) { days[oldIndex].claude = max(0, days[oldIndex].claude) - min(max(0, days[oldIndex].claude), max(0, old.tokens)) }
                globalRequests[id] = request
                days[i].claude = UsageNumbers.sum(days[i].claude, request.tokens); days[i].observed = true
            }
            publish()
            if Date().timeIntervalSince(lastCheckpoint) >= 10 {
                lastCheckpoint = Date()
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let checkpoint = oldFiles.merging(nextFiles) { _, new in new }
                if let data = try? JSONEncoder().encode(Cache(files: checkpoint)) { try? data.write(to: indexURL, options: .atomic) }
                if !hadSnapshot, let data = try? JSONEncoder().encode(UsageHistory(days: days)) { try? data.write(to: snapshotURL, options: .atomic) }
            }
        }
        for file in files(".codex/sessions", matches: { $0.pathExtension == "jsonl" }) {
          process(file) {
            var previous = 0
            return records(file, matching: ["event_msg"]) { row in
                guard row["type"] as? String == "event_msg", let payload = row["payload"] as? [String: Any] else { return }
                let ts = date(row)
                if payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any],
                   let total = info["total_token_usage"] as? [String: Any] {
                    let current = UsageNumbers.sum(number(total["input_tokens"]), number(total["output_tokens"]))
                    let delta = current >= previous ? current - previous : current
                    previous = current
                    if let ts, let i = index(ts), delta > 0 { days[i].codex = UsageNumbers.sum(days[i].codex, delta); days[i].observed = true }
                } else if payload["type"] as? String == "user_message", payload["message"] is String, let ts, let i = index(ts) {
                    days[i].prompts = UsageNumbers.sum(days[i].prompts, 1); days[i].observed = true
                }
            }
          }
        }
        for file in files(".claude/projects", matches: { $0.pathExtension == "jsonl" }) {
          process(file) {
            return records(file, matching: ["\"user\"", "\"assistant\""]) { row in
                guard let ts = date(row), let i = index(ts), let message = row["message"] as? [String: Any] else { return }
                if row["type"] as? String == "user", !file.pathComponents.contains("subagents") {
                    let blocks = message["content"] as? [[String: Any]]
                    if blocks?.isEmpty != false || !(blocks?.allSatisfy { $0["type"] as? String == "tool_result" } ?? false) {
                        days[i].prompts = UsageNumbers.sum(days[i].prompts, 1); days[i].observed = true
                    }
                }
                guard row["type"] as? String == "assistant", let usage = message["usage"] as? [String: Any],
                      let id = (row["requestId"] as? String) ?? (message["id"] as? String), !id.isEmpty else { return }
                let count = UsageNumbers.sum(number(usage["input_tokens"]), number(usage["cache_creation_input_tokens"]), number(usage["cache_read_input_tokens"]), number(usage["output_tokens"]))
                if count > (fileRequests[id]?.tokens ?? 0) { fileRequests[id] = Request(date: days[i].date, tokens: count) }
            }
          }
        }
        for file in files(".pi/agent/sessions", matches: { $0.pathExtension == "jsonl" }) {
          process(file) {
            return records(file, matching: ["\"message\""]) { row in
                guard let ts = date(row), let i = index(ts), row["type"] as? String == "message", let m = row["message"] as? [String: Any] else { return }
                if m["role"] as? String == "user" { days[i].prompts = UsageNumbers.sum(days[i].prompts, 1); days[i].observed = true }
                if m["provider"] as? String == "deepseek", let usage = m["usage"] as? [String: Any] {
                    let count = number(usage["totalTokens"]); days[i].deepseek = UsageNumbers.sum(days[i].deepseek, count); if count > 0 { days[i].observed = true }
                }
            }
          }
        }
        let versions = ["session.jsonl.zstd": 1, "session.v3.jsonl.zstd": 3, "session.v4.jsonl.zstd": 4]
        var selected: [String: (URL, Int)] = [:]
        for file in files(".dsh/sessions", matches: { versions[$0.lastPathComponent] != nil }) {
            let key = file.deletingLastPathComponent().path, version = versions[file.lastPathComponent]!
            if version > (selected[key]?.1 ?? 0) { selected[key] = (file, version) }
        }
        for (_, (file, _)) in selected {
          process(file) {
            guard let text = Zstd.decompress(file) else { return false }
            var isDeepSeek = false
            var usageByStep: [String: (Int, Int)] = [:]
            records(text, matching: ["request/context", "request/header", "user/message", "assistant/message", "assistant/chunk"]) { row in
                let type = row["type"] as? String ?? "", data = row["data"] as? [String: Any] ?? [:]
                if type == "request/context" { isDeepSeek = ((data["model"] as? String ?? "") + (data["provider"] as? String ?? "")).lowercased().contains("deepseek") }
                if type == "request/header", let header = data["header"] as? [String: Any], let config = header["config"] as? [String: Any], let model = config["model"] as? String { isDeepSeek = model.lowercased().contains("deepseek") }
                guard let ts = date(row), let i = index(ts) else { return }
                if type == "user/message" { days[i].prompts = UsageNumbers.sum(days[i].prompts, 1); days[i].observed = true }
                guard isDeepSeek, let turn = data["turn"] as? Int, let step = data["step"] as? Int else { return }
                let chunk = data["chunk"] as? [String: Any]
                let usage = type == "assistant/message" ? data["usage"] as? [String: Any] : ((type == "assistant/chunk" && chunk?["type"] as? String == "usage") ? chunk?["usage"] as? [String: Any] : nil)
                guard let usage else { return }
                let count = UsageNumbers.sum(number(usage["inputTokens"]), number(usage["cacheReadTokens"]), number(usage["outputTokens"]))
                let key = "\(turn):\(step)"
                if count > (usageByStep[key]?.1 ?? 0) { usageByStep[key] = (i, count) }
            }
            for (_, value) in usageByStep { days[value.0].deepseek = UsageNumbers.sum(days[value.0].deepseek, value.1); if value.1 > 0 { days[value.0].observed = true } }
            return true
          }
        }
        for file in antigravityTranscriptFiles(home: home, modifiedSince: start) {
          process(file) {
            var usageByStep: [Int: (Int, Int)] = [:]
            var unindexedTokens: [(Int, Int)] = []
            let success = records(file, matching: ["USER_INPUT", "PLANNER_RESPONSE"]) { row in
                guard let ts = date(row), let i = index(ts) else { return }
                let type = row["type"] as? String ?? ""
                if type == "USER_INPUT", row["source"] as? String == "USER_EXPLICIT" {
                    days[i].prompts = UsageNumbers.sum(days[i].prompts, 1); days[i].observed = true
                } else if type == "PLANNER_RESPONSE" {
                    let count = UsageNumbers.sum(number(row["input_tokens"]), number(row["cache_read_tokens"]), number(row["cache_write_tokens"]), number(row["output_tokens"]))
                    if let step = (row["step_index"] as? NSNumber)?.intValue {
                        if count > (usageByStep[step]?.1 ?? 0) { usageByStep[step] = (i, count) }
                    } else if count > 0 {
                        unindexedTokens.append((i, count))
                    }
                }
            }
            for (_, value) in usageByStep { days[value.0].antigravity = UsageNumbers.sum(days[value.0].antigravity, value.1); if value.1 > 0 { days[value.0].observed = true } }
            for value in unindexedTokens { days[value.0].antigravity = UsageNumbers.sum(days[value.0].antigravity, value.1); if value.1 > 0 { days[value.0].observed = true } }
            return success
          }
        }
        publish(force: true)
        let history = UsageHistory(days: days)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Cache(files: nextFiles)) { try? data.write(to: indexURL, options: .atomic) }
        if let data = try? JSONEncoder().encode(history) { try? data.write(to: snapshotURL, options: .atomic) }
        return history
    }
}
