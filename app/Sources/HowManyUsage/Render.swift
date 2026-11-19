import Cocoa

/// Popover / CLI rendering: progress bars, colors, durations
enum Render {
    private static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let monoBold = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    /// Next-reset clock time (local time), used for the 5h row instead of a countdown.
    static let resetClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    /// Same clock, with the weekday — for resets more than a day out (e.g. DeepSeek
    /// peak resuming Monday after the weekend-off rule).
    static let resetDayClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE HH:mm"
        return f
    }()
    /// " (UTC+8 HH:mm)" to append after a local clock so Beijing time is readable at
    /// a glance. Empty when the machine itself runs UTC+8 — showing it twice is noise.
    static func utc8Suffix(for date: Date) -> String {
        guard TimeZone.current.secondsFromGMT(for: date) != 8 * 3600 else { return "" }
        return " (UTC+8 \(resetClockFormatter.string(from: date)))"
    }

    /// Slightly desaturated red for quota bars / errors: systemRed is too bright.
    /// Keeps the red hue; reduces saturation ~15% and brightness a touch.
    static let softRed: NSColor = {
        let c = NSColor.systemRed.usingColorSpace(.sRGB) ?? .systemRed
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: max(0, s * 0.85), brightness: min(1, b * 0.97), alpha: a)
    }()

    static func color(for pct: Double) -> NSColor {
        guard let pct = UsageNumbers.percent(pct) else { return .secondaryLabelColor }
        if pct >= 90 { return Render.softRed }
        if pct >= 60 { return .systemOrange }
        return .systemGreen
    }

    static func attributed(_ text: String, color: NSColor? = nil, bold: Bool = false, dim: Bool = false) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .foregroundColor: color ?? (dim ? .secondaryLabelColor : .labelColor),
            .font: bold ? monoBold : mono,
        ])
    }

    /// Tool header title: name (plan), with a yellow dot when the data is stale (cached).
    /// `suffix` is appended in light secondary color (e.g. the plan value multiple).
    /// `planColor` tints just the "(plan)" part.
    static func headerTitle(
        name: String, plan: String?, stale: Bool, suffix: String? = nil, planColor: NSColor? = nil
    ) -> NSAttributedString {
        let line = NSMutableAttributedString()
        line.append(NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]))
        if let plan {
            line.append(attributed(" (\(plan))", color: planColor, bold: true))
        }
        if let suffix, !suffix.isEmpty {
            line.append(attributed(" \(suffix)", color: .secondaryLabelColor))
        }
        if stale {
            line.append(attributed(" ●", color: .systemYellow, bold: true))
        }
        return line
    }

    /// Monospaced label (progress bars / numbers stay aligned)
    static func padLabel(_ label: String, width: Int = 7) -> String {
        label.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    /// Mini sparkline glyphs for Double values (oldest → newest).
    static func sparkline(_ values: [Double]) -> String {
        let glyphs = Array("▁▂▃▄▅▆▇█")
        guard values.allSatisfy(\.isFinite),
              let maxV = values.max(), let minV = values.min(), maxV > minV else { return "" }
        let scale = max(abs(minV), abs(maxV))
        return values.map { v in
            let t = (v / scale - minV / scale) / (maxV / scale - minV / scale)
            let idx = min(7, max(0, Int((t * 8).rounded()) - 1))
            return String(glyphs[idx])
        }.joined()
    }

    /// 7-day amount bars (oldest -> today); zero-value days render as the lowest bar.
    static func weekBars(_ week: [Double]) -> String {
        let glyphs = Array("▁▂▃▄▅▆▇█")
        guard week.isEmpty == false else { return "" }
        guard week.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return "" }
        guard let maxV = week.max(), maxV > 0 else { return String(repeating: "—", count: week.count) }
        return week.map { v in
            guard v > 0 else { return String(glyphs[0]) }
            let idx = min(7, max(0, Int((v / maxV * 8).rounded()) - 1))
            return String(glyphs[idx])
        }.joined()
    }

    /// A fixed template icon; macOS supplies the menu-bar tint for light and dark modes.
    static func staticStatusBarsImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 12))
        image.lockFocus()
        NSColor.black.setFill()
        for index in 0..<3 {
            let rect = NSRect(x: 1.5 + CGFloat(index) * 7, y: 1.5, width: 5, height: 9)
            NSBezierPath(roundedRect: rect, xRadius: 0.8, yRadius: 0.8).fill()
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    static func currencySymbol(_ currency: String) -> String {
        switch currency.uppercased() {
        case "CNY": return "¥"
        case "USD": return "$"
        case "EUR": return "€"
        default: return currency + " "
        }
    }

    static func formatAmount(_ amount: Double, currency: String) -> String {
        guard amount.isFinite else { return "—" }
        if currency.uppercased() == "CU" {
            return String(format: "%.2f CU", amount)
        }
        return String(format: "%@%.2f", currencySymbol(currency), amount)
    }

    /// Token count text (M / K)
    static func tokenText(_ usage: DailyUsage) -> String {
        if usage.totalTokens >= 1_000_000 {
            return String(format: "%.1fM tokens", Double(usage.totalTokens) / 1_000_000)
        }
        if usage.totalTokens >= 1_000 {
            return String(format: "%.0fK tokens", Double(usage.totalTokens) / 1_000)
        }
        return "\(usage.totalTokens) tokens"
    }

    /// Token count plus a cost suffix when the provider priced today's usage
    /// (e.g. `8.7M tokens · ¥3.21`). Plain token text when cost is zero.
    static func tokenTextWithCost(_ usage: DailyUsage) -> String {
        let costText = usage.cost > 0 || usage.costIsLowerBound == true
            ? formatAmount(usage.cost, currency: usage.currency)
            : ""
        // When token logs are unavailable but the wallet gives an exact spend,
        // show the amount alone rather than a misleading "0 tokens".
        if usage.totalTokens == 0, usage.cost > 0 || usage.costIsLowerBound == true {
            return costText
        }
        var text = tokenText(usage)
        if costText.isEmpty == false {
            text += " · \(costText)"
        }
        return text
    }

    /// Today usage text plus an optional 7-day amount bar suffix.
    static func todayUsageText(_ usage: DailyUsage, weekSpend: [Double]? = nil) -> String {
        var text = tokenTextWithCost(usage)
        if let weekSpend, weekSpend.isEmpty == false {
            text += "  " + weekBars(weekSpend)
        }
        return text
    }

    private static let todayGapGlyph = "\u{200A}"

    private static func todayGapIndex(_ pct: Double?, todayDelta: Double?, width: Int) -> Int? {
        guard let pct, let todayDelta, width > 0,
              pct.isFinite, todayDelta.isFinite, todayDelta >= 0.5 else { return nil }
        let startPct = min(100, max(0, pct - todayDelta))
        // Place the gap on the left edge of today's cell so the filled
        // cell(s) to its right remain visible.
        let startCell = Int((startPct / 100 * Double(width)).rounded(.up)) - 1
        return min(width - 1, max(0, startCell))
    }

    private static func barGlyphs(_ pct: Double?, width: Int, todayDelta: Double? = nil) -> [String] {
        guard width > 0 else { return [] }
        guard let pct = UsageNumbers.percent(pct) else { return Array(repeating: "·", count: width) }
        let filled = Int((min(1, max(0, pct / 100)) * Double(width)).rounded())
        var glyphs = Array(repeating: "░", count: width)
        for i in 0..<min(width, filled) { glyphs[i] = "█" }
        if let gap = todayGapIndex(pct, todayDelta: todayDelta, width: width) {
            glyphs[gap] = todayGapGlyph
        }
        return glyphs
    }

    static func barString(_ pct: Double?, width: Int, todayDelta: Double? = nil) -> String {
        barGlyphs(pct, width: width, todayDelta: todayDelta).joined()
    }

    static func durationText(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "unknown" }
        if seconds <= 0 { return "0m" }
        if seconds < 60 { return "<1m" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        guard let hours = Int(exactly: (seconds / 3600).rounded(.down)) else { return "unknown" }
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        let remHours = hours % 24
        return remHours > 0 ? "\(days)d \(remHours)h" : "\(days)d"
    }

    /// Plain-text report for --once mode.
    /// logStats: local-log scan results, for the plan value suffix on the headers.
    static func textReport(_ report: [ProviderResult], logStats: TodayStats? = nil) -> String {
        var out = ["AI usage overview"]
        let deltas = TodayStatsScanner.todayWeeklyDeltas()
        let deepSeekWeekSpend = TodayStatsScanner.deepSeekWeekSpend()
        let colabWeekSpend = TodayStatsScanner.colabWeekSpend()
        for p in report {
            out.append("")
            let displayPlan = p.id == "codex" ? CodexValue.displayPlanName(for: p.plan) : p.plan
            let displayName = p.id == "antigravity" ? "Google" : p.name
            var header = "\(displayName)\(displayPlan.map { "(\($0))" } ?? "")"
            switch p.id {
            case "codex":
                let serverUsage = StateStore.loadCodexServerUsage()
                let windowStart = WeeklyWindow.start(id: p.id, resetAt: p.weekly?.resetAt)
                let localUSD = logStats?.codexCost(in: windowStart) ?? 0
                let usedPct = p.weekly?.usedPercent ?? logStats?.codexWindowPct
                let raw = CodexServerUsage.codexExtrapolatedValue(
                    serverUsage: serverUsage, windowStart: windowStart,
                    usedPercent: usedPct, localUSD: localUSD
                ).monthly
                let estimate = (monthly: raw ?? 0, isPrior: false)
                let localTokens = logStats?.codexTokens(in: windowStart) ?? 0
                let cloudTokens = serverUsage?.daysInWindow(windowStart).reduce(0) { UsageNumbers.sum($0, $1.cloud.total) } ?? 0
                let wkTokens = CodexValue.weeklyLimitText(tokensSoFar: Double(UsageNumbers.sum(localTokens, cloudTokens)), pctSoFar: usedPct ?? 0)
                let tokenSuffix = wkTokens.map { " · \($0)" } ?? ""
                if raw == nil {
                    header += "  \(wkTokens ?? "estimating")"
                } else if let planPrice = CodexValue.planPriceMonthly(for: p.plan), planPrice > 0 {
                    header += String(format: "  %.0f×", estimate.monthly / planPrice) + tokenSuffix
                } else if let wkTokens {
                    header += "  \(wkTokens)"
                }
            case "claude":
                let boundary = WeeklyWindow.start(id: "claude", resetAt: p.weekly?.resetAt)
                let wkTokens = ClaudeValue.weeklyLimitText(stats: logStats, boundary: boundary, usedPercent: p.weekly?.usedPercent)
                let tokenSuffix = wkTokens.map { " · \($0)" } ?? ""
                if let monthly = ClaudeValue.monthlyValue(stats: logStats,
                    boundary: boundary, usedPercent: p.weekly?.usedPercent),
                   let planPrice = ClaudeValue.planPriceMonthly(for: p.plan), planPrice > 0 {
                    header += String(format: "  %.0f×", monthly / planPrice) + tokenSuffix
                } else { header += "  \(wkTokens ?? "—")" }
            case "antigravity":
                let boundary = WeeklyWindow.start(id: "antigravity", resetAt: p.weekly?.resetAt)
                    ?? p.weekly?.resetAt.map { $0.addingTimeInterval(-7 * 86400) }
                let wkTokens = AntigravityValue.weeklyLimitText(
                    stats: logStats, boundary: boundary, usedPercent: p.weekly?.usedPercent
                )
                let tokenSuffix = wkTokens.map { " · \($0)" } ?? ""
                if let monthly = AntigravityValue.monthlyValue(
                    stats: logStats, boundary: boundary, usedPercent: p.weekly?.usedPercent
                ), let planPrice = AntigravityValue.planPriceMonthly(for: p.plan), planPrice > 0 {
                    header += String(format: "  %.0f×", monthly / planPrice) + tokenSuffix
                } else {
                    header += "  \(wkTokens ?? "—")"
                }
            default:
                break
            }
            out.append(header)
            if let err = p.error {
                out.append("  ✗ \(err)")
            } else {
                if p.weekly != nil || p.fiveHourValid {
                    if let w = p.weekly {
                        var line = " \(padLabel("Weekly"))  " + windowText(w, todayDelta: deltas[p.id])
                        let pace = TodayStatsScanner.quotaPace(id: p.id, resetAt: w.resetAt)
                        line += " " + QuotaMenuRowView.details(
                            window: w, id: p.id, exhaustsIn: pace?.exhaustsIn,
                            projectedAtReset: pace?.projectedAtReset,
                            spikeDelta: TodayStatsScanner.quotaSpike(id: p.id, kind: "weekly"), stale: p.stale
                        ).string
                        out.append(line)
                    }
                    if p.fiveHourValid {
                        var line = " \(padLabel("5h"))  " + windowText(p.fiveHour)
                        if let spike = TodayStatsScanner.quotaSpike(id: p.id, kind: "fiveHour") {
                            line += " · ⚠ +\(UsageNumbers.wholeText(spike))%"
                        }
                        out.append(line)
                    }
                }
                if let balance = p.balance {
                    var line = " \(padLabel("Balance"))  \(formatAmount(balance.total, currency: balance.currency))"
                    if let trend = TodayStatsScanner.balanceTrend(id: p.id).map(Render.sparkline), !trend.isEmpty {
                        line += "  \(trend)"
                    }
                    if p.id == "deepseek", let spike = TodayStatsScanner.deepSeekBalanceSpike() {
                        line += " · ⚠ -¥\(UsageNumbers.wholeText(spike))"
                    } else if p.id == "colab", let spike = TodayStatsScanner.colabBalanceSpike() {
                        line += " · ⚠ -\(UsageNumbers.wholeText(spike)) CU"
                    }
                    out.append(line)
                }
                if let today = p.todayUsage {
                    let weekSpend: [Double]? = p.id == "deepseek" ? deepSeekWeekSpend
                        : (p.id == "colab" ? colabWeekSpend : nil)
                    var todayLine = " \(padLabel("Today"))  " + todayUsageText(today, weekSpend: weekSpend)
                    if p.id == "colab", let note = today.costNote, !note.isEmpty {
                        todayLine += " · \(note)"
                    }
                    out.append(todayLine)
                }
            }
        }
        return out.joined(separator: "\n")
    }

    private static func windowText(_ w: RateWindow?, todayDelta: Double? = nil) -> String {
        guard let w else { return "N/A" }
        let bar = barString(w.validUsedPercent, width: 20, todayDelta: todayDelta)
        var s = bar
        if let pct = w.validUsedPercent {
            s += " \(UsageNumbers.wholeText(pct))%"
        } else if let used = w.used, let limit = w.limit {
            s += " \(UsageNumbers.wholeText(used, rounding: .towardZero))/\(UsageNumbers.wholeText(limit, rounding: .towardZero))"
        }
        if w.kind == "weekly" { return s }
        if let resetAt = w.resetAt, resetAt.timeIntervalSince1970.isFinite {
            s += " · resets \(resetClockFormatter.string(from: resetAt))\(utc8Suffix(for: resetAt))"
        } else {
            s += " · \(durationText(w.remainingSeconds()))"
        }
        return s
    }
}

