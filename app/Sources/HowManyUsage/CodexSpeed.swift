import Foundation

/// Passive response-rate estimates, inspired by Token Monitor's matched token/time
/// counters. No streaming interception, credentials, model requests or app injection.
enum CodexSpeed {
    /// Cache reads and total input for a single deduplicated observed response.
    struct CacheUsage: Sendable, Equatable {
        let read: Int
        let input: Int

        private static func valid(read: Int, input: Int) -> Self? {
            guard input > 0, read >= 0, read <= input else { return nil }
            return Self(read: read, input: input)
        }

        /// Codex's input already includes its cached portion.
        static func codex(_ usage: [String: Any]) -> Self? {
            guard let input = usage["input_tokens"] as? Int,
                  let read = usage["cached_input_tokens"] as? Int else { return nil }
            return valid(read: read, input: input)
        }

        /// Claude reports fresh input, cache creation and cache read separately.
        static func claude(_ usage: [String: Any]) -> Self? {
            guard let fresh = usage["input_tokens"] as? Int, fresh >= 0,
                  let create = usage["cache_creation_input_tokens"] as? Int, create >= 0,
                  let read = usage["cache_read_input_tokens"] as? Int, read >= 0 else { return nil }
            let (first, overflow1) = fresh.addingReportingOverflow(create)
            let (total, overflow2) = first.addingReportingOverflow(read)
            guard !overflow1, !overflow2 else { return nil }
            return valid(read: read, input: total)
        }

        /// DSH reports a total that includes input, cache reads and output.
        static func dsh(_ usage: [String: Any]) -> Self? {
            guard let fresh = usage["inputTokens"] as? Int, fresh >= 0,
                  let read = usage["cacheReadTokens"] as? Int, read >= 0,
                  let output = usage["outputTokens"] as? Int, output >= 0,
                  let total = usage["totalTokens"] as? Int, total >= output else { return nil }
            let input = total - output
            let (base, overflow) = fresh.addingReportingOverflow(read)
            guard !overflow, input >= base else { return nil }
            return valid(read: read, input: input)
        }

        /// Antigravity reports fresh input, optional cache write and cache read on PLANNER_RESPONSE steps.
        static func antigravity(_ usage: [String: Any]) -> Self? {
            guard let fresh = usage["input_tokens"] as? Int, fresh >= 0,
                  let read = usage["cache_read_tokens"] as? Int, read >= 0 else { return nil }
            let create = (usage["cache_write_tokens"] as? Int) ?? 0
            guard create >= 0 else { return nil }
            let (first, overflow1) = fresh.addingReportingOverflow(create)
            let (total, overflow2) = first.addingReportingOverflow(read)
            guard !overflow1, !overflow2 else { return nil }
            return valid(read: read, input: total)
        }
    }

    struct Sample: Sendable {
        let responseID: String
        let model: String
        let effort: String
        let outputTokens: Int
        let seconds: Double
        let completedAt: Date
        var waitSeconds: Double? = nil
        var outputSeconds: Double? = nil
        /// Transcript timing includes waiting before output, unlike output-stage timing.
        var includesWait = false
        var cacheUsage: CacheUsage? = nil
        var rate: Double? {
            guard let outputSeconds, outputSeconds.isFinite, outputSeconds >= 0.5, outputTokens > 0 else { return nil }
            return Double(outputTokens) / outputSeconds
        }
        var family: String? {
            let name = model.lowercased()
            if name.contains("sol") { return "Sol" }
            if name.contains("luna") { return "Luna" }
            if name.contains("terra") { return "Terra" }
            if name.contains("astra") { return "Astra" }
            if name.contains("claude") { return "Claude" }
            if name.contains("deepseek") { return "DeepSeek" }
            if name.contains("gemini") || name.contains("argon") { return "Gemini" }
            return nil
        }
    }

    struct FirstToken: Sendable {
        let label: String
        let seconds: Double
        let completedAt: Date
    }

    struct Snapshot: Sendable {
        var samples: [Sample] = []
        var firstTokens: [FirstToken] = []
        var observedModels: [String: Date] = [:]
        var now = Date()

