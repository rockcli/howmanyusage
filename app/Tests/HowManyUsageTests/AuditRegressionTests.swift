import Foundation
import Testing
@testable import HowManyUsage

struct AuditRegressionTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func jsonl(_ rows: [[String: Any]]) throws -> Data {
        var data = Data()
        for row in rows { data += try JSONSerialization.data(withJSONObject: row); data.append(10) }
        return data
    }
    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }
    private func write(_ data: Data, under home: URL, path: String) throws -> URL {
        let file = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    @Test func googleUsesExplicitGeminiGroupForOpaqueBucketIDs() throws {
        let reset = "2026-11-20T00:00:00Z"
        let result = Providers.parseAntigravityQuotaSummary(["groups": [
            ["displayName": "Claude and GPT models", "buckets": [
                ["bucketId": "claude-weekly", "window": "weekly", "remainingFraction": 0],
                ["bucketId": "orchestrator-5h", "window": "5h", "remainingFraction": 0]]],
            ["displayName": "Gemini Models", "buckets": [
                ["bucketId": "opaque-week", "window": "weekly", "remainingFraction": 0.75, "resetTime": reset],
                ["bucketId": "opaque-short", "window": "5h", "remainingFraction": 0.5, "resetTime": reset]]]
        ]])
        #expect(result.weekly?.usedPercent == 25)
        #expect(result.fiveHour?.usedPercent == 50)
        #expect(result.weekly?.resetAt == date(reset))
        let unrelated = Providers.parseAntigravityQuotaSummary(["buckets": [
            ["bucketId": "orchestrator-weekly", "window": "weekly", "remainingFraction": 0.1]]])
        #expect(unrelated.weekly == nil)
    }

    @Test func googleDistinguishesOmittedZeroFromUnknownQuotaAndKeepsWindowPairing() {
        let reset = "2026-11-20T00:00:00Z"
        for missingReset: Any in [NSNull(), "invalid"] {
            let result = Providers.parseAntigravityQuotaSummary(["buckets": [
                ["bucketId": "gemini-unknown-weekly", "resetTime": missingReset],
                ["bucketId": "gemini-known-weekly", "remainingFraction": 1, "resetTime": reset]]])
            #expect(result.weekly?.usedPercent == 0)
            #expect(result.weekly?.resetAt == date(reset))
        }
        let exhausted = Providers.parseAntigravityQuotaSummary(["buckets": [
            ["bucketId": "gemini-weekly", "resetTime": reset]]])
        #expect(exhausted.weekly?.usedPercent == 100)
        let unknown = Providers.parseAntigravityQuotaSummary(["buckets": [["bucketId": "gemini-weekly"]]])
        #expect(unknown.weekly?.usedPercent == nil)
        let conflicting = Providers.parseAntigravityQuotaSummary(["buckets": [
            ["bucketId": "gemini-weekly", "window": "5h", "remainingFraction": 0.2]]])
        #expect(conflicting.weekly == nil)
        #expect(abs((conflicting.fiveHour?.usedPercent ?? 0) - 80) < 0.000001)
    }

    @Test func nonfiniteProviderNumbersCannotReachRenderingOrJSONState() throws {
        let windows = Providers.codexWindows(primary: ["window_minutes": 10080, "used_percent": "NaN"],
            secondary: ["window_minutes": 300, "used_percent": "Infinity", "reset_at": NSNumber(value: Double.infinity)])
        #expect(windows.weekly?.usedPercent == nil)
        #expect(windows.fiveHour?.usedPercent == nil)
        #expect(windows.fiveHour?.resetAt == nil)
        let huge = Providers.codexWindows(primary: ["window_minutes": 10080, "used_percent": "1e100"], secondary: nil)
        #expect(huge.weekly?.usedPercent == nil)
        let provider = ProviderResult(id: "codex", name: "Codex", plan: nil, weekly: windows.weekly,
            fiveHour: windows.fiveHour, balance: nil, todayUsage: nil, error: nil)
        _ = try JSONEncoder().encode(provider)
        for value in [Double.nan, .infinity, -.infinity, 0] {
            #expect(CodexValue.extrapolate(costSoFar: 1, pctSoFar: value) == nil)
            #expect(CodexValue.extrapolate(costSoFar: value, pctSoFar: 1) == nil)
        }
    }

    @Test func mixedGoogleSessionUsesOnlyAttributedGeminiStepsForQuotaValue() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let boundary = date("2026-11-16T00:00:00Z"), now = date("2026-11-16T02:00:00Z")
        let rows: [[String: Any]] = [
            ["type": "USER_INPUT", "source": "SYSTEM", "created_at": "2026-11-15T00:00:00Z",
             "content": "The user changed setting `Model Selection` from None to Gemini 3.8 Flash (High). No need to comment."],
            ["type": "PLANNER_RESPONSE", "step_index": 1, "created_at": "2026-11-16T01:00:00Z", "input_tokens": 100, "output_tokens": 10],
            ["type": "PLANNER_RESPONSE", "step_index": 2, "created_at": "2026-11-16T01:01:00Z", "model": "Claude Opus", "input_tokens": 900, "output_tokens": 90],
            ["type": "USER_INPUT", "source": "SYSTEM", "created_at": "2026-11-16T01:02:00Z",
             "content": "The user changed setting `Model Selection` from Claude Opus to Orchestrator. No need to comment."],
            ["type": "PLANNER_RESPONSE", "step_index": 3, "created_at": "2026-11-16T01:03:00Z", "input_tokens": 800, "output_tokens": 80],
            ["type": "PLANNER_RESPONSE", "step_index": 4, "created_at": "2026-11-16T01:04:00Z", "model": "gemini-4-argon", "input_tokens": 200, "output_tokens": 20]
        ]
        _ = try write(jsonl(rows), under: home, path: ".gemini/antigravity/brain/mixed/.system_generated/logs/transcript.jsonl")
        _ = try write(jsonl([["type": "PLANNER_RESPONSE", "step_index": 1, "created_at": "2026-11-16T01:00:00Z",
                             "input_tokens": 700, "output_tokens": 70]]), under: home,
                          path: ".gemini/antigravity-cli/brain/unknown/.system_generated/logs/transcript.jsonl")
        let stats = TodayStatsScanner.scan(home: home, now: now, windowStarts: ["antigravity": boundary])
        let fallback = AntigravityUsage.windowTotals(since: boundary, home: home, now: now)
        let cost = AntigravityValue.cost(model: "Gemini 3.8 Flash", input: 100, cacheRead: 0, cacheWrite: 0, output: 10)
            + AntigravityValue.cost(model: "gemini-orchestrator", input: 800, cacheRead: 0, cacheWrite: 0, output: 80)
            + AntigravityValue.cost(model: "gemini-4-argon", input: 200, cacheRead: 0, cacheWrite: 0, output: 20)
            + AntigravityValue.cost(model: nil, input: 700, cacheRead: 0, cacheWrite: 0, output: 70)
        #expect(stats.antigravityTodayTokens == 2970) // All models remain in local activity.
        #expect(stats.antigravityWindowTokens == 1980) // Includes Gemini, Orchestrator, and unattributed subagent; excludes Claude Opus (990).
        #expect(fallback.tokens == 1980)
        #expect(abs((stats.antigravityWindowCostUSD ?? 0) - cost) < 0.0000001)
        #expect(abs(fallback.costUSD - cost) < 0.0000001)
    }

    @Test func codexPricesEveryLiveSlugWithoutInventingUnpublishedRates() {
        let expected: [String: Double] = [
            "gpt-6.1-sol": 2.05, "gpt-6-astra": 10.5, "gpt-6.1-terra": 2.05,
            "gpt-6-sol": 2.1, "gpt-reserve": 2.05, "gpt-6-luna": 0.105,
            "gpt-5.6-sol": 4.2, "gpt-5.6-terra": 2.3, "gpt-5.6-luna": 0.23,
            "codex-auto-review": 2.05,
        ]
        for (model, cost) in expected {
            let actual = CodexValue.cost(model: model, input: 1_000_000, cachedInput: 500_000, output: 100_000)
            #expect(abs((actual ?? -1) - cost) < 0.000001)
        }
    }

    @Test func codexRecountsDelayedTailAndDropsTruncatedContributions() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let boundary = date("2026-11-16T00:00:00Z")
        let prefix = try jsonl([
            ["timestamp": "2026-11-16T00:01:00Z", "type": "event_msg", "payload": ["type": "user_message", "message": "fixture"]],
            ["timestamp": "2026-11-16T00:01:00Z", "type": "turn_context", "payload": ["model": "gpt-6.1-sol", "effort": "ultra"]]
        ])
        let usage = try jsonl([["timestamp": "2026-11-16T00:01:05Z", "type": "event_msg", "payload": [
            "type": "token_count", "info": ["last_token_usage": ["input_tokens": 100, "cached_input_tokens": 80, "output_tokens": 10],
                "total_token_usage": ["input_tokens": 100, "output_tokens": 10]]]]])
        let split = usage.count / 2
        let file = try write(prefix + usage.prefix(split), under: home, path: ".codex/sessions/2020/01/01/resumed.jsonl")
        func scan(_ seconds: Double) -> TodayStats {
            TodayStatsScanner.scan(home: home, now: boundary.addingTimeInterval(seconds), windowStarts: ["codex": boundary])
        }
        #expect(scan(70).tokens == 0)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: usage.dropFirst(split)); try handle.close()
        let completed = scan(80)
        #expect(completed.tokens == 110)
        #expect(completed.codexWindowTokens == 110)
        #expect(completed.instructions == 1)
        #expect(scan(90).tokens == 110)
        try prefix.write(to: file)
        #expect(scan(100).tokens == 0)
        #expect(scan(100).codexWindowCostUSD == nil)
    }

    @Test func codexCanonicalAndRepeatedQuotaNotificationsArePricedOnce() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let boundary = date("2026-11-16T00:00:00Z")
        let firstUsage: [String: Any] = ["input_tokens": 100, "cached_input_tokens": 80, "output_tokens": 10]
        let legacy: [String: Any] = ["timestamp": "2026-11-16T00:01:06Z", "type": "event_msg", "payload": [
            "type": "token_count", "info": ["last_token_usage": firstUsage, "total_token_usage": ["input_tokens": 100, "output_tokens": 10]],
            "rate_limits": ["primary": ["window_minutes": 300, "used_percent": 83], "secondary": ["window_minutes": 10080, "used_percent": 7]]]]
        let canonical: [String: Any] = ["timestamp": "2026-11-16T00:01:05Z", "type": "token_usage_record",
            "payload": ["response_id": "fixture-response", "usage": firstUsage]]
        let rows: [[String: Any]] = [
            ["timestamp": "2026-11-16T00:01:00Z", "type": "turn_context", "payload": ["model": "gpt-6.1-terra"]],
            canonical, canonical, legacy, legacy,
            ["timestamp": "2026-11-16T00:02:00Z", "type": "event_msg", "payload": ["type": "token_count", "info": [
                "last_token_usage": ["input_tokens": 50, "cached_input_tokens": 0, "output_tokens": 10],
                "total_token_usage": ["input_tokens": 150, "output_tokens": 20]]]]
        ]
        _ = try write(jsonl(rows), under: home, path: ".codex/sessions/2020/01/01/resumed.jsonl")
        let stats = TodayStatsScanner.scan(home: home, now: boundary.addingTimeInterval(200), windowStarts: ["codex": boundary])
        #expect(stats.tokens == 170)
        #expect(stats.codexWindowTokens == 170)
        #expect(stats.codexWindowPct == 7)
        #expect(abs((stats.codexWindowCostUSD ?? 0) - 0.000348) < 0.00000001)
    }

    @Test func snapshotCorruptionPreservesHealthyHistoryAndOldShapes() throws {
        let data = Data("""
        [{"ts":1,"codexWeekly":10,"dsBalance":100},
         {"ts":"damaged","codexWeekly":20},
         {"ts":3,"claudeWeekly":30,"dsBalance":95}]
        """.utf8)
        let decoded = try JSONDecoder().decode(SnapshotHistory.self, from: data)
        #expect(decoded.discardedEntries)
        #expect(decoded.snapshots.count == 2)
        #expect(decoded.snapshots[0].codexWeekly == 10)
        #expect(decoded.snapshots[1].claudeWeekly == 30)
        let roundTrip = try JSONDecoder().decode(SnapshotHistory.self, from: JSONEncoder().encode(decoded.snapshots))
        #expect(!roundTrip.discardedEntries)
        #expect(roundTrip.snapshots.map(\.dsBalance) == [100, 95])
    }

    @Test func dshModernUsageDeduplicatesChunksAndCompletedMessagesAtCSTBoundary() throws {
        let start = date("2026-11-16T00:00:00+08:00")
        let ms = start.timeIntervalSince1970 * 1000
        func record(_ type: String, _ offset: Double, _ step: Int, _ count: Int) -> [String: Any] {
            let usage: [String: Any] = ["inputTokens": count, "cacheReadTokens": 20, "outputTokens": 10, "totalTokens": count + 30]
            let body: [String: Any] = type == "assistant/chunk"
                ? ["turn": 1, "step": step, "chunk": ["type": "usage", "usage": usage]]
                : ["turn": 1, "step": step, "usage": usage]
            return ["type": type, "time": ms + offset * 1000, "data": body]
        }
        let data = try jsonl([
            ["type": "request/context", "data": ["provider": "deepseek-official", "model": "deepseek-v4-flash"]],
            record("assistant/message", -1, 0, 1000),
            record("assistant/chunk", 0, 1, 80), record("assistant/message", 1, 1, 100),
            record("assistant/message", 1, 1, 100), record("assistant/message", 61, 2, 2000),
            ["type": "request/context", "data": ["provider": "other", "model": "other"]],
            record("assistant/message", 2, 3, 3000)
        ])
        let usage = PiUsage.dshUsage(String(decoding: data, as: UTF8.self), start: start, end: start.addingTimeInterval(60))
        #expect(usage.input == 100)
        #expect(usage.output == 10)
        #expect(usage.total == 130)
        #expect(abs(usage.costUSD - 0.000016856) < 0.000000001)
    }

    @Test func deepSeekPiUsageHonorsCSTMidnightAndRejectsFutureRecords() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        func row(_ stamp: String, _ total: Int) -> [String: Any] {
            ["timestamp": stamp, "message": ["provider": "deepseek", "usage": ["input": total, "output": 0, "totalTokens": total]]]
        }
        _ = try write(jsonl([row("2026-11-15T15:59:59Z", 1000), row("2026-11-15T16:00:00Z", 100),
                            row("2026-11-16T01:00:00Z", 2000)]), under: home, path: ".pi/agent/sessions/project/session.jsonl")
        let usage = PiUsage.todayDeepSeek(home: home, now: date("2026-11-15T16:01:00Z"))
        #expect(usage.totalTokens == 100)
    }

    @Test func dshUsageDeduplicatesAcrossMidnightBoundaryWithoutDoubleCounting() throws {
        let day1Start = date("2026-11-16T00:00:00+08:00")
        let midnight = date("2026-11-17T00:00:00+08:00")
        let day2End = date("2026-11-17T23:59:59+08:00")
        func dshRow(_ type: String, _ ts: Date, _ step: Int, _ input: Int) -> [String: Any] {
            let usage: [String: Any] = ["inputTokens": input, "cacheReadTokens": 20, "outputTokens": 10, "totalTokens": input + 30]
            let body: [String: Any] = type == "assistant/chunk"
                ? ["turn": 1, "step": step, "chunk": ["type": "usage", "usage": usage]]
                : ["turn": 1, "step": step, "usage": usage]
            return ["type": type, "time": ts.timeIntervalSince1970 * 1000, "data": body]
        }

        // Case 1: equal count emitted before and after CST midnight.
        let equalText = String(decoding: try jsonl([
            ["type": "request/context", "data": ["provider": "deepseek-official", "model": "deepseek-v4-flash"]],
            dshRow("assistant/chunk", midnight.addingTimeInterval(-1), 1, 100),
            dshRow("assistant/message", midnight.addingTimeInterval(1), 1, 100)
        ]), as: UTF8.self)
        let eqDay1 = PiUsage.dshUsage(equalText, start: day1Start, end: midnight.addingTimeInterval(-0.001))
        let eqDay2 = PiUsage.dshUsage(equalText, start: midnight, end: day2End)
        let eqCombined = PiUsage.dshUsage(equalText, start: day1Start, end: day2End)
        #expect(eqDay1.total == 130)
        #expect(eqDay2.total == 0)
        #expect(eqDay1.total + eqDay2.total == eqCombined.total)

        // Case 2: larger completed message after CST midnight supersedes pre-midnight chunk.
        let grownText = String(decoding: try jsonl([
            ["type": "request/context", "data": ["provider": "deepseek-official", "model": "deepseek-v4-flash"]],
            dshRow("assistant/chunk", midnight.addingTimeInterval(-1), 2, 80),
            dshRow("assistant/message", midnight.addingTimeInterval(1), 2, 100)
        ]), as: UTF8.self)
        let grDay1 = PiUsage.dshUsage(grownText, start: day1Start, end: midnight.addingTimeInterval(-0.001))
        let grDay2 = PiUsage.dshUsage(grownText, start: midnight, end: day2End)
        let grCombined = PiUsage.dshUsage(grownText, start: day1Start, end: day2End)
        #expect(grDay1.total == 0)
        #expect(grDay2.total == 130)
        #expect(grDay1.total + grDay2.total == grCombined.total)
    }

    @Test func codexFirstTurnAfterResetIsNotDroppedBySubsequentQuotaDropNotification() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let boundary = date("2026-11-16T00:00:00Z")
        let iso = ISO8601DateFormatter()
        let firstUsage: [String: Any] = ["input_tokens": 100, "cached_input_tokens": 80, "output_tokens": 10]
        let rows: [[String: Any]] = [
            ["timestamp": iso.string(from: boundary.addingTimeInterval(-10)), "type": "event_msg", "payload": [
                "type": "token_count",
                "rate_limits": ["secondary": ["window_minutes": 10080, "used_percent": 95]]]],
            ["timestamp": iso.string(from: boundary), "type": "turn_context", "payload": ["model": "gpt-6.1-terra"]],
            ["timestamp": iso.string(from: boundary.addingTimeInterval(1)), "type": "token_usage_record",
             "payload": ["response_id": "first-post-reset", "usage": firstUsage]],
            ["timestamp": iso.string(from: boundary.addingTimeInterval(2)), "type": "event_msg", "payload": [
                "type": "token_count",
                "info": ["last_token_usage": firstUsage, "total_token_usage": ["input_tokens": 100, "output_tokens": 10]],
                "rate_limits": ["secondary": ["window_minutes": 10080, "used_percent": 1]]]]
        ]
        _ = try write(jsonl(rows), under: home, path: ".codex/sessions/2026/11/16/resumed.jsonl")
        let expectedCost = try #require(CodexValue.cost(model: "gpt-6.1-terra", input: 100, cachedInput: 80, output: 10))

        let stats = TodayStatsScanner.scan(home: home, now: boundary.addingTimeInterval(60),
                                           windowStarts: ["codex": boundary])
        #expect(stats.codexWindowTokens == 110)
        #expect(stats.codexWindowPct == 1)
        #expect(abs((stats.codexWindowCostUSD ?? 0) - expectedCost) < 1e-8)

        let unknownBoundary = TodayStatsScanner.scan(home: home, now: boundary.addingTimeInterval(60),
                                                     windowStarts: [:])
        #expect(unknownBoundary.codexWindowTokens == nil)
        #expect(unknownBoundary.codexWindowCostUSD == nil)
        #expect(unknownBoundary.codexWindowPct == 1)
    }
}