/// Thin rounded quota bar (track + colored fill + today-break marker).
final class QuotaBarView: NSView {
    var pct: Double? { didSet { needsDisplay = true } }
    var todayStartPct: Double? { didSet { needsDisplay = true } }
    var color: NSColor = .systemGreen { didSet { needsDisplay = true } }
    var barHeight: CGFloat = 10 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let h = min(bounds.height, max(0, barHeight))
        let y = (bounds.height - h) / 2
        let track = NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: bounds.width, height: h), xRadius: 3, yRadius: 3)
        NSColor.black.withAlphaComponent(0.12).setFill()
        track.fill()
        guard let pct = UsageNumbers.percent(pct), pct > 0 else { return }
        let w = max(6, bounds.width * CGFloat(min(1, max(0, pct / 100))))
        let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: w, height: h), xRadius: 3, yRadius: 3)
        color.setFill()
        fill.fill()

        if let todayStartPct, todayStartPct.isFinite {
            let gapX = min(w, max(0, bounds.width * CGFloat(min(100, max(0, todayStartPct)) / 100)))
            if gapX < w {
                let gapWidth = min(1.5, w - gapX)
                let gap = NSBezierPath(rect: NSRect(x: gapX, y: y, width: gapWidth, height: h))
                NSColor.black.withAlphaComponent(0.55).setFill()
                gap.fill()
            }
        }
    }
}