        struct Row {
            let name: String
            let ttft: Double?
            let tps: Double?
            let waitCount: Int
            let outputCount: Int
            let includesWait: Bool
            let cachePercent: Double?
            var text: String {
                let wait = ttft.map { String(format: "%.1fs", $0) } ?? "—"
                let output = tps.map { String(format: "%.0f tok/s", $0) } ?? "—"
                let cache = cachePercent.map { String(format: "%.0f%%", $0) } ?? "—"
                return "\(name.padding(toLength: max(25, name.count + 2), withPad: " ", startingAt: 0))\(wait.padding(toLength: 9, withPad: " ", startingAt: 0))\(output.padding(toLength: 14, withPad: " ", startingAt: 0))\(cache)"
            }
        }
        static let explanation = "Passive local logs: models seen in 24h, timing and cache averages over 4h, efforts combined. Cache is input-token-weighted cache reads / total input from the same observed response samples; missing or invalid fields are excluded. Output tok/s excludes TTFT waiting and tool runtime whenever first-token or stream timing is recorded (Codex, DeepSeek, Antigravity agy-speed.json); models without first-token timing (Claude) fall back to end-to-end transcript duration and are prefixed with ~."
        var rows: [Row] {
            let recent = samples.filter { (0...14400).contains(now.timeIntervalSince($0.completedAt)) }
            let observed = observedModels.filter { (0...86_400).contains(now.timeIntervalSince($0.value)) }.keys
            let measured = samples.filter { (0...86_400).contains(now.timeIntervalSince($0.completedAt)) && $0.family != nil }.map(\.model)
            let models = Set(observed).union(measured).sorted { left, right in
                func rank(_ name: String) -> Int {
                    let lower = name.lowercased()
                    if lower.contains("sol") { return 0 }
                    if lower.contains("luna") { return 1 }
                    if lower.contains("terra") { return 2 }
                    if lower.contains("astra") { return 3 }
                    if lower.contains("claude") { return 4 }
                    if lower.contains("gemini") || lower.contains("argon") { return 5 }
                    return 6
                }
                return rank(left) == rank(right) ? left < right : rank(left) < rank(right)
            }
            return models.map { model in
                let group = recent.filter { $0.model == model }
                let waits = group.compactMap(\.waitSeconds).filter { $0.isFinite && $0 >= 0 }.sorted()
                let medianTTFT: Double? = {
                    guard !waits.isEmpty else { return nil }
                    let mid = waits.count / 2
                    return waits.count.isMultiple(of: 2)
                        ? (waits[mid - 1] + waits[mid]) / 2
                        : waits[mid]
                }()
                // Prefer pure output-stage throughput (excluding TTFT wait and tool runtime)
                // whenever recorded; fall back to end-to-end transcript estimates only when
                // a model has no output-stage samples at all (e.g. Claude).
                let pureOutput = group.filter {
                    !$0.includesWait && ($0.outputSeconds ?? 0).isFinite && ($0.outputSeconds ?? 0) >= 0.5 && $0.outputTokens > 0
                }
                let usesFallbackWait = pureOutput.isEmpty
                let output = usesFallbackWait
                    ? group.filter { $0.includesWait && $0.seconds.isFinite && $0.seconds >= 0.5 && $0.outputTokens > 0 }
                    : pureOutput
                let seconds = output.reduce(0.0) { $0 + (usesFallbackWait ? $1.seconds : ($1.outputSeconds ?? 0)) }
                let tokens = output.reduce(0.0) { $0 + Double($1.outputTokens) }
                let cache = group.compactMap(\.cacheUsage)
                let cachedInput = cache.reduce(0.0) { $0 + Double($1.read) }
                let totalInput = cache.reduce(0.0) { $0 + Double($1.input) }
                return Row(name: model, ttft: medianTTFT,
                           tps: seconds.isFinite && seconds > 0 ? tokens / seconds : nil,
                           waitCount: waits.count, outputCount: output.count,
                           includesWait: usesFallbackWait && !output.isEmpty,
                           cachePercent: totalInput > 0 ? 100 * cachedInput / totalInput : nil)
            }.filter { $0.ttft != nil || $0.tps != nil || $0.cachePercent != nil }
        }
        var lines: [String] { ["Speed · 4h avg", "Model                    TTFT     Output        Cache"] + rows.map(\.text) }
    }

