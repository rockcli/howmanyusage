import Cocoa
import Foundation
import SwiftUI

// --once: CLI mode, print a text report and exit (for testing)
if CommandLine.arguments.contains("--claude-quota") {
    // Read-only live quota probe; source overrides never alter either client's credentials.
    let sources: [ClaudeQuotaSource] = CommandLine.arguments.contains("--desktop-only") ? [.desktop]
        : CommandLine.arguments.contains("--cli-only") ? [.cli] : [.desktop, .cli]
    Task.detached {
        do {
            let (data, credential) = try await ClaudeQuota.fetch(sources: sources)
            print("Claude quota source: \(credential.source.rawValue)")
            for key in ["five_hour", "seven_day"] {
                let window = data[key] as? [String: Any]
                print("\(key): \(window?["utilization"] ?? "unavailable")%; resets: \(window?["resets_at"] ?? "unknown")")
            }
            exit(0)
        } catch { print("Claude quota unavailable: \(error.localizedDescription)"); exit(1) }
    }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--claude-usage") {
    let now = Date()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    let today = calendar.startOfDay(for: now)
    let boundary = WeeklyWindow.start(id: "claude")
    let usage = TodayStatsScanner.scanClaude(home: FileManager.default.homeDirectoryForCurrentUser,
        now: now, cutoff: boundary ?? today, weekStart: today.addingTimeInterval(-6 * 86400),
        todayStart: today, tomorrowStart: today.addingTimeInterval(86400), windowStart: boundary)
    let stats = TodayStats(claudeWindowCostUSD: usage.claudeWindowCost, claudeWindowStart: boundary,
        claudeWindowUnpriced: usage.claudeWindowUnpriced)
    let provider = StateStore.loadProviderCache()["claude"]
    let monthly = ClaudeValue.monthlyValue(stats: stats, boundary: boundary, usedPercent: provider?.weekly?.usedPercent)
    print("Claude window USD: \(usage.claudeWindowCost); unpriced: \(usage.claudeWindowUnpriced)")
    print("Claude today tokens: \(usage.claudeTodayTokens ?? 0)")
    if let monthly, let price = ClaudeValue.planPriceMonthly(for: provider?.plan), price > 0 {
        print(String(format: "Claude value: $%.0f/mo · %.0f×", monthly, monthly / price))
    } else { print("Claude value: —") }
} else if CommandLine.arguments.contains("--speed") {
    let snapshot = ModelSpeedScanner().scan()
    print((snapshot.lines + [CodexSpeed.Snapshot.explanation]).joined(separator: "\n"))
} else if CommandLine.arguments.contains("--server-usage") {
    // Diagnostics for the server-side attribution (read-only).
    Task.detached {
        let since = Date().addingTimeInterval(-9 * 86_400)
        let ids = CodexServerUsage.harvestConversationIDs(since: since)
        let localIDs = CodexServerUsage.localRolloutThreadIDs()
        print("harvested conversation ids: \(ids.count)")
        print("local rollout thread ids: \(localIDs.count)")
        let windowStart = WeeklyWindow.start(id: "codex")
        print("safe window start: \(windowStart.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown")")
        if let snapshot = await CodexServerUsage.fetch(days: 8, windowStart: windowStart) {
            print("days: \(snapshot.days.count)  conversations: \(snapshot.conversations.count)")
            print("cloud quota pct: \(snapshot.cloudQuotaPct.map { String(format: "%.2f%%", $0) } ?? "nil")")
            print("local quota pct: \(snapshot.localQuotaPct.map { String(format: "%.2f%%", $0) } ?? "nil")")
            print("cloud token share (8d): \(snapshot.cloudTokenShare().map { String(format: "%.1f%%", $0 * 100) } ?? "nil")")
            print("notes: \(snapshot.notes)")
            print("valuation scope: \(snapshot.valuationNote(windowStart: windowStart))")
            let usedPercent = StateStore.loadProviderCache()["codex"]?.weekly?.usedPercent
            let source = snapshot.sourceLine(usedPercent: usedPercent, windowStart: windowStart) ?? "n/a"
            let cloud = snapshot.cloudUSD(windowStart: windowStart, using: CodexValue.cloudPricing,
                usedPercent: usedPercent, localUSD: StateStore.loadTodayStats()?.codexCost(in: windowStart) ?? 0)
                .map { String(format: "$%.0f Sol-equiv", $0) } ?? "n/a"
            print("source line: \(source) · cloud \(cloud)")
            for day in snapshot.days.suffix(4) {
                print("  \(day.date)  local \(day.local.total)  cloud \(day.cloud.total)  other \(day.other.total)")
            }
        } else {
            print("fetch failed (daily token split unavailable)")
        }
        exit(0)
    }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--once") {
    Task.detached {
        let report = await Providers.fetchAll()
        let inputs = Providers.stateInputs(report)
        let dot = StateStore.updateWindows(inputs.windows)
        StateStore.appendSnapshot(inputs.snapshot)
        if dot { FileHandle.standardError.write(Data("reset-dot: true\n".utf8)) }
        if report.contains(where: { $0.id == "codex" }) {
            let windowStart = WeeklyWindow.start(id: "codex")
            if let serverUsage = await CodexServerUsage.fetch(days: 8, windowStart: windowStart), !serverUsage.days.isEmpty {
                StateStore.saveCodexServerUsage(serverUsage)
            }
        }
        let stats = TodayStatsScanner.scan()
        print(Render.textReport(report, logStats: stats))
        exit(report.contains { !$0.ok } ? 1 : 0)
    }
    RunLoop.main.run()
} else if let idx = CommandLine.arguments.firstIndex(of: "--popover-screenshot"),
          idx + 1 < CommandLine.arguments.count {
    let outPath = CommandLine.arguments[idx + 1]
    Task { @MainActor in
        _ = NSApplication.shared
        let cached = StateStore.loadProviderCache()
        let fetched = await Providers.fetchAll()
        var shown: [ProviderResult] = []
        for p in fetched {
            if p.ok {
                StateStore.saveProviderCache(p)
                shown.append(p)
            } else if let c = cached[p.id] {
                var stale = c
                stale.stale = true
                shown.append(stale)
            } else {
                shown.append(p)
            }
        }
        let inputs = Providers.stateInputs(shown)
        _ = StateStore.updateWindows(inputs.windows)
        StateStore.appendSnapshot(inputs.snapshot)
        if shown.contains(where: { $0.id == "codex" }) {
            let windowStart = WeeklyWindow.start(id: "codex")
            if let serverUsage = await CodexServerUsage.fetch(days: 8, windowStart: windowStart), !serverUsage.days.isEmpty {
                StateStore.saveCodexServerUsage(serverUsage)
            }
        }
        let stats = TodayStatsScanner.scan()
        let history = UsageHistoryScanner.loadSnapshot() ?? UsageHistoryScanner.scan()
        let speed = ModelSpeedScanner().scan()
        let now = Date()

        let model = UsagePopoverModel()
        model.history = history
        model.speed = speed
        model.update(report: shown, updatedAt: now, todayStats: stats, now: now)

        let width: CGFloat = 470
        let hosting = NSHostingView(rootView: UsagePopoverView(model: model).environment(\.colorScheme, .dark))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 800)
        hosting.layoutSubtreeIfNeeded()
        let expandedHeight = ceil(hosting.fittingSize.height)
        let visibleHeight = (NSScreen.main?.visibleFrame.height ?? 1000) - 20
        if expandedHeight > visibleHeight {
            model.speedCollapsible = true
            model.speedCollapsed = !CommandLine.arguments.contains("--expand-speed")
            hosting.rootView = UsagePopoverView(model: model).environment(\.colorScheme, .dark)
            hosting.layoutSubtreeIfNeeded()
        }
        let height = max(400, ceil(hosting.fittingSize.height))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1.0)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 250_000_000)
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(1) }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try png.write(to: URL(fileURLWithPath: outPath))
        exit(0)
    }
    RunLoop.main.run()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