/// Attribution details formatter for a quota window card.
enum QuotaMenuRowView {
    static func details(
        window w: RateWindow?, id: String, exhaustsIn: TimeInterval?, projectedAtReset: Double?,
        spikeDelta: Double? = nil, stale: Bool = false, now: Date = Date()
    ) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let line = NSMutableAttributedString()
        func append(_ text: String, color: NSColor) {
            line.append(NSAttributedString(string: text, attributes: [
                .foregroundColor: color,
                .font: font,
            ]))
        }

        guard let w else { return line }
        let remaining = w.remainingSeconds(at: now)
        if let unused = WeeklyWindow.expiringUnusedPercent(
            window: w, stale: stale, projectedAtReset: projectedAtReset,
            exhaustsIn: exhaustsIn, spikeDelta: spikeDelta, now: now
        ) {
            append("· \(UsageNumbers.wholeText(unused))% unused", color: .systemTeal)
            append(" · resets in \(Render.durationText(remaining))", color: .secondaryLabelColor)
            return line
        }
        if w.kind == "weekly" {
            append(remaining.map { $0 <= 0 } == true ? "· reset due" : "· \(Render.durationText(remaining))", color: .secondaryLabelColor)
        } else if let resetAt = w.resetAt, resetAt.timeIntervalSince1970.isFinite {
            append("· resets \(Render.resetClockFormatter.string(from: resetAt))\(Render.utc8Suffix(for: resetAt))", color: .secondaryLabelColor)
        } else {
            append("· \(Render.durationText(remaining))", color: .secondaryLabelColor)
        }
        if !stale, let exhaustsIn, let reset = remaining,
           TodayStatsScanner.exhaustionWorthy(id: id, exhaustsIn: exhaustsIn, reset: reset) {
            append(" · ⚠ \(Render.durationText(exhaustsIn))", color: Render.softRed)
        } else if !stale, let projectedAtReset = UsageNumbers.percent(projectedAtReset),
                  let remaining, remaining > 0,
                  projectedAtReset < TodayStatsScanner.wasteThreshold {
            let left = max(0, 100 - projectedAtReset)
            let sat = TodayStatsScanner.hasSaturday(until: w.resetAt, now: now) ? " (Sat)" : ""
            append(" · \(UsageNumbers.wholeText(left))% left\(sat)", color: .systemGreen)
        }
        if !stale, let spikeDelta = UsageNumbers.percent(spikeDelta), spikeDelta > 0 {
            append(" · ⚠ +\(UsageNumbers.wholeText(spikeDelta))%", color: Render.softRed)
        }
        return line
    }
}

