import Foundation
import Testing
@testable import HowManyUsage

/// Exercise the intersections of window recounting, bounded reads and numeric safety.
struct MergedRegressionTests {
    private let boundary = Date(timeIntervalSince1970: 1_794_787_200) // 2026-11-16 00:00 UTC

    private func home() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ data: Data, to path: String, home: URL) throws -> URL {
        let file = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    private func jsonl(_ rows: [[String: Any]]) throws -> Data {
        var data = Data()
        for row in rows {
            data.append(try JSONSerialization.data(withJSONObject: row))
            data.append(10)
        }
        return data
    }

    private func stamp(_ seconds: Double) -> String {
        ISO8601DateFormatter().string(from: boundary.addingTimeInterval(seconds))
    }

    @Test func delayedCanonicalTailSurvivesBadUTF8AndRecountsBothIndexes() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let input = 9_007_199_254_740_993
        let usage: [String: Any] = ["input_tokens": input, "cached_input_tokens": 0, "output_tokens": 10]
        var prefix = try jsonl([
            ["timestamp": stamp(1), "type": "event_msg", "payload": ["type": "user_message", "message": "fixture"]],
            ["timestamp": stamp(1), "type": "turn_context", "payload": ["model": "gpt-6.1-sol"]]
        ])
        prefix.append(contentsOf: [0xff, 10])
        let canonical = try jsonl([["timestamp": stamp(2), "type": "token_usage_record",
                                    "payload": ["response_id": "merged-response", "usage": usage]]])
        let split = canonical.count / 2
        let file = try write(prefix + canonical.prefix(split), to: ".codex/sessions/2020/01/01/resumed.jsonl", home: home)
        let now = boundary.addingTimeInterval(60)
        func stats() -> TodayStats { TodayStatsScanner.scan(home: home, now: now, windowStarts: ["codex": boundary]) }
        #expect(stats().tokens == 0)
        #expect(UsageHistoryScanner.scan(home: home, now: now).days.last?.codex == 0)

        let legacy = try jsonl([["timestamp": stamp(3), "type": "event_msg", "payload": ["type": "token_count",
            "info": ["last_token_usage": usage, "total_token_usage": usage],
            "rate_limits": ["secondary": ["window_minutes": 10080, "used_percent": 7]]]]])
        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd()
        try writer.write(contentsOf: canonical.dropFirst(split) + canonical + legacy + legacy)
        try writer.close()
        for _ in 0..<2 {
            let current = stats()
            #expect(current.tokens == input + 10)
            #expect(current.codexWindowTokens == input + 10)
            #expect(current.codexWindowPct == 7)
            #expect(current.instructions == 1)
            #expect(UsageHistoryScanner.scan(home: home, now: now).days.last?.codex == input + 10)
        }
        try prefix.write(to: file)
        #expect(stats().tokens == 0)
        #expect(stats().codexWindowCostUSD == nil)
        #expect(UsageHistoryScanner.scan(home: home, now: now).days.last?.codex == 0)
    }

    @Test func canonicalAndLegacyHugeCountsSaturateWithoutAcceptingBooleanPercent() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let usage: [String: Any] = ["input_tokens": Int.max, "cached_input_tokens": Int.max, "output_tokens": Int.max]
        _ = try write(jsonl([
            ["timestamp": stamp(1), "type": "turn_context", "payload": ["model": "gpt-6.1-sol"]],
            ["timestamp": stamp(2), "type": "token_usage_record", "payload": ["response_id": "huge", "usage": usage]],
            ["timestamp": stamp(3), "type": "event_msg", "payload": ["type": "token_count",
                "info": ["last_token_usage": usage, "total_token_usage": usage],
                "rate_limits": ["secondary": ["window_minutes": 10080, "used_percent": true]]]]
        ]), to: ".codex/sessions/2020/01/01/huge.jsonl", home: home)
        let now = boundary.addingTimeInterval(60)
        let current = TodayStatsScanner.scan(home: home, now: now, windowStarts: ["codex": boundary])
        #expect(current.tokens == Int.max)
        #expect(current.codexWindowTokens == Int.max)
        #expect(current.codexWindowCostUSD?.isFinite == true)
        #expect(current.codexWindowPct == nil)
        #expect(UsageHistoryScanner.scan(home: home, now: now).days.last?.total == Int.max)
        _ = try JSONEncoder().encode(current)
    }

    @Test func deepSeekBoundedTailAndModernCarriersShareSaturatingCounts() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let start = boundary.addingTimeInterval(-8 * 3600) // CST midnight
        func pi(_ seconds: Double, _ count: Int) -> [String: Any] {
            ["timestamp": ISO8601DateFormatter().string(from: start.addingTimeInterval(seconds)),
             "message": ["provider": "deepseek", "usage": ["input": count, "output": count, "totalTokens": count]]]
        }
        var prefix = try jsonl([pi(-1, 1000), pi(0, 10), pi(120, 2000)])
        prefix.append(contentsOf: [0xff, 10])
        let tail = try jsonl([pi(1, Int.max)])
        let file = try write(prefix + tail.prefix(tail.count / 2), to: ".pi/agent/sessions/test/live.jsonl", home: home)
        let now = start.addingTimeInterval(60)
        #expect(PiUsage.todayDeepSeek(home: home, now: now).totalTokens == 10)
        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd()
        try writer.write(contentsOf: tail.dropFirst(tail.count / 2))
        try writer.close()
        let pi = PiUsage.todayDeepSeek(home: home, now: now)
        #expect(pi.inputTokens == Int.max)
        #expect(pi.outputTokens == Int.max)
        #expect(pi.totalTokens == Int.max)
        #expect(pi.cost.isFinite)

        let usage: [String: Any] = ["inputTokens": Int.max, "cacheReadTokens": Int.max, "outputTokens": Int.max]
        let text = try jsonl([
            ["type": "request/context", "data": ["provider": "deepseek-official", "model": "deepseek-v4-flash"]],
            ["type": "assistant/chunk", "time": start.timeIntervalSince1970 * 1000,
             "data": ["turn": 1, "step": 1, "chunk": ["type": "usage", "usage": usage]]],
            ["type": "assistant/message", "time": start.timeIntervalSince1970 * 1000,
             "data": ["turn": 1, "step": 1, "usage": usage]]
        ])
        let dsh = PiUsage.dshUsage(String(decoding: text, as: UTF8.self), start: start, end: now)
        #expect(dsh.input == Int.max)
        #expect(dsh.output == Int.max)
        #expect(dsh.total == Int.max)
        let expectedCost = Double(Int.max) * (0.14 + 0.28 + 0.0028) / 1e6
        #expect(abs(dsh.costUSD / expectedCost - 1) < 0.000001)
    }

    @Test func versionTwoIndexIsRebuiltEvenWhenLogMetadataIsUnchanged() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try write(jsonl([["type": "PLANNER_RESPONSE", "created_at": stamp(1), "step_index": 0,
                             "input_tokens": 10, "output_tokens": 5]]),
            to: ".gemini/antigravity/brain/test/.system_generated/logs/transcript.jsonl", home: home)
        let now = boundary.addingTimeInterval(60)
        #expect(UsageHistoryScanner.scan(home: home, now: now).days.last?.antigravity == 15)
        let indexURL = home.appendingPathComponent(".config/howmanyusage/usage-history-index.json")
        var index = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
        #expect(index["version"] as? Int == 3)
        index["version"] = 2
        var files = try #require(index["files"] as? [String: [String: Any]])
        let key = try #require(files.keys.first)
        var cached = try #require(files[key])
        var days = try #require(cached["days"] as? [[String: Any]])
        days[0]["antigravity"] = 999
        cached["days"] = days
        files[key] = cached
        index["files"] = files
        try JSONSerialization.data(withJSONObject: index).write(to: indexURL)
        var reads = 0
        let rebuilt = UsageHistoryScanner.scan(home: home, now: now, onFileRead: { _ in reads += 1 })
        #expect(reads == 1)
        #expect(rebuilt.days.last?.antigravity == 15)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
        #expect(saved["version"] as? Int == 3)
    }
}
