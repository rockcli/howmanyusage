import Foundation
import Testing
@testable import HowManyUsage

struct CodexServerRegressionTests {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func quotaSample(_ timestamp: Date, percent: Double, reset: Date) -> UsageSnapshot {
        UsageSnapshot(ts: timestamp, codexWeekly: percent,
            codexWeeklyReset: String(reset.timeIntervalSince1970),
            claudeWeekly: nil, claudeWeeklyReset: nil, claude5h: nil, claude5hReset: nil,
            dsBalance: nil, dsTodayTokens: nil)
    }

    /// A completed UTC day with a $100 cloud report and ten observed quota points.
    private func calibration() -> (snapshot: CodexServerUsage.Snapshot, history: [UsageSnapshot]) {
        let start = date("2026-11-15T00:00:00Z")
        let reset = start.addingTimeInterval(86400)
        let history = (0..<144).map { index in
            let seconds = Double(index * 600)
            return quotaSample(start.addingTimeInterval(seconds), percent: seconds * 10 / 86400, reset: reset)
        }
        let snapshot = CodexServerUsage.Snapshot(fetchedAt: reset, days: [
            .init(date: "2026-11-15", local: .zero,
                cloud: .init(uncached: 50_000_000, cached: 0, output: 0), other: .zero)
        ])
        return (snapshot, history)
    }

