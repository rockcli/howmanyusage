import Foundation
import Testing
@testable import HowManyUsage

struct CodexSpeedTests {
    private func record(_ time: Double, _ type: String, _ payload: [String: Any]) -> [String: Any] {
        ["timestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: time)), "type": type, "payload": payload]
    }
    private func start(_ session: inout CodexSpeed.Session, at: Double = 0, model: String = "gpt-6.1-sol", turn: String = "turn") {
        session.consume(record(at, "event_msg", ["type": "task_started", "turn_id": turn]))
        session.consume(record(at, "turn_context", ["turn_id": turn, "model": model, "effort": "medium"]))
    }
    private func output(_ session: inout CodexSpeed.Session, at: Double, first: Double? = nil) {
        if let first {
            session.consume(record(at, "event_msg", ["type": "item_completed", "turn_id": "turn",
                "item": ["type": "Reasoning"], "started_at_ms": first * 1000, "completed_at_ms": at * 1000]))
        }
        session.consume(record(at, "response_item", ["type": "custom_tool_call"]))
    }
    private func usage(_ session: inout CodexSpeed.Session, at: Double, tokens: Int = 100, id: String = "resp", turn: String = "turn") {
        session.consume(record(at, "token_usage_record", ["response_id": id, "turn_id": turn,
            "usage": ["output_tokens": tokens, "reasoning_output_tokens": 40, "input_tokens": 90000, "cached_input_tokens": 80000]]))
    }

    @Test func outputOnlyCountersAndCanonicalLegacyDeduplication() {
        var session = CodexSpeed.Session()
        start(&session)
        output(&session, at: 9, first: 2)
        usage(&session, at: 10)
        // Same response is repeated in both carriers; its tool takes 90s.
        session.consume(record(100, "response_item", ["type": "custom_tool_call_output"]))
        session.consume(record(100, "event_msg", ["type": "token_count", "info": ["last_token_usage": ["output_tokens": 100]]]))
        usage(&session, at: 100, id: "resp")
        #expect(session.samples.count == 1)
        #expect(session.samples.first?.rate == 12.5)
        #expect(session.samples.first?.waitSeconds == 2)
        #expect(session.samples.first?.outputSeconds == 8)
        #expect(session.samples.first?.cacheUsage == .init(read: 80000, input: 90000))
        // The next model request starts only after the tool returned.
        output(&session, at: 104, first: 102)
        usage(&session, at: 105, id: "resp2")
        #expect(session.samples.count == 2)
        #expect(session.samples.last?.outputSeconds == 3)
        #expect(session.samples.last?.waitSeconds == 2)
    }

    @Test func legacyUsageAfterParallelToolResultsExcludesTools() {
        var session = CodexSpeed.Session()
        start(&session)
        output(&session, at: 10)
        for time in [80.0, 90.0] {
            session.consume(record(time, "response_item", ["type": "function_call_output"]))
        }
        let legacy: [String: Any] = ["type": "token_count", "info": ["last_token_usage": ["output_tokens": 200]]]
        session.consume(record(90, "event_msg", legacy))
        session.consume(record(90, "event_msg", legacy))
        #expect(session.samples.count == 1)
        #expect(session.samples.first?.seconds == 10)
        output(&session, at: 95)
        session.consume(record(95, "event_msg", legacy))
        #expect(session.samples.last?.seconds == 5)
    }

    @Test func unknownTimingModelsAndSubsecondWindowsStayUnknown() {
        var session = CodexSpeed.Session()
        output(&session, at: 5)
        usage(&session, at: 6)
        #expect(session.samples.isEmpty)
        start(&session)
        output(&session, at: 0)
        usage(&session, at: 0, id: "zero")
        #expect(session.samples.isEmpty)
        start(&session)
        output(&session, at: 2)
        usage(&session, at: 3, id: "wrong-turn", turn: "other")
        #expect(session.samples.isEmpty)
        start(&session)
        session.consume(record(1, "compacted", [:]))
        output(&session, at: 5)
        usage(&session, at: 6, id: "after-compact")
        #expect(session.samples.isEmpty)
    }

    @Test func modelSwitchAndFirstTokenAreTurnScoped() {
        var session = CodexSpeed.Session()
        start(&session)
        output(&session, at: 9)
        usage(&session, at: 10)
        session.consume(record(11, "event_msg", ["type": "task_complete", "time_to_first_token_ms": 2500]))
        start(&session, at: 20, model: "gpt-6-luna", turn: "luna-turn")
        output(&session, at: 24)
        usage(&session, at: 25, id: "luna", turn: "luna-turn")
        #expect(session.samples.map(\.model) == ["gpt-6.1-sol", "gpt-6-luna"])
        #expect(session.firstTokens["gpt-6.1-sol · medium"]?.seconds == 2.5)
        #expect(session.firstTokens["gpt-6-luna · medium"] == nil)
        session.consume(record(30, "event_msg", ["type": "task_started", "turn_id": "no-model"]))
        output(&session, at: 34)
        usage(&session, at: 35, id: "no-model", turn: "no-model")
        #expect(session.samples.count == 2)
    }

    @Test func concreteModelsCombineEffortsAndExpireTimingsAfterFourHours() {
        let now = Date(timeIntervalSince1970: 100000)
        let samples = [
            CodexSpeed.Sample(responseID: "a", model: "gpt-6.1-sol", effort: "low", outputTokens: 100, seconds: 10, completedAt: now, waitSeconds: 6, outputSeconds: 4),
            CodexSpeed.Sample(responseID: "b", model: "gpt-6.1-sol", effort: "high", outputTokens: 900, seconds: 30, completedAt: now, waitSeconds: 18, outputSeconds: 12),
            CodexSpeed.Sample(responseID: "c", model: "gpt-6-sol", effort: "low", outputTokens: 300, seconds: 3, completedAt: now.addingTimeInterval(-7200), waitSeconds: 1, outputSeconds: 2)
        ]
        var snapshot = CodexSpeed.Snapshot(samples: samples, observedModels: [
            "claude-sonnet-5-5": now.addingTimeInterval(-80000),
            "claude-opus-5-5": now.addingTimeInterval(-87000)
        ], now: now)
        let sol = snapshot.rows.first { $0.name == "gpt-6.1-sol" }
        #expect(sol?.ttft == 12)
        #expect(sol?.tps == 62.5)
        #expect(sol?.outputCount == 2)
        #expect(snapshot.rows.count == 2)
        #expect(snapshot.rows.first { $0.name == "claude-sonnet-5-5" }?.ttft == nil)
        #expect(snapshot.rows.first { $0.name == "gpt-6-sol" }?.tps == 150)
        snapshot.now = now.addingTimeInterval(3601)
        #expect(snapshot.rows.count == 2)
        snapshot.now = now.addingTimeInterval(14401)
        #expect(snapshot.rows.isEmpty)
        snapshot.now = now.addingTimeInterval(86401)
        #expect(snapshot.rows.isEmpty)
    }

    @Test func bothUnknownRowsHideButPartialAndZeroWaitMeasurementsRemain() {
        let now = Date(timeIntervalSince1970: 100000)
        let samples = [
            CodexSpeed.Sample(responseID: "a", model: "gpt-6-luna", effort: "low", outputTokens: 10, seconds: 1, completedAt: now, waitSeconds: 0),
            CodexSpeed.Sample(responseID: "b", model: "deepseek-flash", effort: "", outputTokens: 200, seconds: 2, completedAt: now, outputSeconds: 1),
            CodexSpeed.Sample(responseID: "c", model: "gpt-6.1-sol", effort: "", outputTokens: 100, seconds: 10, completedAt: now)
        ]
        let snapshot = CodexSpeed.Snapshot(samples: samples, observedModels: ["claude-opus-5-5": now], now: now)
        #expect(snapshot.rows.count == 2)
        #expect(snapshot.rows.first { $0.name == "gpt-6-luna" }?.ttft == 0)
        #expect(snapshot.rows.first { $0.name == "deepseek-flash" }?.tps == 200)
        #expect(snapshot.rows.allSatisfy { $0.name != "gpt-6.1-sol" && $0.name != "claude-opus-5-5" })
    }

    @Test func responseTotalsWithoutAFirstOutputCannotBecomeOutputTPS() {
        var session = CodexSpeed.Session()
        start(&session)
        output(&session, at: 9)
        usage(&session, at: 10)
        #expect(session.samples.first?.rate == nil)
        #expect(session.samples.first?.waitSeconds == nil)
    }

    @Test func terraAndAstraModelsAreNotFilteredFromSpeedRows() {
        let now = Date()
        let samples = ["gpt-6.1-terra", "gpt-6-astra"].map {
            CodexSpeed.Sample(responseID: $0, model: $0, effort: "", outputTokens: 100,
                              seconds: 5, completedAt: now, waitSeconds: 1, outputSeconds: 4)
        }
        let rows = CodexSpeed.Snapshot(samples: samples, now: now).rows
        #expect(Set(rows.map(\.name)) == ["gpt-6.1-terra", "gpt-6-astra"])
        #expect(rows.allSatisfy { $0.tps == 25 && !$0.includesWait })
    }

    @Test func scannerHandlesOldFoldersPartialAppendsTruncationAndDuplicateFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("sessions/2020/01/01")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("old-chat.jsonl")
        let now = Date()
        let base = floor(now.timeIntervalSince1970) - 10
        let records = [
            record(base, "event_msg", ["type": "task_started", "turn_id": "turn"]),
            record(base, "turn_context", ["turn_id": "turn", "model": "sol", "effort": "low"]),
            record(base + 4, "event_msg", ["type": "item_completed", "turn_id": "turn", "item": ["type": "AgentMessage"], "started_at_ms": (base + 2) * 1000, "completed_at_ms": (base + 4) * 1000]),
            record(base + 4, "response_item", ["type": "message", "role": "assistant"]),
            record(base + 5, "token_usage_record", ["response_id": "resp", "turn_id": "turn", "usage": ["output_tokens": 100]])
        ]
        let lines = try records.map { try JSONSerialization.data(withJSONObject: $0) }
        var data = Data()
        let usageLine = try #require(lines.last)
        for line in lines.dropLast() { data.append(line); data.append(10) }
        data.append(usageLine.prefix(15))
        try data.write(to: file)
        let scanner = CodexSpeedScanner(home: root)
        #expect(scanner.scan(now: now).samples.isEmpty)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: usageLine.dropFirst(15) + Data([10]))
        try handle.close()
        #expect(scanner.scan(now: now).samples.first?.outputSeconds == 3)
        #expect(scanner.scan(now: now).samples.count == 1)
        try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent("fork.jsonl"))
        #expect(scanner.scan(now: now.addingTimeInterval(16)).samples.count == 1)
        try Data().write(to: file)
        try Data().write(to: folder.appendingPathComponent("fork.jsonl"))
        #expect(scanner.scan(now: now.addingTimeInterval(17)).samples.isEmpty)
    }

    @Test func scannerRecoversTurnContextBeforeTwoMegabyteTail() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("sessions/2026/11/18")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("large.jsonl")
        let now = Date()
        let base = floor(now.timeIntervalSince1970) - 20
        var data = Data()
        let headRecords: [[String: Any]] = [
            record(base, "event_msg", ["type": "task_started", "turn_id": "turn-1"]),
            record(base, "turn_context", ["turn_id": "turn-1", "model": "gpt-6.1-sol", "effort": "max"])
        ]
        for rec in headRecords {
            data.append(try JSONSerialization.data(withJSONObject: rec))
            data.append(10)
        }
        let padLine = try JSONSerialization.data(withJSONObject: record(base + 1, "response_item", ["type": "function_call_output", "output": String(repeating: "x", count: 8192)]))
        while data.count < 2_200_000 {
            data.append(padLine)
            data.append(10)
        }
        let tailRecords: [[String: Any]] = [
            record(base + 5, "response_item", ["type": "function_call_output"]),
            record(base + 6, "event_msg", ["type": "item_completed", "turn_id": "turn-1", "item": ["type": "AgentMessage"], "started_at_ms": (base + 6) * 1000, "completed_at_ms": (base + 9) * 1000]),
            record(base + 9, "response_item", ["type": "message", "role": "assistant"]),
            record(base + 10, "token_usage_record", [
                "response_id": "resp-tail",
                "turn_id": "turn-1",
                "usage": ["input_tokens": 100_000, "cached_input_tokens": 95_000, "output_tokens": 500]
            ])
        ]
        for rec in tailRecords {
            data.append(try JSONSerialization.data(withJSONObject: rec))
            data.append(10)
        }
        try data.write(to: file)
        let scanner = CodexSpeedScanner(home: root)
        let snapshot = scanner.scan(now: now)
        let row = try #require(snapshot.rows.first { $0.name == "gpt-6.1-sol" })
        #expect(row.tps == 125)
        #expect(row.cachePercent == 95)
    }

    @Test func ttftUsesMedianToResistRetryOutliers() throws {
        let now = Date()
        let samples = [2.0, 3.0, 150.0].enumerated().map { idx, wait in
            CodexSpeed.Sample(responseID: "w-\(idx)", model: "Gemini 4 Hydrogen", effort: "Medium",
                              outputTokens: 300, seconds: wait + 2, completedAt: now,
                              waitSeconds: wait, outputSeconds: 2)
        }
        let row = try #require(CodexSpeed.Snapshot(samples: samples, now: now).rows.first)
        #expect(row.ttft == 3.0)
        #expect(row.tps == 150)
    }
}
