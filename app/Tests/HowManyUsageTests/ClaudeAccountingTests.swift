import Foundation
import Testing
@testable import HowManyUsage

struct ClaudeAccountingTests {
    @Test func sonnet55UsesVerifiedRatesAndUnknownVersionsHaveNoFallback() throws {
        let cost = try #require(ClaudeValue.cost(model: "claude-sonnet-5-5", input: 1_000_000,
            cacheCreate5m: 1_000_000, cacheCreate1h: 1_000_000, cacheRead: 1_000_000, output: 1_000_000))
        #expect(abs(cost - 18.6) < 0.000001)
        #expect(ClaudeValue.pricing(for: "claude-sonnet-5-5-20260928")?.cacheRead == 0.1e-6)
        for model: String? in [nil, "", "claude-sonnet-future", "claude-opus-5-5-unknown"] {
            #expect(ClaudeValue.cost(model: model, input: 100, cacheCreate5m: 0,
                cacheCreate1h: 0, cacheRead: 0, output: 10) == nil)
        }
    }

    @Test func haiku55TierIncludesCacheTokensAndUsesStrictThreshold() throws {
        let low = try #require(ClaudeValue.cost(model: "claude-haiku-5-5", input: 20_000,
            cacheCreate5m: 0, cacheCreate1h: 0, cacheRead: 80_000, output: 10_000))
        #expect(abs(low - 0.0078) < 0.0000001)
        let high = try #require(ClaudeValue.cost(model: "claude-haiku-5-5-20261008", input: 20_000,
            cacheCreate5m: 0, cacheCreate1h: 0, cacheRead: 90_000, output: 10_000))
        #expect(abs(high - 0.0395) < 0.0000001)
        #expect(ClaudeValue.pricing(for: "claude-haiku") == nil)
    }

    @Test func recursiveUsageDeduplicatesCopiesAndIncrementalAppends() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent(".claude/projects/project")
        let child = project.appendingPathComponent("session/subagents/agent-child.jsonl")
        try FileManager.default.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
        let now = Date(), boundary = now.addingTimeInterval(-900)
        let userTime = now.addingTimeInterval(-800)
        func record(_ type: String, id: String = "", model: String = "", output: Int = 0, time: Date) throws -> Data {
            var message: [String: Any] = ["content": []]
            if type == "assistant" {
                message["id"] = id; message["model"] = model
                message["usage"] = ["input_tokens": 1_000_000, "output_tokens": output]
            }
            let value: [String: Any] = ["type": type, "timestamp": ISO8601DateFormatter().string(from: time),
                "requestId": id, "message": message]
            var data = try JSONSerialization.data(withJSONObject: value); data.append(10); return data
        }
        let parent = project.appendingPathComponent("session.jsonl")
        var data = try record("user", time: userTime)
        data += try record("assistant", id: "parent", model: "claude-opus-5-5", output: 1_000_000, time: userTime.addingTimeInterval(10))
        data += try record("assistant", id: "shared", model: "claude-sonnet-5-5", output: 500_000, time: userTime.addingTimeInterval(20))
        try data.write(to: parent)
        func scan(_ cutoff: Date) -> TodayStatsScanner.Partial {
            TodayStatsScanner.scanClaude(home: home, now: now, cutoff: cutoff,
                weekStart: boundary.addingTimeInterval(-86400), todayStart: boundary,
                tomorrowStart: now.addingTimeInterval(86400), windowStart: boundary)
        }
        #expect(abs(scan(boundary).claudeWindowCost - 31) < 0.000001)
        var childData = try record("user", time: userTime)
        let completed = try record("assistant", id: "shared", model: "claude-sonnet-5-5", output: 1_000_000, time: userTime.addingTimeInterval(30))
        childData += completed
        var messageOnly = try JSONSerialization.jsonObject(with: completed) as! [String: Any]
        messageOnly.removeValue(forKey: "requestId")
        childData += try JSONSerialization.data(withJSONObject: messageOnly)
        childData.append(10)
        try childData.write(to: child)
        let result = scan(now.addingTimeInterval(-1))
        #expect(abs(result.claudeWindowCost - 36) < 0.000001)
        #expect(result.claudeTodayTokens == 4_000_000)
        #expect(result.instructions == 0)
        #expect(scan(boundary).instructions == 1) // Child's task prompt is not a human instruction.
        #expect(!result.claudeWindowUnpriced)
        #expect(abs(scan(now.addingTimeInterval(-1)).claudeWindowCost - 36) < 0.000001)
        try record("assistant", id: "unknown", model: "unpriced-model", output: 1_000_000,
            time: userTime.addingTimeInterval(40)).write(to: project.appendingPathComponent("unknown.jsonl"))
        // Without a start boundary it is not admissible, so it cannot contaminate the window.
        #expect(!scan(boundary).claudeWindowUnpriced)
        var unknownData = try record("user", time: userTime)
        unknownData += try record("assistant", id: "unknown", model: "unpriced-model", output: 1_000_000,
            time: userTime.addingTimeInterval(40))
        try unknownData.write(to: project.appendingPathComponent("unknown.jsonl"))
        #expect(scan(boundary).claudeWindowUnpriced)
    }

    @Test func windowMismatchAndUnknownPricingSuppressOldValuations() {
        let boundary = Date()
        var stats = TodayStats(claudeWindowCostUSD: 10, claudeWindowStart: boundary, claudeWindowUnpriced: false)
        #expect(ClaudeValue.monthlyValue(stats: stats, boundary: boundary, usedPercent: 10) != nil)
        stats.claudeWindowUnpriced = true
        #expect(ClaudeValue.monthlyValue(stats: stats, boundary: boundary, usedPercent: 10) == nil)
        stats.claudeWindowUnpriced = false
        #expect(ClaudeValue.monthlyValue(stats: stats, boundary: boundary.addingTimeInterval(1), usedPercent: 10) == nil)
    }

    @Test func speedHeadingOmitsEstimateLabel() {
        #expect(!CodexSpeed.Snapshot().lines[0].contains("est."))
    }
}