    @Test func calibratedCloudCannotEraseReportedCurrentWindowValue() throws {
        let (snapshot, history) = calibration()
        let rate = try #require(snapshot.quotaValueRate(using: CodexValue.cloudPricing,
            history: history, now: date("2026-11-16T12:00:00Z")))
        #expect(abs(rate - 10) < 0.000001)
        let cloud = try #require(snapshot.cloudUSD(windowStart: date("2026-11-15T00:00:00Z"),
            using: CodexValue.cloudPricing, now: date("2026-11-16T12:00:00Z"),
            usedPercent: 10, localUSD: 200, history: history))
        // A different current local model mix can exceed the calibrated total.
        // The already reported $100 of cloud value still exists in this window.
        #expect(abs(cloud - 100) < 0.000001)
    }

    @Test func calibrationUsesOnlyQuotaIncreaseAfterTheSafeBoundary() throws {
        let (snapshot, past) = calibration()
        let start = date("2026-11-16T08:00:00Z"), now = date("2026-11-16T12:00:00Z")
        let history = past + [quotaSample(start, percent: 70, reset: now.addingTimeInterval(7 * 86400))]
        let cloud = try #require(snapshot.cloudUSD(windowStart: start, using: CodexValue.cloudPricing,
            now: now, usedPercent: 80, localUSD: 20, history: history))
        // The 70 points consumed before the first post-reset observation are excluded.
        #expect(abs(cloud - ((80 - 70) * 10 - 20)) < 0.000001)
    }

    @Test func stalePriorWindowCloudDoesNotInventSpendWhenRecentDaysAreLocalOnly() throws {
        let (_, past) = calibration()
        let start = date("2026-11-19T00:00:00Z"), now = date("2026-11-19T12:00:00Z")
        let snapshot = CodexServerUsage.Snapshot(fetchedAt: now, days: [
            .init(date: "2026-11-15", local: .zero, cloud: .init(uncached: 50_000_000, cached: 0, output: 0), other: .zero),
            .init(date: "2026-11-16", local: .init(uncached: 1_000_000, cached: 0, output: 0), cloud: .zero, other: .zero),
            .init(date: "2026-11-17", local: .init(uncached: 1_000_000, cached: 0, output: 0), cloud: .zero, other: .zero),
            .init(date: "2026-11-18", local: .init(uncached: 1_000_000, cached: 0, output: 0), cloud: .zero, other: .zero),
        ])
        let history = past + [quotaSample(start, percent: 0, reset: now.addingTimeInterval(7 * 86400))]
        let cloud = try #require(snapshot.cloudUSD(windowStart: start, using: CodexValue.cloudPricing,
            now: now, usedPercent: 24, localUSD: 7, history: history))
        #expect(cloud == 0)
    }

    @Test func missingBoundaryOrDecreasingQuotaUsesDailyProjection() throws {
        let (snapshot, past) = calibration()
        let start = date("2026-11-16T08:00:00Z"), now = date("2026-11-16T12:00:00Z")
        let reset = now.addingTimeInterval(7 * 86400)
        for history in [past, past + [quotaSample(start, percent: 90, reset: reset)]] {
            let cloud = try #require(snapshot.cloudUSD(windowStart: start, using: CodexValue.cloudPricing,
                now: now, usedPercent: 80, localUSD: 20, history: history))
            #expect(abs(cloud - 100 * 4 / 24) < 0.000001)
        }
    }

    @Test func calibrationRejectsInvalidNumericAndOutOfWindowInputs() throws {
        let (snapshot, past) = calibration()
        let start = date("2026-11-16T08:00:00Z"), now = date("2026-11-16T12:00:00Z")
        let history = past + [quotaSample(start, percent: 70, reset: now.addingTimeInterval(7 * 86400))]
        for invalid in [Double.nan, .infinity, -.infinity] {
            #expect(snapshot.cloudUSD(windowStart: Date(timeIntervalSince1970: invalid),
                using: CodexValue.cloudPricing, now: now, usedPercent: 80, history: history) == nil)
            #expect(snapshot.cloudUSD(windowStart: start, using: CodexValue.cloudPricing,
                now: Date(timeIntervalSince1970: invalid), usedPercent: 80, history: history) == nil)
            let cloud = try #require(snapshot.cloudUSD(windowStart: start, using: CodexValue.cloudPricing,
                now: now, usedPercent: invalid, localUSD: invalid, history: history))
            #expect(cloud.isFinite)
            #expect(abs(cloud - 100 * 4 / 24) < 0.000001)
        }
        #expect(snapshot.cloudUSD(windowStart: now.addingTimeInterval(-9 * 86400),
            using: CodexValue.cloudPricing, now: now, usedPercent: 80, history: history) == nil)
    }

    @Test func serverPercentagesRejectNonfiniteAndInvalidJSONTypes() throws {
        for value: Any in ["NaN", "Infinity", "-Infinity", "1e100", -1, 101, true, ["wrong": 1]] {
            let data = try JSONSerialization.data(withJSONObject: ["threads": [
                ["thread_id": "fixture", "weekly_limit_percent": value, "data_status": "partial"]
            ]])
            #expect(throws: CodexServerUsageError.self) { try CodexServerUsage.parseThreadUsage(data) }
        }
        let data = Data(#"{"threads":[{"thread_id":"a","weekly_limit_percent":null},{"thread_id":"b","weekly_limit_percent":"12.5"}]}"#.utf8)
        let rows = try CodexServerUsage.parseThreadUsage(data)
        #expect(rows.map(\.pct) == [0, 12.5])
    }

    @Test func serverTokenCountsRejectInvalidTypesAndIntegerOverflow() throws {
        for value: Any in ["NaN", "Infinity", "-1", "1.5", "18446744073709551615",
                           1e100, -1, 1.5, true, ["wrong": 1]] {
            let data = try JSONSerialization.data(withJSONObject: ["data": [
                ["date": "2026-11-15", "clients": [["client_id": "CODEX_WORK_WEB",
                    "uncached_text_input_tokens": value]]]
            ]])
            #expect(throws: CodexServerUsageError.self) { try CodexServerUsage.parseDailyCounts(data) }
        }
        let overflow = Data("""
        {"data":[{"date":"2026-11-15","clients":[
          {"client_id":"CODEX_WORK_WEB","uncached_text_input_tokens":\(Int.max),"text_output_tokens":1}
        ]}]}
        """.utf8)
        #expect(throws: CodexServerUsageError.self) { try CodexServerUsage.parseDailyCounts(overflow) }
    }

    @Test func tokenResponseAggregateIsCheckedAcrossClientsAndDays() throws {
        let data = Data("""
        {"data":[
          {"date":"2026-11-15","clients":[{"client_id":"CODEX_WORK_WEB","cached_text_input_tokens":\(Int.max)}]},
          {"date":"2026-11-16","clients":[{"client_id":"CODEX_DESKTOP_APP","text_output_tokens":1}]}
        ]}
        """.utf8)
        #expect(throws: CodexServerUsageError.self) { try CodexServerUsage.parseDailyCounts(data) }
    }

    @Test func tokenParserPreservesExactIntegersAndIntegralDecimals() throws {
        let data = Data(#"{"data":[{"date":"2026-11-15","clients":[{"client_id":"CODEX_WORK_WEB","uncached_text_input_tokens":9007199254740993,"cached_text_input_tokens":1000.0,"text_output_tokens":"25"}]}]}"#.utf8)
        let day = try #require(CodexServerUsage.parseDailyCounts(data).first)
        #expect(day.cloud.uncached == 9_007_199_254_740_993)
        #expect(day.cloud.cached == 1000)
        #expect(day.cloud.output == 25)
        _ = try JSONEncoder().encode(CodexServerUsage.Snapshot(fetchedAt: Date(), days: [day]))
    }

    @Test func midWindowCalibrationExtrapolatesOverIncrementalQuotaDelta() throws {
        let (snapshot, past) = calibration()
        let start = date("2026-11-16T08:00:00Z"), now = date("2026-11-16T12:00:00Z")
        let history = past + [quotaSample(start, percent: 70, reset: now.addingTimeInterval(7 * 86400))]

        let paired = CodexServerUsage.codexExtrapolatedValue(
            serverUsage: snapshot, windowStart: start, usedPercent: 80,
            localUSD: 20, now: now, history: history
        )
        #expect(abs((paired.cloudUSD ?? 0) - 80) < 1e-6)
        #expect(abs(paired.pctSoFar - 10) < 1e-6)
        #expect(abs((paired.weekly ?? 0) - 1000) < 1e-6)
        #expect(abs((paired.monthly ?? 0) - (1000 * 30.44 / 7)) < 1e-6)

        let noProgress = CodexServerUsage.codexExtrapolatedValue(
            serverUsage: snapshot, windowStart: start, usedPercent: 70,
            localUSD: 20, now: now, history: history
        )
        #expect(noProgress.pctSoFar == 0)
        #expect(noProgress.weekly == nil)
        #expect(noProgress.monthly == nil)

        let localOnly = CodexServerUsage.codexExtrapolatedValue(
            serverUsage: nil, windowStart: start, usedPercent: 80,
            localUSD: 20, now: now, history: history
        )
        #expect(localOnly.cloudUSD == nil)
        #expect(abs(localOnly.pctSoFar - 10) < 1e-6)
        #expect(abs((localOnly.weekly ?? 0) - 200) < 1e-6)
    }
}
