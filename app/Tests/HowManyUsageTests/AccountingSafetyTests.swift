import Foundation
import Testing
@testable import HowManyUsage

struct AccountingSafetyTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot(at date: Date, pct: Double?, reset: String) -> UsageSnapshot {
        UsageSnapshot(ts: date, codexWeekly: pct, codexWeeklyReset: reset,
                      claudeWeekly: nil, claudeWeeklyReset: nil, claude5h: nil, claude5hReset: nil,
                      dsBalance: nil, dsTodayTokens: nil)
    }

    @Test func corruptResetCannotStartAnUnboundedForecastLoop() {
        for reset in ["NaN", "Infinity", "1e300", "-1e300"] {
            let history = [snapshot(at: now.addingTimeInterval(-86400), pct: 10, reset: reset),
                           snapshot(at: now, pct: 20, reset: reset)]
            #expect(TodayStatsScanner.quotaPace(id: "codex", history: history, now: now) == nil)
        }
        #expect(!TodayStatsScanner.exhaustionWorthy(id: "codex", exhaustsIn: 1, reset: .infinity))
    }

    @Test func paceExcludesEarlierManualResetSegments() throws {
        let resetDate = now.addingTimeInterval(4 * 3600)
        let reset = String(resetDate.timeIntervalSince1970)
        let history = [snapshot(at: now.addingTimeInterval(-2 * 86400), pct: 80, reset: reset),
                       snapshot(at: now.addingTimeInterval(-86400), pct: 5, reset: reset),
                       snapshot(at: now, pct: 15, reset: reset)]
        let pace = try #require(TodayStatsScanner.quotaPace(id: "codex", history: history, now: now, resetAt: resetDate))
        #expect(pace.dailyRate == 10)
        #expect(try #require(pace.projectedAtReset) >= 15)
        #expect(TodayStatsScanner.quotaPace(id: "codex", history: history, now: now,
                                          resetAt: resetDate.addingTimeInterval(3600)) == nil)
    }

    @Test func liveGeminiLogKeepsValidUsageDespiteCorruptTailAndHugeCounters() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".gemini/antigravity/brain/test/.system_generated/logs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let record: [String: Any] = ["type": "PLANNER_RESPONSE", "model": "gemini-flash",
            "created_at": timestamp, "step_index": 0, "input_tokens": Int.max, "output_tokens": Int.max]
        var data = try JSONSerialization.data(withJSONObject: record)
        data.append(10); data.append(contentsOf: [0xe4, 0xb8])
        try data.write(to: directory.appendingPathComponent("transcript.jsonl"))
        let start = now.addingTimeInterval(-3600)
        let partial = TodayStatsScanner.scanAntigravity(home: home, now: now, cutoff: start,
            weekStart: start, todayStart: start, tomorrowStart: now.addingTimeInterval(86400), windowStart: start)
        #expect(partial.antigravityWindowTokens == Int.max)
        #expect(partial.antigravityTodayTokens == Int.max)
        let fallback = AntigravityUsage.windowTotals(since: start, home: home, now: now)
        #expect(fallback.tokens == Int.max)
        #expect(fallback.costUSD.isFinite)
    }
}
