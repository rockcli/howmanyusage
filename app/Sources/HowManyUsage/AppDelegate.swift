import Cocoa
import SwiftUI

enum RefreshSchedule {
    static let data: TimeInterval = 600
    static func shouldSkip(next: Date, now: Date, force: Bool, lastSucceeded: Bool) -> Bool {
        now < next && !(force && lastSucceeded)
    }
}

/// Menu bar app: NSStatusItem + periodic refresh + native usage popover
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    var report: [ProviderResult] = []
    var updatedAt: Date?
    private var refreshing = false
    private var timer: Timer?
    private let speedScanner = ModelSpeedScanner()
    var speed = CodexSpeed.Snapshot()
    private let popover = NSPopover()
    private var hostingController: NSHostingController<UsagePopoverView>?
    let popoverModel = UsagePopoverModel()
    private var samplingSpeed = false
    private var speedScannedAt = Date.distantPast
    /// Last successful data per provider, used as a fallback when a live fetch fails
    private var lastData: [String: ProviderResult] = [:]
    /// Per-provider throttle: 10 min TTL after success, exponential backoff on 429
    private var nextFetchAt: [String: Date] = [:]
    private var rateLimitCount: [String: Int] = [:]
    private var successfulProviderIDs: Set<String> = []
    /// Server-side Codex attribution changes slowly (the backend recalculates daily);
    /// a 30-minute cadence is plenty and keeps an undocumented route low-traffic.
    private var nextServerUsageFetchAt = Date.distantPast
    private var deepSeekLocalScannedAt = Date.distantPast
    private var fetchingServerUsage = false
    private var enrichingDeepSeek = false
    private let onDemandScanTTL: TimeInterval = 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.title = ""
            button.toolTip = nil
            button.target = self
            button.action = #selector(toggleUsagePopover)
            button.image = Render.staticStatusBarsImage()
            button.imagePosition = .imageOnly
        }
        popoverModel.onOpenProvider = { [weak self] id in self?.openUsagePage(id) }
        popoverModel.onRefresh = { [weak self] in self?.refreshNow() }
        popoverModel.onQuit = { [weak self] in self?.quitApp() }
        popoverModel.onToggleSpeed = { [weak self] in self?.resizePopoverToFit() }

        popover.behavior = .transient
        popover.delegate = self
        let hc = NSHostingController(rootView: UsagePopoverView(model: popoverModel))
        hostingController = hc
        popover.contentViewController = hc
        _ = hc.view
        lastData = StateStore.loadProviderCache()

        // Background timer only polls lightweight quota/balance APIs so snapshots stay
        // current for cross-day deltas, 12h pace forecasts, and 45m spike detection.
        // Heavy local log scans run only on demand when the popover is opened.
        timer = Timer.scheduledTimer(withTimeInterval: RefreshSchedule.data, repeats: true) { [weak self] _ in
            Task {
                guard let self else { return }
                await self.refresh(includeLocalScans: self.popover.isShown)
            }
        }
        timer?.tolerance = 60
        Task { await refresh(includeLocalScans: false) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    func popoverDidClose(_ notification: Notification) {
        popoverModel.isPopoverVisible = false
    }

    private func sampleSpeed(force: Bool = false) async {
        guard !samplingSpeed, force || Date().timeIntervalSince(speedScannedAt) >= onDemandScanTTL else { return }
        samplingSpeed = true
        let scanner = speedScanner
        speed = await Task.detached(priority: .utility) { scanner.scan() }.value
        speedScannedAt = Date()
        samplingSpeed = false
        popoverModel.speed = speed
        resizePopoverToFit()
    }

    private func resizePopoverToFit(force: Bool = false) {
        guard force || popover.isShown else { return }
        guard let hc = hostingController else { return }
        let view = hc.view
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main
        // NSPopover adds 26pt of window chrome (13pt top + 13pt bottom) around its contentView.
        let visibleHeight = (screen?.visibleFrame.height ?? 1000) - 26

        // Measure current height and compute full expanded height to detect overflow.
        hc.rootView = UsagePopoverView(model: popoverModel)
        view.layoutSubtreeIfNeeded()
        let currentHeight = ceil(view.fittingSize.height)
        guard currentHeight > 0 else { return }

        let speedBodyHeight = CGFloat(1 + max(1, popoverModel.speed.rows.count)) * 25
        let expandedHeight = popoverModel.speedCollapsed ? currentHeight + speedBodyHeight : currentHeight
        let overflows = expandedHeight > visibleHeight

        if overflows {
            popoverModel.speedCollapsible = true
            if !popoverModel.userExpandedSpeed && !popoverModel.speedCollapsed {
                popoverModel.speedCollapsed = true
            }
        } else {
            popoverModel.speedCollapsible = false
            popoverModel.speedCollapsed = false
            popoverModel.userExpandedSpeed = false
        }

        hc.rootView = UsagePopoverView(model: popoverModel)
        view.layoutSubtreeIfNeeded()
        let finalFittingHeight = max(300, ceil(view.fittingSize.height))
        popover.contentSize = NSSize(width: 470, height: finalFittingHeight)

        if popover.isShown, let win = view.window {
            let chromeHeight = max(26, win.frame.height - view.frame.height)
            let neededWinHeight = finalFittingHeight + chromeHeight
            if abs(win.frame.height - neededWinHeight) > 1 {
                let topY = win.frame.maxY
                let minY = (screen?.frame.minY ?? 0) + 2
                let newOriginY = max(minY, topY - neededWinHeight)
                let newFrame = NSRect(
                    x: win.frame.origin.x,
                    y: newOriginY,
                    width: win.frame.width,
                    height: topY - newOriginY
                )
                win.setFrame(newFrame, display: true)
            }
        }
    }

    // MARK: - Popover & Actions

    @objc private func toggleUsagePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        popoverModel.userExpandedSpeed = false
        popoverModel.isPopoverVisible = true
        var visibleSpeed = speed
        visibleSpeed.now = Date()
        popoverModel.speed = visibleSpeed
        if report.isEmpty && !lastData.isEmpty {
            let installed = ProviderDetection.installedProviders()
            report = ProviderDetection.allProviderIDs
                .filter { installed.contains($0) }
                .compactMap { lastData[$0] }
        }
        popoverModel.update(report: report, updatedAt: updatedAt, todayStats: TodayStatsScanner.cachedStats())
        resizePopoverToFit(force: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()

        // On-demand local scans & stale network refresh after the popover is visible.
        _ = TodayStatsScanner.ensureFreshStats(maxAge: onDemandScanTTL) { [weak self] stats in
            guard let self, self.popover.isShown else { return }
            self.popoverModel.update(report: self.report, updatedAt: self.updatedAt, todayStats: stats)
            self.resizePopoverToFit()
        }
        popoverModel.refreshHistory()
        Task { await sampleSpeed() }
        Task { await refreshOnPopoverOpen() }
    }

    private func refreshNow() {
        Task { await refresh(force: true, includeLocalScans: true) }
        Task { await sampleSpeed(force: true) }
        popoverModel.refreshHistory(force: true)
    }

    private func refreshOnPopoverOpen() async {
        if updatedAt == nil || Date().timeIntervalSince(updatedAt!) >= RefreshSchedule.data {
            await refresh(includeLocalScans: true)
        } else {
            await refreshLocalMetadataIfNeeded()
        }
    }

    private func refreshLocalMetadataIfNeeded() async {
        let now = Date()
        let installed = ProviderDetection.installedProviders()
        if installed.contains("codex"), now >= nextServerUsageFetchAt && !fetchingServerUsage {
            fetchingServerUsage = true
            let codexWindowStart = WeeklyWindow.start(id: "codex")
            let snapshot = await Task.detached(priority: .utility) {
                await CodexServerUsage.fetch(days: 8, windowStart: codexWindowStart)
            }.value
            fetchingServerUsage = false
            if let snapshot, !snapshot.days.isEmpty {
                StateStore.saveCodexServerUsage(snapshot)
                nextServerUsageFetchAt = now.addingTimeInterval(1800)
                if popover.isShown { updateStatusItem(allowLocalScan: false) }
            } else {
                nextServerUsageFetchAt = now.addingTimeInterval(300)
            }
        }
        if Date().timeIntervalSince(deepSeekLocalScannedAt) >= onDemandScanTTL && !enrichingDeepSeek,
           let idx = report.firstIndex(where: { $0.id == "deepseek" && $0.ok }) {
            enrichingDeepSeek = true
            let current = report[idx]
            let enriched = await Task.detached(priority: .utility) {
                Providers.enrichDeepSeekUsage(current, includeLocalLogs: true)
            }.value
            deepSeekLocalScannedAt = Date()
            enrichingDeepSeek = false
            if let liveIdx = report.firstIndex(where: { $0.id == "deepseek" }) {
                report[liveIdx] = enriched
                if !enriched.stale {
                    lastData["deepseek"] = enriched
                    StateStore.saveProviderCache(enriched)
                }
                if popover.isShown { updateStatusItem(allowLocalScan: false) }
            }
        }
    }

    private func quitApp() {
        NSApp.terminate(nil)
    }

    private func openUsagePage(_ id: String) {
        let pages: [String: String] = [
            "codex": "https://chatgpt.com/codex/settings/usage",
            "claude": "https://claude.ai/settings/usage",
            "antigravity": "https://antigravity.google/docs",
            "deepseek": "https://platform.deepseek.com/usage",
            "colab": "https://colab.research.google.com/signup",
        ]
        guard let url = pages[id], let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }

    // MARK: - Refresh

    private func refresh(force: Bool = false, includeLocalScans: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        let now = Date()
        let skip = Set(nextFetchAt.filter { id, next in
            RefreshSchedule.shouldSkip(next: next, now: now, force: force, lastSucceeded: successfulProviderIDs.contains(id))
        }.keys)
        let installed = ProviderDetection.installedProviders()
        let result = await Providers.fetchAll(only: installed, skip: skip, includeLocalUsage: includeLocalScans)
        if includeLocalScans { deepSeekLocalScannedAt = Date() }
        updatedAt = Date()

        // Per-provider throttle: 10 min TTL after success; exponential backoff on 429.
        for p in result where !skip.contains(p.id) {
            if p.ok, hasData(p) {
                successfulProviderIDs.insert(p.id)
                nextFetchAt[p.id] = now.addingTimeInterval(RefreshSchedule.data)
                rateLimitCount[p.id] = 0
            } else if !p.ok {
                successfulProviderIDs.remove(p.id)
                let isRateLimited = (p.error?.lowercased().contains("429") ?? false)
                    || (p.error?.lowercased().contains("rate_limit") ?? false)
                if isRateLimited {
                    let c = (rateLimitCount[p.id] ?? 0) + 1
                    rateLimitCount[p.id] = c
                    nextFetchAt[p.id] = now.addingTimeInterval(min(60.0 * pow(2.0, Double(c - 1)), RefreshSchedule.data))
                } else {
                    nextFetchAt[p.id] = now.addingTimeInterval(60)
                }
            }
        }

        // Cache successful data; fall back to the cached copy (marked stale) on failure.
        var shown: [ProviderResult] = []
        for p in result {
            if skip.contains(p.id), p.ok, !hasData(p), let cached = lastData[p.id] {
                shown.append(cached)
            } else if p.ok {
                var merged = p
                if !includeLocalScans, p.id == "deepseek", let prevToday = lastData[p.id]?.todayUsage, prevToday.totalTokens > 0 {
                    merged = ProviderResult(
                        id: p.id, name: p.name, plan: p.plan, weekly: p.weekly, fiveHour: p.fiveHour,
                        balance: p.balance,
                        todayUsage: DailyUsage(
                            inputTokens: prevToday.inputTokens,
                            outputTokens: prevToday.outputTokens,
                            totalTokens: prevToday.totalTokens,
                            cost: p.todayUsage?.cost ?? prevToday.cost,
                            currency: p.todayUsage?.currency ?? prevToday.currency,
                            costIsEstimated: p.todayUsage?.costIsEstimated ?? prevToday.costIsEstimated,
                            costIsLowerBound: p.todayUsage?.costIsLowerBound ?? prevToday.costIsLowerBound,
                            costNote: p.todayUsage?.costNote ?? prevToday.costNote
                        ),
                        error: p.error, stale: p.stale
                    )
                }
                lastData[p.id] = merged
                StateStore.saveProviderCache(merged)
                shown.append(merged)
            } else if p.id == "claude", p.error?.hasPrefix("Claude quota credential") == true {
                shown.append(p)
            } else if let cached = lastData[p.id] {
                var stale = cached
                stale.stale = true
                shown.append(stale)
            } else if let restored = restoreFromHistory(p) {
                shown.append(restored)
            } else {
                shown.append(ProviderResult(id: p.id, name: p.name, plan: nil, weekly: nil, fiveHour: nil, balance: nil, todayUsage: nil, error: nil, stale: true))
            }
        }
        report = shown

        let inputs = Providers.stateInputs(
            shown,
            recordDeepSeekBalance: !skip.contains("deepseek") && result.contains { $0.id == "deepseek" && $0.ok && $0.balance != nil },
            recordColabBalance: !skip.contains("colab") && result.contains { $0.id == "colab" && $0.ok && $0.balance != nil }
        )
        _ = StateStore.updateWindows(inputs.windows)
        StateStore.appendSnapshot(inputs.snapshot)

        if includeLocalScans {
            let codexWindowStart = WeeklyWindow.start(id: "codex")
            let serverUsageTask: Task<CodexServerUsage.Snapshot?, Never>? = (installed.contains("codex") && now >= nextServerUsageFetchAt && !fetchingServerUsage)
                ? Task.detached(priority: .utility) { await CodexServerUsage.fetch(days: 8, windowStart: codexWindowStart) }
                : nil

            _ = TodayStatsScanner.ensureFreshStats(maxAge: force ? 0 : onDemandScanTTL) { [weak self] _ in
                guard let self, self.popover.isShown else { return }
                self.updateStatusItem(allowLocalScan: false)
            }

            if let serverUsageTask {
                fetchingServerUsage = true
                if let snapshot = await serverUsageTask.value, !snapshot.days.isEmpty {
                    StateStore.saveCodexServerUsage(snapshot)
                    nextServerUsageFetchAt = now.addingTimeInterval(1800)
                } else {
                    nextServerUsageFetchAt = now.addingTimeInterval(300)
                }
                fetchingServerUsage = false
            }
        }

        if popover.isShown {
            updateStatusItem(allowLocalScan: includeLocalScans)
        }
        refreshing = false
    }

    func updateStatusItem(allowLocalScan: Bool = true) {
        let todayStats: TodayStats?
        if allowLocalScan {
            todayStats = TodayStatsScanner.ensureFreshStats(maxAge: onDemandScanTTL) { [weak self] stats in
                guard let self, self.popover.isShown else { return }
                self.popoverModel.update(report: self.report, updatedAt: self.updatedAt, todayStats: stats)
                self.resizePopoverToFit()
            }
        } else {
            todayStats = TodayStatsScanner.cachedStats()
        }
        popoverModel.update(report: report, updatedAt: updatedAt, todayStats: todayStats)
        resizePopoverToFit()
    }

    /// Rebuild a provider result from the most recent snapshot that had data for it.
    private func restoreFromHistory(_ p: ProviderResult) -> ProviderResult? {
        let hist = StateStore.history()
        let id = p.id
        func lastValue<T>(_ keyPath: (UsageSnapshot) -> T?) -> T? {
            for s in hist.reversed() {
                if let v = keyPath(s) { return v }
            }
            return nil
        }
        func window(kind: String, pct: Double?, reset: String?) -> RateWindow? {
            guard let pct else { return nil }
            let resetDate = reset.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
            return RateWindow(
                kind: kind, usedPercent: pct, used: nil, limit: nil, remaining: nil,
                resetAt: resetDate,
                resetsInSeconds: resetDate.map { $0.timeIntervalSinceNow }
            )
        }
        switch id {
        case "codex":
            guard let w = lastValue({ $0.codexWeekly }) else { return nil }
            return ProviderResult(id: id, name: p.name, plan: nil,
                weekly: window(kind: "weekly", pct: w, reset: lastValue({ $0.codexWeeklyReset })),
                fiveHour: window(kind: "fiveHour", pct: lastValue({ $0.codex5h }), reset: lastValue({ $0.codex5hReset })),
                balance: nil, todayUsage: nil, error: nil, stale: true)
        case "claude":
            let w = lastValue({ $0.claudeWeekly }), f = lastValue({ $0.claude5h })
            guard w != nil || f != nil else { return nil }
            let plan = (try? Auth.claudeTokens()).flatMap {
                ClaudeValue.planName(
                    subscriptionType: $0.subscriptionType,
                    rateLimitTier: $0.rateLimitTier
                )
            }
            return ProviderResult(id: id, name: p.name, plan: plan,
                weekly: window(kind: "weekly", pct: w, reset: lastValue({ $0.claudeWeeklyReset })),
                fiveHour: window(kind: "fiveHour", pct: f, reset: lastValue({ $0.claude5hReset })),
                balance: nil, todayUsage: nil, error: nil, stale: true)
        case "antigravity":
            let w = lastValue({ $0.antigravityWeekly }), f = lastValue({ $0.antigravity5h })
            guard w != nil || f != nil else { return nil }
            let cachedPlan = StateStore.loadProviderCache()["antigravity"]?.plan
            return ProviderResult(id: id, name: p.name, plan: p.plan ?? cachedPlan,
                weekly: window(kind: "weekly", pct: w, reset: lastValue({ $0.antigravityWeeklyReset })),
                fiveHour: window(kind: "fiveHour", pct: f, reset: lastValue({ $0.antigravity5hReset })),
                balance: nil, todayUsage: nil, error: nil, stale: true)
        case "deepseek":
            let b = lastValue({ $0.dsBalance })
            guard let b else { return nil }
            return ProviderResult(id: id, name: p.name, plan: nil,
                weekly: nil, fiveHour: nil,
                balance: Balance(currency: "CNY", total: b, granted: 0, toppedUp: b),
                todayUsage: nil, error: nil, stale: true)
        case "colab":
            let b = lastValue({ $0.colabBalance })
            guard let b else { return nil }
            return ProviderResult(id: id, name: p.name, plan: nil,
                weekly: nil, fiveHour: nil,
                balance: Balance(currency: "CU", total: b, granted: 0, toppedUp: b),
                todayUsage: nil, error: nil, stale: true)
        default:
            return nil
        }
    }

    /// Whether a provider result has any data to render
    private func hasData(_ p: ProviderResult) -> Bool {
        p.weekly != nil || p.fiveHour != nil || p.balance != nil || p.todayUsage != nil
    }
}
