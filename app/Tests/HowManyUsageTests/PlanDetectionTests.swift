import Foundation
import Testing
@testable import HowManyUsage

struct PlanDetectionTests {
    @Test func testClaudeUsesSubscriptionAndRateLimitTier() {
        #expect(ClaudeValue.planName(subscriptionType: "pro", rateLimitTier: "default_claude_ai") == "pro")
        #expect(ClaudeValue.planName(subscriptionType: "max", rateLimitTier: "default_claude_max_5") == "max 5x")
        #expect(ClaudeValue.planName(subscriptionType: "max", rateLimitTier: "default_claude_max_20") == "max 20x")
        #expect(ClaudeValue.planPriceMonthly(for: "max 5x") == 100)
        #expect(ClaudeValue.planPriceMonthly(for: "max 20x") == 200)
    }

    @Test func testCodexNormalizesPlanTypeAndKeepsUnknownPlansSafe() {
        #expect(CodexValue.planName(for: "plus") == "plus")
        #expect(CodexValue.planPriceMonthly(for: "plus") == 20)
        #expect(CodexValue.planName(for: "prolite") == "pro 5x")
        #expect(CodexValue.planPriceMonthly(for: "prolite") == 100)
        #expect(CodexValue.displayPlanName(for: "pro 5x") == "5x")
        #expect(CodexValue.planPriceMonthly(for: "pro 5x") == 100)
        #expect(CodexValue.planName(for: "pro_20x") == "pro 20x")
        #expect(CodexValue.planPriceMonthly(for: "pro 20x") == 200)
        #expect(CodexValue.displayPlanName(for: "pro 20x") == "20x")
        #expect(CodexValue.planName(for: "pro") == "pro")
        #expect(CodexValue.displayPlanName(for: "pro") == "pro")
        #expect(CodexValue.planPriceMonthly(for: "pro") == nil)
        #expect(CodexValue.planName(for: "enterprise") == "enterprise")
        #expect(CodexValue.planPriceMonthly(for: "enterprise") == nil)
    }

    @Test func testCodexPricesCurrentModelsWithSolFallback() {
        let usage = (input: 1_000_000, cached: 500_000, output: 100_000)
        #expect(abs((CodexValue.cost(model: "gpt-6.1-sol", input: usage.input, cachedInput: usage.cached, output: usage.output) ?? -1) - 2.05) <= 0.000001)
        #expect(abs((CodexValue.cost(model: "gpt-6.1-sol-2026-09-29", input: usage.input, cachedInput: usage.cached, output: usage.output) ?? -1) - 2.05) <= 0.000001)
        #expect(abs((CodexValue.cost(model: "gpt-6-astra", input: usage.input, cachedInput: usage.cached, output: usage.output) ?? -1) - 10.5) <= 0.000001)
        #expect(abs((CodexValue.cost(model: "gpt-6-sol", input: usage.input, cachedInput: usage.cached, output: usage.output) ?? -1) - 2.1) <= 0.000001)
        #expect(abs((CodexValue.cost(model: "gpt-6-luna", input: usage.input, cachedInput: usage.cached, output: usage.output) ?? -1) - 0.105) <= 0.000001)
        #expect(abs((CodexValue.cost(model: "gpt-5.6-sol", input: usage.input, cachedInput: usage.cached, output: usage.output) ?? -1) - 4.2) <= 0.000001)
        for model: String? in ["codex-auto-review", "gpt-6-unpriced", nil, ""] {
            #expect(abs((CodexValue.cost(model: model, input: usage.input, cachedInput: usage.cached, output: usage.output) ?? -1) - 2.05) <= 0.000001)
        }
    }

    @Test func testCodexValueCanEstimateFromFirstPercent() {
        #expect(CodexValue.extrapolate(costSoFar: 0, pctSoFar: 0) == nil)
        let estimate = CodexValue.extrapolate(costSoFar: 1, pctSoFar: 1)
        #expect(estimate?.weekly == 100)
        #expect(abs((estimate?.monthly ?? 0) - 100 * 30.44 / 7) <= 0.000001)
    }

    @Test func testClaudeOpus55PricesAllCacheTiers() {
        let cost = ClaudeValue.cost(model: "claude-opus-5-5", input: 1_000_000,
                                    cacheCreate5m: 1_000_000, cacheCreate1h: 1_000_000,
                                    cacheRead: 1_000_000, output: 1_000_000)
        #expect(abs((cost ?? -1) - (4 + 5 + 8 + 0.2 + 20)) <= 0.000001)
    }

    @Test func testQuotaValueCarriesPriorWindowThroughReset() {
        #expect(QuotaValueEstimate.isResetDrop(from: 95, to: 1))
        #expect(!(QuotaValueEstimate.isResetDrop(from: 11, to: 10)))
        let before = QuotaValueEstimate.updated(nil, resetEpoch: 1_000,
                                                 observedPercent: 95, rawMonthlyUSD: 900)
        let after = QuotaValueEstimate.updated(before, resetEpoch: 605_800,
                                                observedPercent: 1, rawMonthlyUSD: 100)
        #expect(after?.previousMonthlyUSD == 900)
        #expect(abs((after?.monthlyUSD ?? 0) - 860) <= 0.000001)
        let mature = QuotaValueEstimate.updated(after, resetEpoch: 605_800,
                                                 observedPercent: 20, rawMonthlyUSD: 700)
        #expect(mature?.monthlyUSD == 700)
        let detectedByPercent = QuotaValueEstimate.updated(before, resetEpoch: 1_000,
                                                            observedPercent: 1, rawMonthlyUSD: 100)
        #expect(detectedByPercent?.previousMonthlyUSD == 900)
    }

