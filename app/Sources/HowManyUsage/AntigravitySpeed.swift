import Foundation

/// Optional exact per-step Antigravity timing exported to ~/.config/howmanyusage/agy-speed.json
/// (ttft + streamingDuration, excluding tool runtime). When present, overrides transcript timing
/// for matching steps while preserving transcript cacheUsage.
enum AntigravitySpeedFile {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/howmanyusage/agy-speed.json")

    static func samples(url: URL = defaultURL, now: Date = Date()) -> [CodexSpeed.Sample] {
        guard let data = try? Data(contentsOf: url), data.count <= 4 * 1_048_576,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["samples"] as? [[String: Any]] else { return [] }
        var byID: [String: CodexSpeed.Sample] = [:]
        for row in rows {
            guard let rawID = row["id"] as? String, !rawID.isEmpty,
                  let rawModel = row["model"] as? String,
                  let parsed = AntigravitySpeedScanner.splitModelAndEffort(rawModel),
                  let tokens = (row["outputTokens"] as? NSNumber)?.intValue, tokens > 0,
                  let ttft = (row["ttft"] as? NSNumber)?.doubleValue, ttft.isFinite, ttft >= 0,
                  let stream = (row["stream"] as? NSNumber)?.doubleValue, stream.isFinite, stream >= 0,
                  let completedEpoch = (row["completedAt"] as? NSNumber)?.doubleValue, completedEpoch.isFinite else { continue }
            let total = ttft + stream
            guard total.isFinite, total >= 0.5, total <= 3600 else { continue }
            let completedAt = Date(timeIntervalSince1970: completedEpoch)
            guard (0...14_400).contains(now.timeIntervalSince(completedAt)) else { continue }
            let id = rawID.hasPrefix("agy:") ? rawID : "agy:\(rawID)"
            let hasPureOutput = stream >= 0.5
            byID[id] = CodexSpeed.Sample(
                responseID: id,
                model: parsed.model,
                effort: parsed.effort,
                outputTokens: tokens,
                seconds: total,
                completedAt: completedAt,
                waitSeconds: ttft,
                outputSeconds: hasPureOutput ? stream : nil,
                includesWait: !hasPureOutput,
                cacheUsage: nil
            )
        }
        return Array(byID.values)
    }

    static func merge(transcriptSamples: [CodexSpeed.Sample], fileSamples: [CodexSpeed.Sample]) -> [CodexSpeed.Sample] {
        guard !fileSamples.isEmpty else { return transcriptSamples }
        var merged: [String: CodexSpeed.Sample] = Dictionary(
            transcriptSamples.map { ($0.responseID, $0) },
            uniquingKeysWith: { lhs, rhs in
                if rhs.outputTokens != lhs.outputTokens { return rhs.outputTokens > lhs.outputTokens ? rhs : lhs }
                return rhs.completedAt >= lhs.completedAt ? rhs : lhs
            }
        )
        for var sample in fileSamples {
            if let existing = merged[sample.responseID] {
                sample.cacheUsage = existing.cacheUsage
                if existing.outputTokens > sample.outputTokens {
                    sample = CodexSpeed.Sample(
                        responseID: sample.responseID,
                        model: sample.model,
                        effort: sample.effort,
                        outputTokens: existing.outputTokens,
                        seconds: sample.seconds,
                        completedAt: max(sample.completedAt, existing.completedAt),
                        waitSeconds: sample.waitSeconds,
                        outputSeconds: sample.outputSeconds,
                        includesWait: sample.includesWait,
                        cacheUsage: existing.cacheUsage
                    )
                }
            }
            merged[sample.responseID] = sample
        }
        return Array(merged.values)
    }
}

