import Cocoa
import SwiftUI

/// Native popover presentation model driven directly by structured provider results.
@MainActor
final class UsagePopoverModel: ObservableObject {
    struct WindowCard {
        let quotaLabel: String
        let quotaID: String
        let quotaWindow: RateWindow?
        var quotaTodayDelta: Double? = nil
        var quotaExhaustsIn: TimeInterval? = nil
        var quotaProjectedAtReset: Double? = nil
        var quotaSpikeDelta: Double? = nil
        var quotaStale = false
    }

    struct Provider {
        let id: String
        let headerTitle: NSAttributedString
        var windows: [WindowCard] = []
        var showPeakStrip: Bool = false
        var todayText: String? = nil
        var statusLine: NSAttributedString? = nil
    }

    @Published var providers: [Provider] = []
    @Published var deepSeekBalanceSpike: Double? = nil
    @Published var colabBalanceSpike: Double? = nil
    @Published var speed = CodexSpeed.Snapshot()
    @Published var speedCollapsible = false
    @Published var speedCollapsed = false
    var userExpandedSpeed = false
    @Published var updatedAt: Date?
    @Published var report: [ProviderResult] = []
    @Published var history: UsageHistory? = UsageHistoryScanner.loadSnapshot()
    @Published private(set) var historyLoading = false
    @Published var isPopoverVisible = false
    private var historyScannedAt = Date.distantPast

    var onOpenProvider: ((String) -> Void)?
    var onRefresh: (() -> Void)?
    var onQuit: (() -> Void)?
    var onToggleSpeed: (() -> Void)?

    func toggleSpeedCollapsed() {
        speedCollapsed.toggle()
        userExpandedSpeed = !speedCollapsed
        onToggleSpeed?()
    }