    @Test func testCodexWindowsFollowDurationNotPrimarySecondaryNames() {
        let primary: [String: Any] = [
            "window_minutes": 300,
            "used_percent": 19,
        ]
        let secondary: [String: Any] = [
            "window_minutes": 10_080,
            "used_percent": 3,
        ]

        let windows = Providers.codexWindows(primary: primary, secondary: secondary)
        #expect(windows.fiveHour?.kind == "fiveHour")
        #expect(windows.fiveHour?.usedPercent == 19)
        #expect(windows.weekly?.kind == "weekly")
        #expect(windows.weekly?.usedPercent == 3)
    }

    @Test func testCodexWindowsKeepLegacyFallbackWhenDurationIsMissing() {
        let primary: [String: Any] = ["used_percent": 22]
        let secondary: [String: Any] = ["used_percent": 3]

        let windows = Providers.codexWindows(primary: primary, secondary: secondary)
        #expect(windows.weekly?.usedPercent == 22)
        #expect(windows.fiveHour?.usedPercent == 3)
    }

    @Test func testTodayDeltaCreatesAQuietBarGap() {
        let bar = Render.barString(34, width: 20, todayDelta: 5)
        #expect(Array(bar)[5] == Character("\u{200A}"))
        #expect(Array(bar)[6] == Character("█"))
        #expect(!(bar.contains("today")))
        #expect(!(Render.barString(34, width: 20, todayDelta: 0.4).contains("\u{200A}")))
    }

    @Test func testAntigravitySummaryAggregatesCLIAndClientTranscripts() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let clientLogs = home.appendingPathComponent(".gemini/antigravity/brain/conv-client/.system_generated/logs", isDirectory: true)
        let cliLogs = home.appendingPathComponent(".gemini/antigravity-cli/brain/conv-cli/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: clientLogs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cliLogs, withIntermediateDirectories: true)

        try """
        {"step_index":1,"type":"PLANNER_RESPONSE","created_at":"2026-11-04T10:00:00Z","input_tokens":10000,"cache_read_tokens":90000,"cache_write_tokens":0,"output_tokens":2000}
        """.write(to: clientLogs.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        try """
        {"step_index":1,"type":"PLANNER_RESPONSE","created_at":"2026-11-03T10:00:00Z","input_tokens":5000,"cache_read_tokens":25000,"cache_write_tokens":0,"output_tokens":1000}
        """.write(to: cliLogs.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        let now = ISO8601DateFormatter().date(from: "2026-11-04T12:00:00Z")!
        let summary = AntigravityUsage.summary(home: home, now: now, useCache: false)
        #expect(summary.today.totalTokens == 102_000)
        #expect(summary.fiveHourTokens == 102_000)
        #expect(summary.weeklyTokens == 133_000)
        #expect(summary.cliTokens == 31_000)
        #expect(summary.clientTokens == 102_000)
        #expect(summary.weekDailyTokens.count == 7)
        #expect(summary.weekDailyTokens[5] == 31_000)
        #expect(summary.weekDailyTokens[6] == 102_000)

        #expect(AntigravityValue.planName(tierId: "g1-ultra-tier", tierName: "Google AI Ultra") == "ultra")
        #expect(AntigravityValue.planPriceMonthly(for: "ultra") == 200)
        #expect(AntigravityValue.planName(tierId: "g1-pro-tier", tierName: "Google AI Pro") == "pro")
        #expect(AntigravityValue.planPriceMonthly(for: "pro") == 20)
        #expect(AntigravityValue.planName(tierId: "free-tier") == "free")
        #expect(AntigravityValue.planPriceMonthly(for: "free") == 0)
        #expect(abs(AntigravityValue.cost(model: nil, input: 10_000, cacheRead: 90_000, cacheWrite: 0, output: 2_000) - 0.0435) < 0.000001)
    }

    @Test func antigravityQuotaUsesOnlyGeminiBuckets() throws {
        let geminiWeeklyReset = "2026-11-14T01:23:24Z"
        let geminiFiveHourReset = "2026-11-13T12:12:06Z"
        let thirdParty: [[String: Any]] = [
            ["bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 0,
             "resetTime": "2026-11-19T08:48:14Z"],
            ["bucketId": "3p-5h", "window": "5h", "remainingFraction": 0.01,
             "resetTime": "2026-11-13T16:03:34Z"],
        ]
        let parsed = Providers.parseAntigravityQuotaSummary([
            "response": [
                "groups": [
                    ["displayName": "Claude and GPT models", "buckets": thirdParty],
                    ["displayName": "Gemini Models", "buckets": [
                        ["bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.04,
                         "resetTime": geminiWeeklyReset],
                    ]],
                ],
                "buckets": [
                    ["bucketId": "gemini-5h", "remainingFraction": 0.88, "resetTime": geminiFiveHourReset],
                ],
            ],
        ])
        let dateFormatter = ISO8601DateFormatter()
        #expect(abs(try #require(parsed.weekly?.usedPercent) - 96.0) < 0.001)
        #expect(abs(try #require(parsed.fiveHour?.usedPercent) - 12.0) < 0.001)
        #expect(parsed.weekly?.resetAt == dateFormatter.date(from: geminiWeeklyReset))
        #expect(parsed.fiveHour?.resetAt == dateFormatter.date(from: geminiFiveHourReset))

        let thirdPartyOnly = Providers.parseAntigravityQuotaSummary(["buckets": thirdParty])
        #expect(thirdPartyOnly.weekly == nil)
        #expect(thirdPartyOnly.fiveHour == nil)
    }
}