/// 24h peak/off-peak pricing strip: peak windows drawn as filled blocks over a light
/// off-peak track, with a marker for "now".
final class PeakValleyStripView: NSView {
    var isPeak: Bool = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let h: CGFloat = 10
        let y = (bounds.height - h) / 2
        let track = NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: bounds.width, height: h), xRadius: 3, yRadius: 3)
        NSColor.systemGreen.withAlphaComponent(0.16).setFill()
        track.fill()

        if !DeepSeekPeak.isWeekendBeijing(), !DeepSeekPeak.isChineseHolidayBeijing() {
            for w in DeepSeekPeak.peakWindowsUTC {
                let x0 = bounds.width * CGFloat(w.start / 24)
                let x1 = bounds.width * CGFloat(w.end / 24)
                Render.softRed.withAlphaComponent(0.6).setFill()
                NSBezierPath(rect: NSRect(x: x0, y: y, width: max(1, x1 - x0), height: h)).fill()
            }
        }

        let nowX = min(bounds.width - 1.5, bounds.width * CGFloat(DeepSeekPeak.hourOfDayUTC() / 24))
        NSColor.labelColor.withAlphaComponent(0.85).setFill()
        NSBezierPath(rect: NSRect(x: max(0, nowX), y: y - 1, width: 1.5, height: h + 2)).fill()
    }
}

