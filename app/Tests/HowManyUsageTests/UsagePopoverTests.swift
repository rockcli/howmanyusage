import Cocoa
import Testing
@testable import HowManyUsage

@MainActor
struct UsagePopoverTests {
    @Test func manualRefreshBypassesSuccessfulCacheButRespectsFailureBackoff() {
        let now = Date()
        let future = now.addingTimeInterval(60)
        #expect(RefreshSchedule.shouldSkip(next: future, now: now, force: false, lastSucceeded: true))
        #expect(!RefreshSchedule.shouldSkip(next: future, now: now, force: true, lastSucceeded: true))
        #expect(RefreshSchedule.shouldSkip(next: future, now: now, force: true, lastSucceeded: false))
        #expect(!RefreshSchedule.shouldSkip(next: now, now: now, force: false, lastSucceeded: false))
    }

    @Test func preservesQuotaWindowsAndProviderActions() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let reset = "1790600000"
        let snapshots = [
            UsageSnapshot(ts: now.addingTimeInterval(-900), codexWeekly: nil, codexWeeklyReset: nil,
                          claudeWeekly: 70, claudeWeeklyReset: reset, claude5h: 5, claude5hReset: reset,
                          dsBalance: nil, dsTodayTokens: nil),
            UsageSnapshot(ts: now, codexWeekly: nil, codexWeeklyReset: nil,
                          claudeWeekly: 85, claudeWeeklyReset: reset, claude5h: 35, claude5hReset: reset,
                          dsBalance: nil, dsTodayTokens: nil),
        ]
        let weekly = RateWindow(kind: "weekly", usedPercent: 85, used: nil, limit: nil,
                                remaining: nil, resetAt: nil, resetsInSeconds: 5000)
        let five = RateWindow(kind: "fiveHour", usedPercent: 35, used: nil, limit: nil,
                              remaining: nil, resetAt: nil, resetsInSeconds: 1000)
        let claude = ProviderResult(id: "claude", name: "Claude", plan: "pro",
                                    weekly: weekly, fiveHour: five, balance: nil,
                                    todayUsage: nil, error: nil, stale: true)
        let model = UsagePopoverModel()
        model.update(
            report: [claude],
            updatedAt: now,
            deltas: ["claude": 5],
            paces: ["claude": (dailyRate: 20, exhaustsIn: 400, projectedAtReset: 100)],
            snapshots: snapshots,
            now: now
        )
        let provider = try #require(model.providers.first)
        #expect(provider.id == "claude")
        #expect(provider.headerTitle.string.contains("Claude (pro)"))
        #expect(provider.windows.map(\.quotaLabel) == ["Weekly", "5h"])
        #expect(provider.windows[0].quotaTodayDelta == 5)
        #expect(provider.windows[0].quotaExhaustsIn == 400)
        #expect(provider.windows[0].quotaSpikeDelta == 15)
        #expect(provider.windows[1].quotaWindow?.usedPercent == 35)
        #expect(provider.windows[1].quotaSpikeDelta == 30)
    }

    @Test func preservesDeepSeekRateAndProviderErrors() throws {
        let codex = ProviderResult(id: "codex", name: "Codex", plan: nil, weekly: nil,
                                   fiveHour: nil, balance: nil, todayUsage: nil, error: nil, stale: true)
        let agWeekly = RateWindow(kind: "weekly", usedPercent: 3, used: nil, limit: nil,
                                  remaining: nil, resetAt: nil, resetsInSeconds: 590_000)
        let agFive = RateWindow(kind: "fiveHour", usedPercent: 11, used: nil, limit: nil,
                                remaining: nil, resetAt: nil, resetsInSeconds: 9_800)
        let antigravity = ProviderResult(id: "antigravity", name: "Google", plan: "ultra",
                                         weekly: agWeekly, fiveHour: agFive, balance: nil,
                                         todayUsage: nil, error: nil)
        let deepseek = ProviderResult(id: "deepseek", name: "DeepSeek", plan: nil, weekly: nil,
                                      fiveHour: nil, balance: Balance(currency: "CNY", total: 120, granted: 0, toppedUp: 120),
                                      todayUsage: DailyUsage(inputTokens: 100, outputTokens: 50, totalTokens: 150, cost: 1.2, currency: "CNY"),
                                      error: nil)
        let colab = ProviderResult(id: "colab", name: "Colab", plan: nil, weekly: nil,
                                   fiveHour: nil, balance: Balance(currency: "CU", total: 2498.75, granted: 0, toppedUp: 2498.75),
                                   todayUsage: DailyUsage(inputTokens: 0, outputTokens: 0, totalTokens: 0, cost: 0, currency: "CU", costIsEstimated: true, costIsLowerBound: true),
                                   error: nil)
        let model = UsagePopoverModel()
        model.update(report: [codex, antigravity, deepseek, colab], updatedAt: Date())
        #expect(model.providers.map(\.id) == ["codex", "antigravity", "deepseek", "colab"])
        #expect(model.providers[0].statusLine?.string.contains("data unavailable") == true)
        #expect(model.providers[1].headerTitle.string.contains("Google (ultra)"))
        #expect(model.providers[1].windows.map(\.quotaLabel) == ["Weekly", "5h"])
        #expect(!model.providers[2].showPeakStrip)
        #expect(model.providers[3].headerTitle.string.contains("Colab (2498.75 CU)"))
        #expect(model.providers[3].todayText == nil)
    }

    @Test func parsesColabCCUInfoAndFormatsComputeUnits() throws {
        let raw = Data(")]}'\n{\"currentBalance\":2498.7476936646353,\"consumptionRateHourly\":13.08,\"assignmentsCount\":1,\"expirationTime\":\"2027-02-05T00:00:00Z\"}".utf8)
        let parsed = try Providers.parseColabCCUInfo(raw)
        #expect(abs(parsed.balance - 2498.7476936646353) < 1e-6)
        #expect(abs(parsed.hourlyRate - 13.08) < 1e-6)
        #expect(parsed.activeCount == 1)
        #expect(parsed.expiresAt != nil)
        #expect(Render.formatAmount(parsed.balance, currency: "CU") == "2498.75 CU")

        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let snapshots = [
            UsageSnapshot(ts: now.addingTimeInterval(-600), codexWeekly: nil, codexWeeklyReset: nil,
                          claudeWeekly: nil, claudeWeeklyReset: nil, claude5h: nil, claude5hReset: nil,
                          dsBalance: nil, dsTodayTokens: nil, colabBalance: 2500.0),
            UsageSnapshot(ts: now, codexWeekly: nil, codexWeeklyReset: nil,
                          claudeWeekly: nil, claudeWeeklyReset: nil, claude5h: nil, claude5hReset: nil,
                          dsBalance: nil, dsTodayTokens: nil, colabBalance: 2485.0),
        ]
        #expect(TodayStatsScanner.colabBalanceSpike(history: snapshots, now: now) == 15.0)
    }

    @Test func dispatchesProviderIdentityAndActions() {
        let model = UsagePopoverModel()
        var opened: String?
        var refreshed = false
        var toggledSpeed = false
        model.onOpenProvider = { opened = $0 }
        model.onRefresh = { refreshed = true }
        model.onToggleSpeed = { toggledSpeed = true }
        model.openProvider("claude")
        model.onRefresh?()
        model.speedCollapsible = true
        model.speedCollapsed = true
        model.toggleSpeedCollapsed()
        #expect(opened == "claude")
        #expect(refreshed)
        #expect(toggledSpeed)
        #expect(!model.speedCollapsed)
        #expect(model.userExpandedSpeed)
        model.toggleSpeedCollapsed()
        #expect(model.speedCollapsed)
        #expect(!model.userExpandedSpeed)
    }

    @Test func countdownsAndSpikeAlertsFormatCleanly() {
        #expect(Render.durationText(nil) == "unknown")
        #expect(Render.durationText(-10) == "0m")
        #expect(Render.durationText(3599) == "59m")
        #expect(Render.durationText(7199) == "1h")
        #expect(Render.durationText(86_399) == "23h")
        #expect(Render.durationText(86_400) == "1d")
        #expect(Render.durationText(90_061) == "1d 1h")
        #expect(Render.durationText(172_800) == "2d")
        let weekly = RateWindow(kind: "weekly", usedPercent: 68, used: nil, limit: nil,
                                remaining: nil, resetAt: nil, resetsInSeconds: 69_000)
        let details = QuotaMenuRowView.details(window: weekly, id: "codex", exhaustsIn: 12_340,
                                              projectedAtReset: nil, spikeDelta: 12).string
        #expect(details == "· 19h · ⚠ 3h · ⚠ +12%")
        let multiDay = RateWindow(kind: "weekly", usedPercent: 25, used: nil, limit: nil,
                                  remaining: nil, resetAt: nil, resetsInSeconds: 300_000)
        #expect(QuotaMenuRowView.details(window: multiDay, id: "codex", exhaustsIn: nil,
                                         projectedAtReset: nil).string == "· 3d 11h")
    }

    @Test func updateTimeOmitsSeconds() {
        let rendered = Render.timeFormatter.string(from: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(rendered.split(separator: ":").count == 2)
    }

    @Test func activityLevelsDistinguishHighPromptCounts() {
        let counts = [0, 1, 9, 10, 29, 30, 79, 80, 159, 160, 299, 300, 465]
        #expect(counts.map(ActivityScale.level(for:)) == [0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6])
    }
}