    struct Session {
        private struct Response {
            var start: Date?
            var end: Date?
            var firstOutput: Date?
        }
        private var model: String?
        private var effort = "unknown effort"
        private var turnID: String?
        private var current = Response()
        private var awaitingLegacyUsage: Response?
        private var responseIDs: Set<String> = []
        private var responseOrder: [String] = []
        private(set) var samples: [Sample] = []
        private(set) var firstTokens: [String: FirstToken] = [:]

        mutating func seedTurnContext(model: String?, effort: String?, turnID: String?) {
            if let model, !model.isEmpty { self.model = model }
            if let effort, !effort.isEmpty { self.effort = effort }
            if let turnID, !turnID.isEmpty { self.turnID = turnID }
        }

        mutating func consume(_ record: [String: Any]) {
            let type = record["type"] as? String ?? ""
            let payload = record["payload"] as? [String: Any] ?? [:]
            let timestamp = (record["timestamp"] as? String).flatMap(CodexSpeed.date)
            if type == "compacted" {
                current = Response()
                awaitingLegacyUsage = nil
            }
            if type == "turn_context" {
                // A model is only attributed from this turn's recorded settings.
                let nextTurn = payload["turn_id"] as? String
                if let turnID, let nextTurn, nextTurn != turnID {
                    current = Response()
                    awaitingLegacyUsage = nil
                }
                turnID = nextTurn
                model = payload["model"] as? String
                effort = payload["effort"] as? String ?? "unknown effort"
            }
            if type == "event_msg", payload["type"] as? String == "task_started" {
                current = Response(start: timestamp)
                awaitingLegacyUsage = nil
                turnID = payload["turn_id"] as? String
                model = nil
                effort = "unknown effort"
            }
            if type == "response_item" {
                let kind = payload["type"] as? String ?? ""
                if ["function_call_output", "custom_tool_call_output"].contains(kind) {
                    // Older Codex writes token_count after tool completion. Preserve
                    // the model's end timestamp, never include that tool's runtime.
                    if current.end != nil { awaitingLegacyUsage = current }
                    current = Response(start: timestamp)
                } else if kind == "reasoning" || kind == "function_call" || kind == "custom_tool_call"
                    || (kind == "message" && payload["role"] as? String == "assistant") {
                    current.end = timestamp
                }
            }
            if type == "event_msg", payload["type"] as? String == "item_completed",
               let item = payload["item"] as? [String: Any],
               ["Reasoning", "AgentMessage"].contains(item["type"] as? String ?? ""),
               let start = current.start,
               let ms = (payload["started_at_ms"] as? NSNumber)?.doubleValue, ms.isFinite,
               let endMS = (payload["completed_at_ms"] as? NSNumber)?.doubleValue, endMS >= ms,
               payload["turn_id"] as? String == turnID {
                let first = Date(timeIntervalSince1970: ms / 1000)
                if first >= start { current.firstOutput = min(current.firstOutput ?? first, first) }
            }
            if type == "token_usage_record" {
                guard let id = payload["response_id"] as? String, !responseIDs.contains(id),
                      let usage = payload["usage"] as? [String: Any] else { return }
                // Canonical records arrive at response completion, before tools finish.
                // Deduplicate by response identity; the legacy carrier is cleared below.
                responseIDs.insert(id)
                responseOrder.append(id)
                if responseOrder.count > 512 { responseIDs.remove(responseOrder.removeFirst()) }
                if let usageTurn = payload["turn_id"] as? String, let turnID, usageTurn != turnID {
                    current = Response()
                    awaitingLegacyUsage = nil
                    return
                }
                recordSample(usage: usage, response: current, end: timestamp, id: id)
                current = Response()
                awaitingLegacyUsage = nil
            }
            if type == "event_msg", payload["type"] as? String == "token_count",
               let info = payload["info"] as? [String: Any],
               let usage = info["last_token_usage"] as? [String: Any] {
                let response = awaitingLegacyUsage ?? current
                recordSample(usage: usage, response: response, end: response.end)
                awaitingLegacyUsage = nil
                if current.end != nil { current = Response() }
            }
            if type == "event_msg", ["task_complete", "task_completed", "turn_aborted"].contains(payload["type"] as? String ?? "") {
                if payload["type"] as? String != "turn_aborted",
                   let ms = (payload["time_to_first_token_ms"] as? NSNumber)?.doubleValue, ms.isFinite, ms >= 0,
                   let model, let timestamp {
                    let label = "\(model) · \(effort)"
                    firstTokens[label] = FirstToken(label: label, seconds: ms / 1000, completedAt: timestamp)
                }
                current = Response()
                awaitingLegacyUsage = nil
            }
        }

