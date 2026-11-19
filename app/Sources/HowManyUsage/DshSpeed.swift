import Foundation

/// DSH persists stream timestamps, including v4's stream nested in assistant/message.
/// Only completed messages with official usage and matching step boundaries count.
enum DshSpeed {
    static func parse(_ text: String, sourceID: String) -> [CodexSpeed.Sample] {
        var model: String?
        var sessionID = sourceID
        var step: String?
        var start: Date?
        var first: Date?
        var usageAt: Date?
        var result: [String: CodexSpeed.Sample] = [:]

        func date(_ value: Any?) -> Date? {
            guard let ms = (value as? NSNumber)?.doubleValue, ms.isFinite else { return nil }
            return Date(timeIntervalSince1970: ms / 1000)
        }
        func key(_ data: [String: Any]) -> String? {
            guard let turn = data["turn"] as? Int, let step = data["step"] as? Int else { return nil }
            return "\(turn):\(step)"
        }
        func firstOutput(_ event: [String: Any]) -> Date? {
            let type = event["type"] as? String ?? ""
            if type == "chunk", let chunk = event["chunk"] as? [String: Any],
               ["text-delta", "reasoning-delta", "tool-call-delta"].contains(chunk["type"] as? String ?? "") {
                return date(event["time"])
            }
            if ["text-chunks", "reasoning-chunks", "tool-call-chunks"].contains(type) { return date(event["time0"]) }
            return nil
        }

        for line in text.split(separator: "\n") {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = record["type"] as? String ?? ""
            let data = record["data"] as? [String: Any] ?? [:]
            let timestamp = date(record["time"])
            if type == "session", let id = record["id"] as? String { sessionID = id }
            if type == "request/context" {
                let provider = (data["provider"] as? String ?? "").lowercased()
                if let name = data["model"] as? String {
                    model = name.lowercased().contains("deepseek") || provider.contains("deepseek") ? name : nil
                }
            }
            if type == "request/header", let header = data["header"] as? [String: Any],
               let config = header["config"] as? [String: Any], let name = config["model"] as? String {
                model = name.lowercased().contains("deepseek") ? name : nil
            }
            if type == "step/start" {
                step = key(data)
                start = timestamp
                first = nil
                usageAt = nil
            }
            if type == "assistant/chunk", key(data) == step,
               let chunk = data["chunk"] as? [String: Any] {
                let streamEvent: [String: Any] = ["type": "chunk", "time": record["time"] ?? NSNull(), "chunk": chunk]
                if let next = firstOutput(streamEvent) { first = min(first ?? next, next) }
                if chunk["type"] as? String == "usage" { usageAt = timestamp }
            }
            if ["text-chunks", "reasoning-chunks", "tool-call-chunks"].contains(type), key(data) == step,
               let time = date(record["time0"]) { first = min(first ?? time, time) }

            guard type == "assistant/message", let messageStep = key(data), messageStep == step,
                  let model, let start, let timestamp,
                  let usage = data["usage"] as? [String: Any],
                  let tokens = (usage["outputTokens"] as? NSNumber)?.intValue, tokens > 0 else { continue }
            // In v4, stream records are folded into this completed message.
            for event in data["stream"] as? [[String: Any]] ?? [] {
                if let next = firstOutput(event) { first = min(first ?? next, next) }
                if let chunk = event["chunk"] as? [String: Any], chunk["type"] as? String == "usage" {
                    usageAt = date(event["time"])
                }
            }
            let end = usageAt ?? timestamp
            guard end >= start else { continue }
            let firstOutput = first.flatMap { $0 >= start && $0 <= end ? $0 : nil }
            let outputSeconds = firstOutput.map { end.timeIntervalSince($0) }
            let id = "dsh:\(sessionID):\(messageStep)"
            result[id] = CodexSpeed.Sample(responseID: id, model: model, effort: "",
                outputTokens: tokens, seconds: end.timeIntervalSince(start), completedAt: end,
                waitSeconds: firstOutput.map { $0.timeIntervalSince(start) },
                outputSeconds: outputSeconds.flatMap { $0 >= 0.5 ? $0 : nil },
                cacheUsage: CodexSpeed.CacheUsage.dsh(usage))
        }
        return Array(result.values)
    }
}

