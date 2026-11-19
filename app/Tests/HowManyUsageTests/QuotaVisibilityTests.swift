import Cocoa
import Testing
@testable import HowManyUsage

struct QuotaVisibilityTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func window(used: Double? = 40, seconds: Double? = 2520, kind: String = "weekly") -> RateWindow {
        RateWindow(kind: kind, usedPercent: used, used: nil, limit: nil, remaining: nil,
                   resetAt: seconds.map { now.addingTimeInterval($0) }, resetsInSeconds: 999_999)
    }

    private func hint(_ w: RateWindow, stale: Bool = false, projected: Double? = nil,
                      exhaustion: Double? = nil, spike: Double? = nil) -> Double? {
        WeeklyWindow.expiringUnusedPercent(window: w, stale: stale, projectedAtReset: projected,
                                          exhaustsIn: exhaustion, spikeDelta: spike, now: now)
    }

    @Test func countdownBoundariesNeverRoundAFutureResetDownToZeroHours() {
        #expect(Render.durationText(0) == "0m")
        #expect(Render.durationText(0.01) == "<1m")
        #expect(Render.durationText(59.9) == "<1m")
        #expect(Render.durationText(60) == "1m")
        #expect(Render.durationText(42 * 60) == "42m")
        #expect(Render.durationText(3599) == "59m")
        #expect(Render.durationText(3600) == "1h")
        #expect(Render.durationText(86_399) == "23h")
        #expect(Render.durationText(86_400) == "1d")
        #expect(Render.durationText(172_800) == "2d")
        for invalid in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            #expect(Render.durationText(invalid) == "unknown")
        }
    }

    @Test func reminderHasInclusiveTimeAndUnusedThresholds() {
        #expect(hint(window(used: 70, seconds: 6 * 3600)) == 30)
        #expect(hint(window(used: 70.01)) == nil)
        #expect(hint(window(seconds: 6 * 3600 + 1)) == nil)
        #expect(hint(window(seconds: 0)) == nil)
        #expect(hint(window(seconds: -1)) == nil)
        #expect(hint(window(kind: "fiveHour")) == nil)
        #expect(hint(window(used: 0)) == 100)
    }

    @Test func unknownStaleAndConflictingSignalsDoNotProduceWasteHints() {
        #expect(hint(window(), stale: true) == nil)
        #expect(hint(window(used: nil)) == nil)
        #expect(hint(window(used: .nan)) == nil)
        #expect(hint(window(used: -1)) == nil)
        #expect(hint(window(used: 101)) == nil)
        #expect(hint(window(seconds: .infinity)) == nil)
        #expect(hint(window(), projected: .nan) == nil)
        #expect(hint(window(), projected: 70) == 60)
        #expect(hint(window(), projected: 70.01) == nil)
        #expect(hint(window(), exhaustion: 2500) == nil)
        #expect(hint(window(), exhaustion: .infinity) == nil)
        #expect(hint(window(), spike: 8) == nil)
        #expect(hint(window(), spike: .nan) == nil)
        let unknown = RateWindow(kind: "weekly", usedPercent: 40, used: nil, limit: nil,
                                 remaining: nil, resetAt: nil, resetsInSeconds: nil)
        #expect(hint(unknown) == nil)
    }

    @Test @MainActor func singleEnglishHintUsesCurrentTimeAndDisappearsAtReset() {
        let w = window()
        func details(at date: Date, stale: Bool = false, exhaustion: Double? = nil) -> String {
            QuotaMenuRowView.details(window: w, id: "codex", exhaustsIn: exhaustion,
                                    projectedAtReset: nil, stale: stale, now: date).string
        }
        #expect(details(at: now) == "· 60% unused · resets in 42m")
        #expect(details(at: now.addingTimeInterval(60)) == "· 60% unused · resets in 41m")
        #expect(details(at: now.addingTimeInterval(2520)) == "· reset due")
        #expect(details(at: now, stale: true) == "· 42m")
        #expect(details(at: now, exhaustion: 600) == "· 42m · ⚠ 10m")
    }

    @Test func expiredAbsoluteResetOverridesCachedCountdown() {
        let w = window(seconds: -1)
        #expect(w.remainingSeconds(at: now) == -1)
        #expect(hint(w) == nil)
    }

    @Test @MainActor func malformedNumbersNeverReachTextOrQuotaGeometry() {
        for invalid in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            #expect(Render.barString(invalid, width: 4) == "····")
            #expect(UsageNumbers.wholeText(invalid) == "—")
        }
        #expect(Render.formatAmount(.nan, currency: "CNY") == "—")
        #expect(Render.weekBars([0, .infinity]) == "")
        #expect(Render.sparkline([0, .nan, 1]) == "")
        #expect(Render.sparkline([-.greatestFiniteMagnitude, 0, .greatestFiniteMagnitude]) == "▁▄█")
        #expect(Render.weekBars([0, 10]) == "▁█")
        let details = QuotaMenuRowView.details(window: window(used: .nan), id: "codex",
            exhaustsIn: .nan, projectedAtReset: -.infinity, spikeDelta: .infinity, now: now)
        #expect(details.string == "· 42m")
    }

    @Test func providerParsingRejectsInvalidNumberBridges() throws {
        for invalid in ["NaN", "Infinity", "1e300", true, NSNull(), ["wrong": 1]] as [Any] {
            let parsed = Providers.codexWindows(primary: ["window_minutes": 10080, "used_percent": invalid,
                                                         "reset_at": Double.infinity], secondary: nil)
            #expect(parsed.weekly?.usedPercent == nil)
            #expect(parsed.weekly?.resetAt == nil)
        }
        let parsed = Providers.parseAntigravityQuotaSummary(["buckets": [
            ["bucketId": "gemini-weekly", "remainingFraction": "NaN", "resetTime": "2026-11-16T12:00:00Z"]
        ]])
        #expect(parsed.weekly?.usedPercent == nil)
        #expect(CodexValue.extrapolate(costSoFar: .greatestFiniteMagnitude, pctSoFar: .leastNonzeroMagnitude) == nil)
        #expect(CodexValue.cost(model: nil, input: .min, cachedInput: .max, output: 0) == nil)
        #expect(ClaudeValue.cost(model: "claude-opus-5-5", input: .max, cacheCreate5m: .max,
                                 cacheCreate1h: .max, cacheRead: .max, output: .max)?.isFinite == true)
    }
}