        private mutating func recordSample(usage: [String: Any], response: Response, end: Date?, id: String? = nil) {
            guard let model, !model.isEmpty, let start = response.start, response.end != nil, let end,
                  let tokens = usage["output_tokens"] as? Int, tokens > 0 else { return }
            let seconds = end.timeIntervalSince(start)
            // Very short windows are unstable; missing/invalid timing is unknown.
            guard seconds.isFinite, seconds >= 0.5 else { return }
            let identity = id ?? "legacy:\(start.timeIntervalSince1970):\(end.timeIntervalSince1970):\(tokens)"
            let first = response.firstOutput.flatMap { $0 <= end ? $0 : nil }
            let wait = first.map { $0.timeIntervalSince(start) }
            let output = first.map { end.timeIntervalSince($0) }.flatMap { $0 >= 0.5 ? $0 : nil }
            samples.append(Sample(responseID: identity, model: model, effort: effort, outputTokens: tokens,
                                  seconds: seconds, completedAt: end, waitSeconds: wait, outputSeconds: output,
                                  cacheUsage: CacheUsage.codex(usage)))
            if samples.count > 2048 { samples.removeFirst(samples.count - 2048) }
        }
    }

    static func date(_ value: String) -> Date? {
        fractionalDate.date(from: value) ?? plainDate.date(from: value)
    }
    private static let fractionalDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainDate = ISO8601DateFormatter()
}

/// One serial sampler owns cursors. Initial reads and incremental reads are bounded;
/// partial final lines are retried, and rotation/truncation resets the parser.
final class CodexSpeedScanner: @unchecked Sendable {
    private struct Cursor {
        var offset: UInt64 = 0
        var identity: UInt64 = 0
        var session = CodexSpeed.Session()
    }
    private var cursors: [String: Cursor] = [:]
    private let home: URL
    private var paths: [URL] = []
    private var discoveredAt = Date.distantPast
    private let limit = 2 * 1_048_576