final class DshSpeedScanner: @unchecked Sendable {
    private struct Cached {
        let modified: Date
        let size: Int
        let samples: [CodexSpeed.Sample]
    }
    private let root: URL
    private var paths: [URL] = []
    private var cache: [String: Cached] = [:]
    private var discoveredAt = Date.distantPast

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/sessions")
    }

    func scan(now: Date = Date()) -> [CodexSpeed.Sample] {
        if now.timeIntervalSince(discoveredAt) >= 15 {
            discoveredAt = now
            var sessions: [String: (url: URL, version: Int, modified: Date)] = [:]
            let names = ["session.jsonl.zstd": 1, "session.v3.jsonl.zstd": 3, "session.v4.jsonl.zstd": 4]
            if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in files {
                    guard let version = names[url.lastPathComponent],
                          let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                          now.timeIntervalSince(modified) < 86_400 else { continue }
                    let key = url.deletingLastPathComponent().path
                    if version > (sessions[key]?.version ?? 0) { sessions[key] = (url, version, modified) }
                }
            }
            paths = sessions.values.sorted { $0.modified > $1.modified }.prefix(64).map(\.url)
            let retained = Set(paths.map(\.path))
            cache = cache.filter { retained.contains($0.key) }
        }
        for url in paths {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate, let size = values.fileSize else { continue }
            if cache[url.path]?.modified == modified && cache[url.path]?.size == size { continue }
            // Bound decompression work; changed files are reparsed, unchanged files cached.
            guard size <= 8 * 1_048_576, let text = Zstd.decompress(url), text.utf8.count <= 32 * 1_048_576 else {
                cache.removeValue(forKey: url.path)
                continue
            }
            let samples = DshSpeed.parse(text, sourceID: url.deletingLastPathComponent().path)
                .filter { (0...86_400).contains(now.timeIntervalSince($0.completedAt)) }
            cache[url.path] = Cached(modified: modified, size: size, samples: samples)
        }
        var seen = Set<String>()
        return cache.values.flatMap(\.samples).filter { seen.insert($0.responseID).inserted }
    }
}

final class ModelSpeedScanner: @unchecked Sendable {
    private let codex = CodexSpeedScanner()
    private let dsh = DshSpeedScanner()
    private let claude = ClaudeModelScanner()
    private let antigravity = AntigravitySpeedScanner()

    func scan(now: Date = Date()) -> CodexSpeed.Snapshot {
        var snapshot = codex.scan(now: now)
        snapshot.samples += dsh.scan(now: now)
        let claudeData = claude.scan(now: now)
        snapshot.observedModels = claudeData.models
        snapshot.samples += claudeData.samples
        let agyData = antigravity.scan(now: now)
        for (model, date) in agyData.models {
            snapshot.observedModels[model] = max(snapshot.observedModels[model] ?? date, date)
        }
        let agyFileSamples = AntigravitySpeedFile.samples(now: now)
        snapshot.samples += AntigravitySpeedFile.merge(transcriptSamples: agyData.samples, fileSamples: agyFileSamples)
        return snapshot
    }
}

/// Claude's completed content blocks establish model activity, but not TTFT.
/// Keep their real model names visible without pretending completion == first token.
final class ClaudeModelScanner: @unchecked Sendable {
    private struct Cached {
        let modified: Date
        let size: Int
        let models: [String: Date]
        let samples: [CodexSpeed.Sample]
    }
    private let root: URL
    private var cache: [String: Cached] = [:]
    private var scannedAt = Date.distantPast

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    static func models(in data: Data, now: Date) -> [String: Date] {
        var result: [String: Date] = [:]
        for line in data.split(separator: 10) {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  record["type"] as? String == "assistant",
                  let message = record["message"] as? [String: Any],
                  let model = message["model"] as? String, model.lowercased().hasPrefix("claude-"),
                  let time = record["timestamp"] as? String, let date = CodexSpeed.date(time),
                  (0...86_400).contains(now.timeIntervalSince(date)) else { continue }
            result[model] = max(result[model] ?? date, date)
        }
        return result
    }