    func refreshHistory(force: Bool = false) {
        guard !historyLoading, force || Date().timeIntervalSince(historyScannedAt) > RefreshSchedule.data else { return }
        historyLoading = true
        let hasCachedSnapshot = history != nil
        Task {
            let result = await Task.detached(priority: .utility) { [weak self] in
                UsageHistoryScanner.scan(progress: { snapshot in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.historyLoading, !hasCachedSnapshot else { return }
                        self.history = snapshot
                    }
                })
            }.value
            history = result
            historyScannedAt = Date()
            historyLoading = false
        }
    }

    func openProvider(_ id: String) {
        onOpenProvider?(id)
    }

    func update(
        report: [ProviderResult],
        updatedAt: Date?,
        todayStats: TodayStats? = nil,
        deltas: [String: Double]? = nil,
        paces: [String: (dailyRate: Double, exhaustsIn: TimeInterval?, projectedAtReset: Double?)]? = nil,
        snapshots: [UsageSnapshot]? = nil,
        now: Date = Date()
    ) {
        self.report = report
        self.updatedAt = updatedAt
        self.deepSeekBalanceSpike = TodayStatsScanner.deepSeekBalanceSpike(history: snapshots, now: now)
        self.colabBalanceSpike = TodayStatsScanner.colabBalanceSpike(history: snapshots, now: now)
        let resolvedDeltas = deltas ?? TodayStatsScanner.todayWeeklyDeltas()

        var built: [Provider] = []
        for p in report {
            var headerSuffix: String?
            var headerPlan: String? = p.plan
            var headerPlanColor: NSColor?
            switch p.id {
            case "codex":
                headerPlan = CodexValue.displayPlanName(for: p.plan)
                let serverUsage = StateStore.loadCodexServerUsage()
                let windowStart = WeeklyWindow.start(id: p.id, resetAt: p.weekly?.resetAt)
                let localUSD = todayStats?.codexCost(in: windowStart) ?? 0
                let usedPct = p.weekly?.usedPercent ?? todayStats?.codexWindowPct
                let raw = CodexServerUsage.codexExtrapolatedValue(
                    serverUsage: serverUsage, windowStart: windowStart,
                    usedPercent: usedPct, localUSD: localUSD
                ).monthly
                let localTokens = todayStats?.codexTokens(in: windowStart) ?? 0
                let cloudTokens = serverUsage?.daysInWindow(windowStart).reduce(0) { UsageNumbers.sum($0, $1.cloud.total) } ?? 0
                let wkTokens = CodexValue.weeklyLimitText(tokensSoFar: Double(UsageNumbers.sum(localTokens, cloudTokens)), pctSoFar: usedPct ?? 0)
                let tokenSuffix = wkTokens.map { " · \($0)" } ?? ""
                if let raw, let planPrice = CodexValue.planPriceMonthly(for: p.plan), planPrice > 0 {
                    headerSuffix = String(format: "%.0f×", raw / planPrice) + tokenSuffix
                } else if raw == nil {
                    headerSuffix = wkTokens ?? "estimating"
                } else {
                    headerSuffix = wkTokens
                }
            case "claude":
                let boundary = WeeklyWindow.start(id: "claude", resetAt: p.weekly?.resetAt)
                let wkTokens = ClaudeValue.weeklyLimitText(stats: todayStats, boundary: boundary, usedPercent: p.weekly?.usedPercent)
                let tokenSuffix = wkTokens.map { " · \($0)" } ?? ""
                if let monthly = ClaudeValue.monthlyValue(stats: todayStats,
                    boundary: boundary, usedPercent: p.weekly?.usedPercent),
                   let planPrice = ClaudeValue.planPriceMonthly(for: p.plan), planPrice > 0 {
                    headerSuffix = String(format: "%.0f×", monthly / planPrice) + tokenSuffix
                } else {
                    headerSuffix = wkTokens ?? "—"
                }
            case "deepseek", "colab":
                if let balance = p.balance {
                    headerPlan = Render.formatAmount(balance.total, currency: balance.currency)
                    headerPlanColor = balance.total < 10 ? .systemYellow : nil
                }
            case "antigravity":
                let boundary = WeeklyWindow.start(id: "antigravity", resetAt: p.weekly?.resetAt)
                    ?? p.weekly?.resetAt.map { $0.addingTimeInterval(-7 * 86400) }
                let wkTokens = AntigravityValue.weeklyLimitText(
                    stats: todayStats, boundary: boundary, usedPercent: p.weekly?.usedPercent,
                    allowFallbackScan: false
                )
                let tokenSuffix = wkTokens.map { " · \($0)" } ?? ""
                if let monthly = AntigravityValue.monthlyValue(
                    stats: todayStats, boundary: boundary, usedPercent: p.weekly?.usedPercent,
                    allowFallbackScan: false
                ), let planPrice = AntigravityValue.planPriceMonthly(for: p.plan), planPrice > 0 {
                    headerSuffix = String(format: "%.0f×", monthly / planPrice) + tokenSuffix
                } else {
                    headerSuffix = wkTokens ?? "—"
                }
            default:
                break
            }

            let displayName = p.id == "antigravity" ? "Google" : p.name
            let title = Render.headerTitle(
                name: displayName, plan: headerPlan, stale: p.stale, suffix: headerSuffix, planColor: headerPlanColor
            )
            var section = Provider(id: p.id, headerTitle: title)
            let hasAnyData = p.weekly != nil || p.fiveHour != nil || p.balance != nil || p.todayUsage != nil

            if let err = p.error, !p.stale, !hasAnyData {
                section.statusLine = Render.attributed("  \(err)", color: Render.softRed, dim: true)
            } else if hasAnyData {
                if let w = p.weekly {
                    let pace = paces?[p.id] ?? TodayStatsScanner.quotaPace(id: p.id, history: snapshots, now: now, resetAt: w.resetAt)
                    let spike = TodayStatsScanner.quotaSpike(id: p.id, kind: "weekly", history: snapshots, now: now)
                    section.windows.append(WindowCard(
                        quotaLabel: "Weekly",
                        quotaID: p.id,
                        quotaWindow: w,
                        quotaTodayDelta: resolvedDeltas[p.id],
                        quotaExhaustsIn: pace?.exhaustsIn,
                        quotaProjectedAtReset: pace?.projectedAtReset,
                        quotaSpikeDelta: spike,
                        quotaStale: p.stale || !p.ok
                    ))
                }
                if p.fiveHourValid {
                    let spike = TodayStatsScanner.quotaSpike(id: p.id, kind: "fiveHour", history: snapshots, now: now)
                    section.windows.append(WindowCard(
                        quotaLabel: "5h",
                        quotaID: p.id,
                        quotaWindow: p.fiveHour,
                        quotaSpikeDelta: spike,
                        quotaStale: p.stale || !p.ok
                    ))
                }
                if let today = p.todayUsage, (p.id != "deepseek" && p.id != "colab") || p.balance == nil {
                    section.todayText = Render.todayUsageText(today)
                }
            } else {
                section.statusLine = Render.attributed("  data unavailable", color: .secondaryLabelColor, dim: true)
            }
            built.append(section)
        }
        self.providers = built
    }
}

struct UsagePopoverView: View {
    @ObservedObject var model: UsagePopoverModel

