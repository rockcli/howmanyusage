import Foundation
import Testing
@testable import HowManyUsage

struct ResetAccountingTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func snapshot(_ ts: Date, _ pct: Double, _ reset: Date, balance: Double? = nil) -> UsageSnapshot {
        UsageSnapshot(ts: ts, codexWeekly: pct, codexWeeklyReset: String(reset.timeIntervalSince1970),
            claudeWeekly: nil, claudeWeeklyReset: nil, claude5h: nil, claude5hReset: nil,
            dsBalance: balance, dsTodayTokens: nil)
    }

    @Test func manualResetExcludesUncertainIntervalAndRemainsStable() {
        let reset = date("2026-10-29T06:00:00Z")
        let before = date("2026-10-22T05:58:00Z")
        let observed = date("2026-10-22T06:03:00Z")
        let rows = [snapshot(before, 80, reset), snapshot(observed, 1, reset),
                    snapshot(observed.addingTimeInterval(300), 2, reset)]
        #expect(WeeklyWindow.start(id: "codex", resetAt: reset, history: rows) == observed)
        #expect(WeeklyWindow.start(id: "codex", resetAt: reset, history: Array(rows.prefix(2))) == observed)
        #expect(WeeklyWindow.start(id: "codex", resetAt: reset.addingTimeInterval(3600), history: rows) == nil)
        #expect(WeeklyWindow.start(id: "codex", resetAt: reset, history: []) == nil)
    }

    @Test func changedResetEpochAlsoExcludesPreResetHistory() {
        let observed = date("2026-10-22T06:03:00Z")
        let old = date("2026-10-25T06:00:00Z")
        let new = date("2026-10-29T06:00:00Z")
        let rows = [snapshot(observed.addingTimeInterval(-300), 13, old), snapshot(observed, 12, new)]
        #expect(WeeklyWindow.start(id: "codex", history: rows) == observed)
    }

    @Test func cloudCrossingDayIsProratedInsteadOfDropped() {
        let start = date("2026-10-22T06:03:00Z")
        let cloud = CodexServerUsage.TokenCounts(uncached: 100, cached: 0, output: 0)
        let snapshot = CodexServerUsage.Snapshot(fetchedAt: start, days: [
            .init(date: "2026-10-21", local: .zero, cloud: cloud, other: .zero),
            .init(date: "2026-10-22", local: .zero, cloud: cloud, other: .zero),
            .init(date: "2026-10-23", local: .zero, cloud: cloud, other: .zero)])
        #expect(snapshot.daysInWindow(start).map(\.date) == ["2026-10-22", "2026-10-23"])
        #expect(snapshot.daysInWindow(date("2026-10-22T00:00:00Z")).count == 2)
        #expect(snapshot.daysInWindow(nil).isEmpty)
        #expect(snapshot.valuationNote(windowStart: start).contains("prorated"))
        let now = date("2026-10-24T00:00:00Z")
        let fraction: Double = 1.0 + 64620.0 / 86400.0
        let expected = fraction * cloud.usd(using: CodexValue.cloudPricing)
        #expect(abs((snapshot.cloudUSD(windowStart: start, using: CodexValue.cloudPricing, now: now) ?? 0) - expected) < 0.000001)
    }

    @Test func walletDayUsesDropsWithoutRechargeOrPreviousDay() throws {
        let start = date("2026-10-22T00:00:00+08:00")
        let values: [(TimeInterval, Double)] = [(-120, 150), (180, 100), (480, 90), (780, 200), (1080, 195)]
        let samples = values.map { (ts: start.addingTimeInterval($0.0), balance: $0.1) }
        let result = try #require(PiUsage.walletSpend(samples: samples, start: start, end: start.addingTimeInterval(1080)))
        #expect(result.cost == 15) // 150 -> 100 crosses midnight and is deliberately excluded
        #expect(result.rechargeObserved)
        #expect(result.incomplete)
        let usage = DailyUsage(inputTokens: 0, outputTokens: 0, totalTokens: 0, cost: result.cost,
            currency: "CNY", costIsEstimated: true, costIsLowerBound: true)
        #expect(Render.tokenTextWithCost(usage) == "¥15.00")
    }

    @Test func walletNoMidnightBaselineStillAccumulatesAndInvalidValuesAreIgnored() throws {
        let start = date("2026-10-22T00:00:00Z")
        let result = try #require(PiUsage.walletSpend(samples: [(start, 100),
            (start.addingTimeInterval(300), .nan), (start.addingTimeInterval(900), 95)],
            start: start, end: start.addingTimeInterval(900)))
        #expect(result.cost == 5)
        #expect(result.incomplete)
        #expect(!result.rechargeObserved)
        #expect(PiUsage.walletSpend(samples: [(start.addingTimeInterval(-1), 100)], start: start, end: start) == nil)
    }
    @Test func cachedBalancesDoNotCreateNewWalletObservations() {
        var provider = ProviderResult(id: "deepseek", name: "DeepSeek", plan: nil,
            weekly: nil, fiveHour: nil, balance: Balance(currency: "CNY", total: 95, granted: 0, toppedUp: 95),
            todayUsage: nil, error: nil)
        #expect(Providers.stateInputs([provider]).snapshot.dsBalance == 95)
        #expect(Providers.stateInputs([provider], recordDeepSeekBalance: false).snapshot.dsBalance == nil)
        provider.stale = true
        #expect(Providers.stateInputs([provider]).snapshot.dsBalance == nil)
    }

    @Test func requestsAndCachedTotalsCannotCrossTheResetBoundary() {
        let boundary = date("2026-10-22T06:03:00Z")
        #expect(!WeeklyWindow.includesRequest(startedAt: boundary.addingTimeInterval(-1), boundary: boundary))
        #expect(!WeeklyWindow.includesRequest(startedAt: nil, boundary: boundary))
        #expect(WeeklyWindow.includesRequest(startedAt: boundary, boundary: boundary))
        let old = TodayStats(codexWindowCostUSD: 999, codexWindowStart: boundary.addingTimeInterval(-86400))
        #expect(old.codexCost(in: boundary) == 0)
        #expect(old.codexCost(in: nil) == 0)
        let current = TodayStats(codexWindowCostUSD: 5, codexWindowStart: boundary)
        #expect(current.codexCost(in: boundary) == 5)
    }

    @Test func lowUsageManualResetStillCutsTheWindow() {
        let observed = date("2026-10-22T06:03:00Z")
        let reset = date("2026-10-29T06:00:00Z")
        let rows = [snapshot(observed.addingTimeInterval(-300), 1, reset), snapshot(observed, 0, reset)]
        #expect(WeeklyWindow.start(id: "codex", history: rows) == observed)
    }

    @Test func unreportedCloudDayUsesRecentRateAndKeepsAnEstimate() {
        let cloud = CodexServerUsage.TokenCounts(uncached: 1_000_000, cached: 0, output: 0)
        let start = date("2026-10-22T08:00:00Z")
        let now = date("2026-10-22T20:00:00Z")
        let snapshot = CodexServerUsage.Snapshot(fetchedAt: now, days: [
            .init(date: "2026-10-21", local: .zero, cloud: cloud, other: .zero)])
        let value = snapshot.cloudUSD(windowStart: start, using: CodexValue.cloudPricing, now: now)
        #expect(value == cloud.usd(using: CodexValue.cloudPricing) / 2)
        #expect(value! > 0)
        let usage = DailyUsage(inputTokens: 1, outputTokens: 1, totalTokens: 2, cost: 1.23,
            currency: "CNY", costIsEstimated: true, costIsLowerBound: true, costNote: "internal detail")
        #expect(Render.tokenTextWithCost(usage) == "2 tokens · ¥1.23")
    }

}