/// Antigravity CLI and clients persist step-level PLANNER_RESPONSE records in
/// ~/.gemini/{antigravity,antigravity-ide,antigravity-cli}/brain/<id>/.system_generated/logs/transcript.jsonl.
/// A PLANNER_RESPONSE followed by a GENERIC tool execution step gives the start-to-completion
/// duration (including TTFT waiting and first-tool runtime); cache reads are recorded on all steps.
final class AntigravitySpeedScanner: @unchecked Sendable {
    private struct Cached {
        let modified: Date
        let size: Int
        let models: [String: Date]
        let samples: [CodexSpeed.Sample]
    }
    private let home: URL
    private var cache: [String: Cached] = [:]
    private var scannedAt = Date.distantPast

    init(home: URL? = nil) {
        self.home = home ?? FileManager.default.homeDirectoryForCurrentUser
    }

    static func splitModelAndEffort(_ raw: String) -> (model: String, effort: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "none" else { return nil }
        var base = trimmed
        var effort = "unknown effort"
        let knownEfforts: Set<String> = ["minimal", "low", "medium", "high", "max", "xhigh", "thinking", "orchestrator"]
        if trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "("), open > trimmed.startIndex {
            let prefix = trimmed[..<open].trimmingCharacters(in: .whitespaces)
            let suffix = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
                .trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty {
                if prefix.lowercased() == "orchestrator" {
                    return ("gemini-orchestrator", suffix.isEmpty ? "orchestrator" : String(suffix))
                }
                if knownEfforts.contains(suffix.lowercased()) {
                    base = String(prefix)
                    effort = String(suffix)
                }
            }
        }
        let lower = base.lowercased()
        if lower == "orchestrator" || lower == "gemini-pro-orchestrator" || lower == "gemini-orchestrator" {
            return ("gemini-orchestrator", effort == "unknown effort" ? "orchestrator" : effort)
        }
        if lower.hasPrefix("gemini") {
            var slug = lower
                .split(whereSeparator: { $0.isWhitespace || $0 == "_" })
                .joined(separator: "-")
            if slug.hasSuffix("-agy") {
                slug.removeLast(4)
            }
            var parts = slug.split(separator: "-").map(String.init)
            let trailingModifiers: Set<String> = ["minimal", "low", "medium", "high", "max", "xhigh", "thinking", "tiered"]
            while parts.count > 2, let last = parts.last, trailingModifiers.contains(last) {
                parts.removeLast()
                if last != "tiered", effort == "unknown effort" {
                    effort = last
                }
            }
            let normalized = parts.joined(separator: "-")
            if normalized == "gemini-pro-orchestrator" {
                return ("gemini-orchestrator", effort == "unknown effort" ? "orchestrator" : effort)
            }
            return (normalized, effort)
        }
        return (base, effort)
    }

    static func extractModel(from record: [String: Any]) -> (model: String, effort: String)? {
        if let direct = record["model"] as? String, let parsed = splitModelAndEffort(direct) {
            return parsed
        }
        guard record["type"] as? String == "USER_INPUT",
              let content = record["content"] as? String else { return nil }
        let marker = "changed setting `Model Selection` from "
        var searchRange = content.startIndex..<content.endIndex
        var latest: (model: String, effort: String)?
        while let markerRange = content.range(of: marker, range: searchRange) {
            let afterMarker = markerRange.upperBound
            searchRange = afterMarker..<content.endIndex
            guard let toRange = content.range(of: " to ", range: afterMarker..<content.endIndex) else { continue }
            let valueStart = toRange.upperBound
            let remainder = content[valueStart...]
            let lineEnd = remainder.firstIndex(where: { $0.isNewline || $0 == "<" }) ?? remainder.endIndex
            let line = remainder[..<lineEnd]
            var value = (line.range(of: ". ").map { line[..<$0.lowerBound] } ?? line)
                .trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(".") { value.removeLast() }
            if let parsed = splitModelAndEffort(value) {
                latest = parsed
            }
        }
        return latest
    }

    static func parse(data: Data, headData: Data? = nil, sourceID: String, now: Date) -> (models: [String: Date], samples: [CodexSpeed.Sample]) {
        struct Pending {
            let stepIndex: Int
            let model: String
            let effort: String
            let start: Date
            let outputTokens: Int
            let cacheUsage: CodexSpeed.CacheUsage?
        }
        var currentModel: String?
        var currentEffort = "unknown effort"
        if let headData {
            for line in headData.split(separator: 10) {
                guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if let next = extractModel(from: record) {
                    currentModel = next.model
                    currentEffort = next.effort
                }
            }
        }
        var models: [String: Date] = [:]
        var samples: [String: CodexSpeed.Sample] = [:]
        var pending: Pending?

        func flush(_ item: Pending, end: Date?) {
            let completedAt = end ?? item.start
            guard (0...14_400).contains(now.timeIntervalSince(completedAt)) else { return }
            let measuredSeconds: Double = {
                guard let end, end >= item.start else { return 0 }
                let delta = end.timeIntervalSince(item.start)
                return (delta >= 0.5 && delta <= 3600) ? delta : 0
            }()
            guard measuredSeconds >= 0.5 || item.cacheUsage != nil else { return }
            let id = "agy:\(sourceID):\(item.stepIndex)"
            if let existing = samples[id],
               existing.outputTokens > item.outputTokens || (existing.outputTokens == item.outputTokens && existing.seconds >= measuredSeconds) {
                return
            }
            samples[id] = CodexSpeed.Sample(
                responseID: id, model: item.model, effort: item.effort,
                outputTokens: item.outputTokens, seconds: measuredSeconds,
                completedAt: completedAt, includesWait: true,
                cacheUsage: item.cacheUsage
            )
        }

        for (lineIdx, line) in data.split(separator: 10).enumerated() {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let next = extractModel(from: record) {
                currentModel = next.model
                currentEffort = next.effort
            }
            let type = record["type"] as? String ?? ""
            let timestamp = (record["created_at"] as? String).flatMap(CodexSpeed.date)
            if let prev = pending {
                if type == "GENERIC" || type == "CHECKPOINT" {
                    flush(prev, end: timestamp)
                } else {
                    flush(prev, end: nil)
                }
                pending = nil
            }
            guard type == "PLANNER_RESPONSE",
                  let ts = timestamp,
                  let model = currentModel, !model.isEmpty else { continue }
            if (0...86_400).contains(now.timeIntervalSince(ts)) {
                models[model] = max(models[model] ?? ts, ts)
            }
            let stepIndex = (record["step_index"] as? NSNumber)?.intValue ?? (-1 - lineIdx)
            let out = max(0, (record["output_tokens"] as? NSNumber)?.intValue ?? 0)
            let cache = CodexSpeed.CacheUsage.antigravity(record)
            if out > 0 || cache != nil {
                pending = Pending(stepIndex: stepIndex, model: model, effort: currentEffort,
                                  start: ts, outputTokens: out, cacheUsage: cache)
            }
        }
        if let prev = pending {
            flush(prev, end: nil)
        }
        return (models, Array(samples.values))
    }

    func scan(now: Date = Date()) -> (models: [String: Date], samples: [CodexSpeed.Sample]) {
        if now.timeIntervalSince(scannedAt) >= 15 {
            scannedAt = now
            let cutoff = now.addingTimeInterval(-86_400)
            let selected = UsageHistoryScanner.antigravityTranscriptFiles(home: home, modifiedSince: cutoff).prefix(64)
            let retained = Set(selected.map(\.path))
            cache = cache.filter { retained.contains($0.key) }
            for url in selected {
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let modified = values.contentModificationDate, let size = values.fileSize else { continue }
                if cache[url.path]?.modified == modified && cache[url.path]?.size == size { continue }
                guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? handle.close() }
                let limit = 2 * 1_048_576
                let headLimit = 16_384
                let headData: Data? = size > limit ? (try? handle.read(upToCount: headLimit)) : nil
                try? handle.seek(toOffset: UInt64(max(0, size - limit)))
                guard let data = try? handle.read(upToCount: limit) else { continue }
                let convID = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                let parsed = Self.parse(data: data, headData: headData, sourceID: convID, now: now)
                cache[url.path] = Cached(modified: modified, size: size, models: parsed.models, samples: parsed.samples)
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