    private let spacing: CGFloat = 18
    private var separator: some View { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("HowManyUsage").font(.system(size: 15, weight: .semibold))
                Spacer()
                if let date = model.updatedAt {
                    Text("Updated \(Render.timeFormatter.string(from: date))")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }.padding(.horizontal, spacing).padding(.top, 14).padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 0) {
                if model.providers.isEmpty {
                    Text(model.updatedAt == nil ? "Loading…" : "No supported AI tools detected")
                        .foregroundColor(.secondary)
                        .padding(.vertical, 12)
                }
                ForEach(model.providers, id: \.id) { provider in
                    providerSection(provider)
                }
                if !model.providers.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Summary").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            if model.historyLoading { Text("Updating…").font(.system(size: 10)).foregroundColor(.secondary) }
                        }
                        SummaryCharts(history: model.history)
                    }.padding(.vertical, 12)
                }
                separator
                speedSection.padding(.top, 9).padding(.bottom, 7)
            }.padding(.horizontal, spacing)

            separator
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button("Refresh") { model.onRefresh?() }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Refresh · auto every 10 min")
                Button("Quit") { model.onQuit?() }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.secondary)
            .padding(.horizontal, spacing).padding(.vertical, 8)
        }
        .frame(width: 470)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func providerSection(_ provider: UsagePopoverModel.Provider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { model.openProvider(provider.id) }) {
                if (provider.id == "deepseek" || provider.id == "colab"),
                   let current = model.report.first(where: { $0.id == provider.id }),
                   let balance = current.balance {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(provider.id == "colab" ? "Colab" : "DeepSeek").font(.system(size: 13, weight: .semibold))
                        if current.stale { Text("●").font(.system(size: 9)).foregroundColor(.yellow) }
                        Spacer()
                        if provider.id == "deepseek", let spike = model.deepSeekBalanceSpike {
                            Text("⚠ -¥\(UsageNumbers.wholeText(spike))")
                                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                                .foregroundColor(Color(nsColor: Render.softRed))
                        } else if provider.id == "colab", let spike = model.colabBalanceSpike {
                            Text("⚠ -\(UsageNumbers.wholeText(spike)) CU")
                                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                                .foregroundColor(Color(nsColor: Render.softRed))
                        }
                        if provider.id == "colab", let note = current.todayUsage?.costNote, !note.isEmpty {
                            Text(note)
                                .font(.system(size: 10)).monospacedDigit().foregroundColor(.secondary)
                        }
                        if let today = current.todayUsage {
                            Text("Today \(Render.formatAmount(today.cost, currency: today.currency))")
                                .font(.system(size: 10)).monospacedDigit().foregroundColor(.secondary)
                        }
                        Text(Render.formatAmount(balance.total, currency: balance.currency))
                            .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                            .foregroundColor(balance.total < 10 ? .yellow : .primary)
                    }.frame(height: 20)
                } else {
                    NativeAttributedLabel(value: provider.headerTitle)
                        .frame(height: 20)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(provider.headerTitle.string)
            .accessibilityHint("Open usage page")
            .help("Open \(provider.id) usage")

            if !provider.windows.isEmpty {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(Array(provider.windows.enumerated()), id: \.offset) { _, window in
                        QuotaPanelCard(row: window, isPopoverVisible: model.isPopoverVisible).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if provider.windows.count == 1 { Color.clear.frame(maxWidth: .infinity).frame(height: 1) }
                }
            }
            if provider.showPeakStrip {
                PeakPanelRow()
            }
            if let todayText = provider.todayText {
                HStack {
                    Text("Today").foregroundColor(.secondary)
                    Spacer()
                    Text(todayText).monospacedDigit().foregroundColor(.secondary)
                }.font(.system(size: 12)).frame(minHeight: 18)
            }
            if let statusLine = provider.statusLine {
                NativeAttributedLabel(value: statusLine)
                    .frame(minHeight: 18)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { separator }
    }

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Speed").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.speedCollapsible {
                    Button(action: { model.toggleSpeedCollapsed() }) {
                        HStack(spacing: 4) {
                            Text("4h avg")
                            Image(systemName: model.speedCollapsed ? "chevron.down" : "chevron.up")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help(model.speedCollapsed ? "Expand Speed (4h avg)" : "Collapse Speed (4h avg)")
                    .accessibilityLabel(model.speedCollapsed ? "Expand Speed" : "Collapse Speed")
                } else {
                    Text("4h avg").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            if !model.speedCollapsed {
                speedLine("Model", "TTFT", "Output · tok/s", "Cache", header: true)
                if model.speed.rows.isEmpty {
                    Text("No timing samples in the last 4h").foregroundColor(.secondary).font(.system(size: 12))
                }
                ForEach(model.speed.rows, id: \.name) { row in
                    speedLine(row.name,
                        row.ttft.map { String(format: "%.1fs", $0) } ?? "—",
                        row.tps.map { String(format: row.includesWait ? "~%.0f" : "%.0f", $0) } ?? "—",
                        row.cachePercent.map { String(format: "%.0f%%", $0) } ?? "—")
                }
            }
        }
    }

    private func speedLine(_ name: String, _ wait: String, _ output: String, _ cache: String, header: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(name).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            Text(wait).frame(width: 43, alignment: .trailing)
            Text(output).frame(width: 90, alignment: .trailing)
            Text(cache).frame(width: 46, alignment: .trailing)
        }
        .font(.system(size: header ? 11 : 12))
        .monospacedDigit()
        .foregroundColor(header ? .secondary : .primary)
        .frame(minHeight: 20)
    }
}