    /// Match a completed assistant record to the preceding user prompt or tool
    /// result, as Claude statusline projects do. This is an end-to-end estimate,
    /// not output-stage speed: persisted records do not expose first-token time.
    static func samples(in data: Data, now: Date, includeSidechain: Bool = false) -> [CodexSpeed.Sample] {
        var lastUser: Date?
        var samples: [String: CodexSpeed.Sample] = [:]
        var starts: [String: Date] = [:]
        for line in data.split(separator: 10) {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  includeSidechain || record["isSidechain"] as? Bool != true,
                  let type = record["type"] as? String,
                  let timestamp = (record["timestamp"] as? String).flatMap(CodexSpeed.date) else { continue }
            if type == "user" { lastUser = timestamp; continue }
            guard type == "assistant", let message = record["message"] as? [String: Any],
                  let id = message["id"] as? String, !id.isEmpty,
                  let model = message["model"] as? String, model.lowercased().hasPrefix("claude-"),
                  let usage = message["usage"] as? [String: Any],
                  let tokens = usage["output_tokens"] as? Int, tokens > 0,
                  (0...14_400).contains(now.timeIntervalSince(timestamp)),
                  let start = starts[id] ?? lastUser else { continue }
            let seconds = timestamp.timeIntervalSince(start)
            guard seconds >= 0.5, seconds <= 3600 else { continue }
            if let existing = samples[id], existing.completedAt > timestamp { continue }
            starts[id] = start
            samples[id] = CodexSpeed.Sample(responseID: "claude:\(id)", model: model, effort: "unknown effort",
                outputTokens: tokens, seconds: seconds, completedAt: timestamp, includesWait: true,
                cacheUsage: CodexSpeed.CacheUsage.claude(usage))
        }
        return Array(samples.values)
    }

    func scan(now: Date = Date()) -> (models: [String: Date], samples: [CodexSpeed.Sample]) {
        if now.timeIntervalSince(scannedAt) >= 15 {
            scannedAt = now
            var files: [(url: URL, modified: Date, size: Int)] = []
            if let enumerator = FileManager.default.enumerator(at: root,
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                    guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                          let modified = values.contentModificationDate, let size = values.fileSize,
                          now.timeIntervalSince(modified) < 86_400 else { continue }
                    files.append((url, modified, size))
                }
            }
            let selected = files.sorted { $0.modified > $1.modified }.prefix(64)
            let retained = Set(selected.map { $0.url.path })
            cache = cache.filter { retained.contains($0.key) }
            for file in selected {
                if cache[file.url.path]?.modified == file.modified && cache[file.url.path]?.size == file.size { continue }
                guard let handle = try? FileHandle(forReadingFrom: file.url) else { continue }
                defer { try? handle.close() }
                let limit = 2 * 1_048_576
                try? handle.seek(toOffset: UInt64(max(0, file.size - limit)))
                guard let data = try? handle.read(upToCount: limit) else { continue }
                cache[file.url.path] = Cached(modified: file.modified, size: file.size,
                    models: Self.models(in: data, now: now),
                    samples: Self.samples(in: data, now: now, includeSidechain: file.url.lastPathComponent.hasPrefix("agent-")))
            }
        }
        var models: [String: Date] = [:]
        var samples: [String: CodexSpeed.Sample] = [:]
        for entry in cache.values {
            for (model, date) in entry.models where (0...86_400).contains(now.timeIntervalSince(date)) {
                models[model] = max(models[model] ?? date, date)
            }
            for sample in entry.samples where (0...14_400).contains(now.timeIntervalSince(sample.completedAt)) {
                if let previous = samples[sample.responseID], previous.completedAt >= sample.completedAt { continue }
                samples[sample.responseID] = sample
            }
        }
        return (models, Array(samples.values))
    }
}
