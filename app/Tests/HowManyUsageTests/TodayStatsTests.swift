import Foundation
import Testing
@testable import HowManyUsage

struct TodayStatsTests {
    @Test func shortWindowBurnSpikeDetectsWeeklyAndFiveHourJumpsWithinSameWindow() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let sameReset = "1790600000"
        let earlier = UsageSnapshot(
            ts: now.addingTimeInterval(-1200),
            codexWeekly: 10, codexWeeklyReset: sameReset,
            codex5h: 15, codex5hReset: sameReset,
            claudeWeekly: 20, claudeWeeklyReset: sameReset,
            claude5h: 10, claude5hReset: sameReset,
            antigravityWeekly: 5, antigravityWeeklyReset: sameReset,
            antigravity5h: 8, antigravity5hReset: sameReset,
            dsBalance: 100, dsTodayTokens: nil
        )
        let latest = UsageSnapshot(
            ts: now,
            codexWeekly: 19, codexWeeklyReset: sameReset,
            codex5h: 42, codex5hReset: sameReset,
            claudeWeekly: 25, claudeWeeklyReset: sameReset,
            claude5h: 30, claude5hReset: sameReset,
            antigravityWeekly: 15, antigravityWeeklyReset: "1791200000", // different window: ignore
            antigravity5h: 40, antigravity5hReset: sameReset,
            dsBalance: 86, dsTodayTokens: nil
        )
        let history = [earlier, latest]
        #expect(TodayStatsScanner.quotaSpike(id: "codex", kind: "weekly", history: history, now: now) == 9)
        #expect(TodayStatsScanner.quotaSpike(id: "codex", kind: "fiveHour", history: history, now: now) == 27)
        #expect(TodayStatsScanner.quotaSpike(id: "claude", kind: "weekly", history: history, now: now) == nil)
        #expect(TodayStatsScanner.quotaSpike(id: "claude", kind: "fiveHour", history: history, now: now) == nil)
        #expect(TodayStatsScanner.quotaSpike(id: "antigravity", kind: "weekly", history: history, now: now) == nil)
        #expect(TodayStatsScanner.quotaSpike(id: "antigravity", kind: "fiveHour", history: history, now: now) == 32)
        #expect(TodayStatsScanner.deepSeekBalanceSpike(history: history, now: now) == 14)
    }

    @Test func shortWindowBurnSpikeIgnoresSamplesOutsideLookbackWindow() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let reset = "1790600000"
        let stale = UsageSnapshot(
            ts: now.addingTimeInterval(-3600),
            codexWeekly: 5, codexWeeklyReset: reset,
            claudeWeekly: nil, claudeWeeklyReset: nil, claude5h: nil, claude5hReset: nil,
            dsBalance: 100, dsTodayTokens: nil
        )
        let recent = UsageSnapshot(
            ts: now,
            codexWeekly: 20, codexWeeklyReset: reset,
            claudeWeekly: nil, claudeWeeklyReset: nil, claude5h: nil, claude5hReset: nil,
            dsBalance: 93, dsTodayTokens: nil
        )
        #expect(TodayStatsScanner.quotaSpike(id: "codex", kind: "weekly", history: [stale, recent], now: now) == nil)
        #expect(TodayStatsScanner.deepSeekBalanceSpike(history: [stale, recent], now: now) == nil)
    }

    @Test func testDeepSeekRechargePreservesObservedSpend() {
        let result = PiUsage.balanceSpend([100, 90, 200, 195])
        #expect(result?.cost == 15)
        #expect(result?.rechargeObserved == true)
        #expect(PiUsage.balanceSpend([100, 95])?.cost == 5)
        #expect(PiUsage.balanceSpend([100, 95])?.rechargeObserved == false)
    }

    @Test func testExhaustionForecastRequiresTenPercentTimeBuffer() {
        #expect(!(TodayStatsScanner.exhaustionWorthy(id: "codex", exhaustsIn: 90, reset: 100)))
        #expect(TodayStatsScanner.exhaustionWorthy(id: "codex", exhaustsIn: 89, reset: 100))
    }

    @Test func testExhaustionForecastRejectsInvalidOrPastWindows() {
        #expect(!(TodayStatsScanner.exhaustionWorthy(id: "claude", exhaustsIn: -1, reset: 100)))
        #expect(!(TodayStatsScanner.exhaustionWorthy(id: "claude", exhaustsIn: 10, reset: 0)))
    }

    @Test func scanAntigravityCountsCLIAndClientAndExcludesSubagentPrompts() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let clientDir = home.appendingPathComponent(".gemini/antigravity/brain/conv-1/.system_generated/logs")
        let cliDir = home.appendingPathComponent(".gemini/antigravity-cli/brain/conv-2/.system_generated/logs")
        let subDir = home.appendingPathComponent(".gemini/antigravity/brain/conv-sub/.system_generated/logs")
        for dir in [clientDir, cliDir, subDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-27T06:00:00Z"))
        let todayStart = cal.startOfDay(for: now)
        let weekStart = try #require(cal.date(byAdding: .day, value: -6, to: todayStart))
        let tomorrowStart = try #require(cal.date(byAdding: .day, value: 1, to: todayStart))
        let yesterdayStamp = "2026-10-25T18:00:00Z" // 2026-10-26 02:00 CST (yesterday)
        let todayStamp = "2026-10-27T01:00:00Z"     // 2026-10-27 09:00 CST (today)

        func jsonl(_ records: [[String: Any]]) throws -> String {
            try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        }

        let clientRows: [[String: Any]] = [
            ["step_index": -1, "source": "SYSTEM", "type": "USER_INPUT", "created_at": "2026-10-20T01:00:00Z",
             "content": "The user changed setting `Model Selection` from None to Gemini 3.8 Flash (High). No need to comment."],
            ["step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT", "created_at": yesterdayStamp, "content": "yesterday prompt"],
            ["step_index": 1, "source": "USER_EXPLICIT", "type": "USER_INPUT", "created_at": todayStamp, "content": "today client prompt"],
            ["step_index": 2, "source": "MODEL", "type": "PLANNER_RESPONSE", "created_at": todayStamp,
             "input_tokens": 1000, "cache_read_tokens": 2000, "output_tokens": 100,
             "tool_calls": [["name": "read_file"], ["name": "edit_file"]]]
        ]
        try jsonl(clientRows).write(to: clientDir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        let cliRows: [[String: Any]] = [
            ["step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT", "created_at": todayStamp, "content": "today cli prompt"],
            ["step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "created_at": todayStamp,
             "model": "claude-opus-5-5", "input_tokens": 500, "cache_read_tokens": 500, "cache_write_tokens": 50, "output_tokens": 50,
             "tool_calls": [["name": "run_command"]]]
        ]
        try jsonl(cliRows).write(to: cliDir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        let subRows: [[String: Any]] = [
            ["step_index": 0, "source": "SYSTEM", "type": "SYSTEM_MESSAGE", "created_at": todayStamp, "agent_name": "research"],
            ["step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "created_at": todayStamp,
             "input_tokens": 200, "cache_read_tokens": 100, "output_tokens": 30,
             "tool_calls": [["name": "read_file"]]]
        ]
        try jsonl(subRows).write(to: subDir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        let partial = TodayStatsScanner.scanAntigravity(
            home: home, now: now, cutoff: weekStart,
            weekStart: weekStart, todayStart: todayStart, tomorrowStart: tomorrowStart, windowStart: todayStart
        )
        #expect(partial.antigravityTodayInstructions == 2)
        #expect(partial.antigravityTodayToolCalls == 4)
        // client: 3100, cli: 1100, subagent: 330 => 4530
        #expect(partial.antigravityTodayTokens == 4530)
        #expect(partial.antigravityWeekInstructions == [0, 0, 0, 0, 0, 1, 2])

        let expectedCost = AntigravityValue.cost(model: "Gemini 3.8 Flash", input: 1000, cacheRead: 2000,
                                                 cacheWrite: 0, output: 100)
            + AntigravityValue.cost(model: nil, input: 200, cacheRead: 100, cacheWrite: 0, output: 30)
        let fallback = AntigravityUsage.windowTotals(since: todayStart, home: home, now: now)
        #expect(partial.antigravityWindowTokens == 3430)
        #expect(partial.antigravityWindowCost == expectedCost)
        #expect(fallback.tokens == 3430)
        #expect(fallback.costUSD == expectedCost)
    }

    @Test func todayStatsIndexCacheMatchesColdScanAcrossIncrementalAppends() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }

        let claudeDir = home.appendingPathComponent(".claude/projects/proj")
        let codexDir = home.appendingPathComponent(".codex/sessions/2026/11/18")
        let agyDir = home.appendingPathComponent(".gemini/antigravity/brain/conv-1/.system_generated/logs")
        for dir in [claudeDir, codexDir, agyDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-18T08:00:00Z"))
        let boundary = try #require(ISO8601DateFormatter().date(from: "2026-11-18T00:00:00Z"))
        let ts1 = "2026-11-18T02:00:00Z"
        let ts2 = "2026-11-18T04:00:00Z"

        func jsonl(_ rows: [[String: Any]]) throws -> Data {
            var data = Data()
            for row in rows {
                data.append(try JSONSerialization.data(withJSONObject: row))
                data.append(10)
            }
            return data
        }

        let claudeFile = claudeDir.appendingPathComponent("session.jsonl")
        try jsonl([
            ["type": "user", "timestamp": ts1, "message": ["content": "hi"]],
            ["type": "assistant", "timestamp": ts1, "requestId": "r1",
             "message": ["id": "m1", "model": "claude-sonnet-5-5",
                         "usage": ["input_tokens": 1000, "output_tokens": 200]]]
        ]).write(to: claudeFile)

        let codexFile = codexDir.appendingPathComponent("rollout.jsonl")
        try jsonl([
            ["timestamp": ts1, "type": "turn_context", "payload": ["model": "gpt-6.1-sol"]],
            ["timestamp": ts1, "type": "event_msg", "payload": ["type": "user_message", "message": "go"]],
            ["timestamp": ts1, "type": "token_usage_record",
             "payload": ["response_id": "resp-1",
                         "usage": ["input_tokens": 500, "cached_input_tokens": 0, "output_tokens": 50]]]
        ]).write(to: codexFile)

        let agyFile = agyDir.appendingPathComponent("transcript.jsonl")
        try jsonl([
            ["step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT", "created_at": ts1, "content": "ask"],
            ["step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "created_at": ts1,
             "model": "gemini-4-argon", "input_tokens": 300, "cache_read_tokens": 0, "output_tokens": 30]
        ]).write(to: agyFile)

        let starts = ["claude": boundary, "codex": boundary, "antigravity": boundary]
        let cold = TodayStatsScanner.scan(home: home, now: now, windowStarts: starts)
        let indexURL = home.appendingPathComponent(".config/howmanyusage/today-stats-index.json")
        #expect(FileManager.default.fileExists(atPath: indexURL.path))

        // Second scan hits persisted index and produces identical counts.
        let warm = TodayStatsScanner.scan(home: home, now: now, windowStarts: starts)
        #expect(warm.tokens == cold.tokens)
        #expect(warm.instructions == cold.instructions)
        #expect(warm.claudeWindowTokens == cold.claudeWindowTokens)
        #expect(warm.codexWindowTokens == cold.codexWindowTokens)
        #expect(warm.antigravityWindowTokens == cold.antigravityWindowTokens)

        // Append to Claude log only; cache invalidates for Claude while Codex/Antigravity stay cached.
        let extraClaude = try jsonl([
            ["type": "assistant", "timestamp": ts2, "requestId": "r2",
             "message": ["id": "m2", "model": "claude-sonnet-5-5",
                         "usage": ["input_tokens": 2000, "output_tokens": 400]]]
        ])
        let handle = try FileHandle(forWritingTo: claudeFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: extraClaude)
        try handle.close()

        let updated = TodayStatsScanner.scan(home: home, now: now.addingTimeInterval(60), windowStarts: starts)
        #expect(updated.claudeTodayTokens == 3600)
        #expect(updated.claudeWindowTokens == 3600)
        #expect(updated.codexWindowTokens == 550)
        #expect(updated.antigravityWindowTokens == 330)
    }
}