enum ActivityScale {
    static func level(for prompts: Int) -> Int {
        switch prompts {
        case ..<1: return 0
        case 1..<10: return 1
        case 10..<30: return 2
        case 30..<80: return 3
        case 80..<160: return 4
        case 160..<300: return 5
        default: return 6
        }
    }

    // Explicit palettes keep adjacent activity levels distinct in both appearances.
    static let light: [Color] = [
        Color(red: 0.88, green: 0.94, blue: 0.89),
        Color(red: 0.71, green: 0.91, blue: 0.75),
        Color(red: 0.48, green: 0.85, blue: 0.61),
        Color(red: 0.23, green: 0.77, blue: 0.43),
        Color(red: 0.07, green: 0.60, blue: 0.33),
        Color(red: 0.03, green: 0.44, blue: 0.23),
        Color(red: 0.01, green: 0.29, blue: 0.12),
    ]
    static let dark: [Color] = [
        Color(red: 0.20, green: 0.27, blue: 0.23),
        Color(red: 0.65, green: 0.86, blue: 0.69),
        Color(red: 0.44, green: 0.79, blue: 0.55),
        Color(red: 0.24, green: 0.73, blue: 0.43),
        Color(red: 0.10, green: 0.66, blue: 0.35),
        Color(red: 0.07, green: 0.51, blue: 0.26),
        Color(red: 0.03, green: 0.36, blue: 0.19),
    ]
}

private struct SummaryCharts: View {
    let history: UsageHistory?
    @Environment(\.colorScheme) private var colorScheme
    private let colors: [Color] = [.green, .orange, .blue, .purple]
    private let chartHeight: CGFloat = 95
    private var recent: [UsageHistory.Day] { Array((history?.days ?? []).suffix(7)) }
    private var peak: Int { max(1, recent.map(\.total).max() ?? 0) }
    private var offset: Int {
        guard let first = history?.days.first else { return 0 }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return (cal.component(.weekday, from: first.date) + 5) % 7
    }
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMM d"; f.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!; return f
    }()
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                HStack { Text("Tokens").fontWeight(.medium); Spacer(); Text("7 days · max \(recent.contains(where: { $0.total > 0 }) ? compact(peak) : "—")").foregroundColor(.secondary) }
                HStack(alignment: .bottom, spacing: 7) {
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, day in
                        VStack(spacing: 3) {
                            VStack(spacing: 0) {
                                ForEach((0..<4).reversed(), id: \.self) { n in
                                    let values = [day.codex, day.claude, day.deepseek, day.antigravity]
                                    colors[n].opacity(0.8).frame(height: chartHeight * CGFloat(max(0, values[n])) / CGFloat(peak))
                                }
                            }.frame(maxWidth: .infinity, minHeight: chartHeight, alignment: .bottom)
                        }
                        .help("\(dateFormatter.string(from: day.date)): Codex (green) \(day.codex), Claude (orange) \(day.claude), DeepSeek (blue) \(day.deepseek), Antigravity (purple) \(day.antigravity) tokens")
                        .accessibilityLabel("\(dateFormatter.string(from: day.date)): Codex \(day.codex), Claude \(day.claude), DeepSeek \(day.deepseek), Antigravity \(day.antigravity) tokens")
                    }
                }.font(.system(size: 9))
            }.frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 7) {
                HStack { Text("Activity").fontWeight(.medium); Spacer(); Text("\(UsageHistoryScanner.weeks) weeks").foregroundColor(.secondary) }
                if let days = history?.days {
                    VStack(spacing: 3) {
                        ForEach(0..<7) { row in
                            HStack(spacing: 3) {
                                ForEach(0..<(UsageHistoryScanner.weeks + 1), id: \.self) { column in
                                    let index = column * 7 + row - offset
                                    if days.indices.contains(index) {
                                        let day = days[index]
                                        let description = "\(dateFormatter.string(from: day.date)): \(day.observed ? "\(day.prompts) prompts observed" : "No local records; history unknown")"
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(day.observed ? (colorScheme == .dark ? ActivityScale.dark : ActivityScale.light)[ActivityScale.level(for: day.prompts)] : Color.clear)
                                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(day.observed && colorScheme == .dark ? Color.white.opacity(0.14) : Color.clear, lineWidth: 0.5))
                                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(day.observed ? Color.clear : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 0.8, dash: [2, 2])))
                                            .help(description)
                                            .accessibilityLabel(description)
                                    } else { Color.clear }
                                }.frame(width: 11, height: 11)
                            }
                        }
                    }
                } else { Text("Loading…").foregroundColor(.secondary).frame(height: 95) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 10))
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}