    init(home: URL? = nil) {
        self.home = home ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    func scan(now: Date = Date()) -> CodexSpeed.Snapshot {
        if now.timeIntervalSince(discoveredAt) >= 15 {
            discoveredAt = now
            var found: [(URL, Date)] = []
            // Resumed chats keep their original date directory. Discover by file
            // modification time across sessions, not just today's date folders.
            if let files = FileManager.default.enumerator(at: home.appendingPathComponent("sessions"),
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in files where url.pathExtension == "jsonl" {
                    guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                          values.isRegularFile == true, let modified = values.contentModificationDate else { continue }
                    if now.timeIntervalSince(modified) < 86_400 { found.append((url, modified)) }
                }
            }
            var seen = Set<String>()
            paths = found.sorted { $0.1 > $1.1 }.compactMap { seen.insert($0.0.path).inserted ? $0.0 : nil }.prefix(64).map { $0 }
            let retained = Set(paths.map(\.path))
            cursors = cursors.filter { retained.contains($0.key) }
        }
        for path in paths { read(path) }
        let cutoff = now.addingTimeInterval(-86_400)
        var seenResponses = Set<String>()
        let samples = cursors.values.flatMap { $0.session.samples }.filter {
            $0.completedAt >= cutoff && $0.completedAt <= now && seenResponses.insert($0.responseID).inserted
        }
        let firstTokens = Dictionary(grouping: cursors.values.flatMap { $0.session.firstTokens.values }.filter { $0.completedAt >= cutoff && $0.completedAt <= now }, by: \.label)
            .values.compactMap { $0.max { $0.completedAt < $1.completedAt } }
        return CodexSpeed.Snapshot(samples: samples, firstTokens: firstTokens, now: now)
    }

    private func read(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let identity = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            var cursor = cursors[url.path] ?? Cursor()
            if cursor.identity != identity || size < cursor.offset { cursor = Cursor(identity: identity) }
            cursors[url.path] = cursor
            let start = cursor.offset == 0 && size > UInt64(limit) ? size - UInt64(limit) : cursor.offset
            if start > 0 && cursor.offset == 0 {
                seedLatestTurnContext(handle: handle, upTo: start, session: &cursor.session)
            }
            try handle.seek(toOffset: start)
            let data = try handle.read(upToCount: limit) ?? Data()
            guard let newline = data.lastIndex(of: 10) else { return }
            var complete = data.prefix(through: newline)
            if start > 0 && cursor.offset == 0, let first = complete.firstIndex(of: 10) {
                complete = complete.suffix(from: complete.index(after: first))
            }
            for line in complete.split(separator: 10) {
                if let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                    cursor.session.consume(record)
                }
            }
            cursor.offset = start + UInt64(newline + 1)
            cursors[url.path] = cursor
        } catch { /* A locked, missing or malformed log cannot produce a speed. */ }
    }

    /// Recover the latest turn_context (model/effort/turn_id) when initial reading skips
    /// past the start of a >2MB session file.
    private func seedLatestTurnContext(handle: FileHandle, upTo limitOffset: UInt64, session: inout CodexSpeed.Session) {
        let marker = Data("\"turn_context\"".utf8)
        let chunkSize = 512 * 1024
        let maxLineBytes = 1_048_576
        try? handle.seek(toOffset: 0)
        var offset: UInt64 = 0
        var carry = Data()
        var dropUntilNewline = false
        var latest: (model: String, effort: String?, turnID: String?)?

        func inspectLine(_ line: Data) {
            guard line.range(of: marker) != nil,
                  let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  record["type"] as? String == "turn_context",
                  let payload = record["payload"] as? [String: Any],
                  let model = payload["model"] as? String, !model.isEmpty else { return }
            latest = (model, payload["effort"] as? String, payload["turn_id"] as? String)
        }

        while offset < limitOffset {
            let toRead = min(chunkSize, Int(limitOffset - offset))
            guard let chunk = try? handle.read(upToCount: toRead), !chunk.isEmpty else { break }
            offset += UInt64(chunk.count)
            var cursor = chunk.startIndex
            while cursor < chunk.endIndex {
                if let nl = chunk[cursor...].firstIndex(of: 10) {
                    if !dropUntilNewline {
                        if carry.count + (nl - cursor) <= maxLineBytes {
                            carry.append(contentsOf: chunk[cursor..<nl])
                            inspectLine(carry)
                        }
                    }
                    carry.removeAll(keepingCapacity: true)
                    dropUntilNewline = false
                    cursor = chunk.index(after: nl)
                } else {
                    if !dropUntilNewline {
                        if carry.count + (chunk.endIndex - cursor) > maxLineBytes {
                            carry.removeAll(keepingCapacity: false)
                            dropUntilNewline = true
                        } else {
                            carry.append(contentsOf: chunk[cursor..<chunk.endIndex])
                        }
                    }
                    break
                }
            }
        }
        if let latest {
            session.seedTurnContext(model: latest.model, effort: latest.effort, turnID: latest.turnID)
        }
    }
}