/// DeepSeek peak/off-peak row formatter ("off-peak · turns 09:00").
enum PeakValleyRowView {
    static func detailText(
        peakNow: Bool,
        untilTransition: TimeInterval,
        weekend: Bool,
        holiday: Bool
    ) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let line = NSMutableAttributedString()
        func append(_ text: String, color: NSColor) {
            line.append(NSAttributedString(string: text, attributes: [
                .foregroundColor: color,
                .font: font,
            ]))
        }
        let soon = untilTransition < 900 // <15min heads-up before the next flip
        let nextAt = Date().addingTimeInterval(untilTransition)
        let nextClock = untilTransition >= 86_400
            ? Render.resetDayClockFormatter.string(from: nextAt)
            : Render.resetClockFormatter.string(from: nextAt)
        append(peakNow ? "peak" : "off-peak", color: peakNow ? Render.softRed : .systemGreen)
        append(" · ", color: .secondaryLabelColor)
        if holiday || weekend {
            append(holiday ? "holiday" : "weekend", color: .secondaryLabelColor)
            append(" · ", color: .secondaryLabelColor)
        }
        append("turns \(nextClock)\(Render.utc8Suffix(for: nextAt))", color: soon ? (peakNow ? .systemGreen : Render.softRed) : .secondaryLabelColor)
        return line
    }
}