private struct QuotaPanelCard: View {
    let row: UsagePopoverModel.WindowCard
    let isPopoverVisible: Bool

    private var value: String {
        if let pct = row.quotaWindow?.validUsedPercent { return "\(UsageNumbers.wholeText(pct))%" }
        if let used = row.quotaWindow?.used, let limit = row.quotaWindow?.limit { return "\(UsageNumbers.wholeText(used, rounding: .towardZero))/\(UsageNumbers.wholeText(limit, rounding: .towardZero))" }
        return row.quotaWindow == nil ? "N/A" : "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.quotaLabel).foregroundColor(.secondary).font(.system(size: 12))
                Spacer(minLength: 4)
                Text(value).font(.system(size: 16, weight: .semibold)).monospacedDigit()
                    .foregroundColor(row.quotaWindow?.validUsedPercent.map { Color(nsColor: Render.color(for: $0)) } ?? .secondary)
            }
            NativeQuotaBar(pct: row.quotaWindow?.validUsedPercent, todayDelta: row.quotaTodayDelta)
                .frame(height: 7)
            if isPopoverVisible {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    detailsLabel(at: context.date)
                }
            } else {
                detailsLabel(at: Date())
            }
        }
    }

    private func detailsLabel(at date: Date) -> some View {
        let details = QuotaMenuRowView.details(
            window: row.quotaWindow, id: row.quotaID,
            exhaustsIn: row.quotaExhaustsIn, projectedAtReset: row.quotaProjectedAtReset,
            spikeDelta: row.quotaSpikeDelta, stale: row.quotaStale, now: date
        )
        return NativeAttributedLabel(value: details, wrap: true).frame(minHeight: 15)
    }
}

private struct NativeQuotaBar: NSViewRepresentable {
    let pct: Double?
    let todayDelta: Double?
    func makeNSView(context: Context) -> QuotaBarView { QuotaBarView() }
    func updateNSView(_ view: QuotaBarView, context: Context) {
        view.barHeight = 5
        let validPct = UsageNumbers.percent(pct)
        view.pct = validPct
        view.color = validPct.map(Render.color(for:)) ?? .systemGreen
        view.todayStartPct = validPct.flatMap { p in todayDelta.flatMap { $0.isFinite && $0 >= 0.5 ? max(0, p - $0) : nil } }
        view.setAccessibilityLabel("Quota used \(validPct.map { "\(UsageNumbers.wholeText($0)) percent" } ?? "unavailable")")
    }
}

private struct PeakPanelRow: View {
    private var details: NSAttributedString {
        let status = DeepSeekPeak.status()
        return PeakValleyRowView.detailText(peakNow: status.isPeak, untilTransition: status.untilTransition,
            weekend: DeepSeekPeak.isWeekendBeijing(), holiday: DeepSeekPeak.isChineseHolidayBeijing())
    }
    var body: some View {
        HStack(spacing: 8) {
            NativeAttributedLabel(value: details).frame(height: 18)
            NativePeakStrip().frame(width: 100, height: 12)
        }
    }
}

private struct NativePeakStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> PeakValleyStripView { PeakValleyStripView() }
    func updateNSView(_ view: PeakValleyStripView, context: Context) { view.isPeak = DeepSeekPeak.status().isPeak }
}

private struct NativeAttributedLabel: NSViewRepresentable {
    let value: NSAttributedString
    var wrap = false
    func makeNSView(context: Context) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.isSelectable = false
        label.drawsBackground = false
        return label
    }
    func updateNSView(_ label: NSTextField, context: Context) {
        label.attributedStringValue = value
        label.usesSingleLineMode = !wrap
        label.maximumNumberOfLines = wrap ? 0 : 1
        label.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
    }
}
