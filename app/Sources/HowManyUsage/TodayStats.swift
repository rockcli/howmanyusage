import Foundation

/// Aggregated "today's work" stats from local agent session logs.
/// Tokens: exact where the log carries them (DeepSeek API),
/// estimated elsewhere (chars/4 of user+assistant text) — `hasEstimate` flags that.
struct TodayStats: Codable, Sendable {
    var conversations = 0            // sessions with ≥1 message today
    var instructions = 0             // user prompts today
    var toolCalls = 0                // tool invocations today
    var activeSessions = 0           // sessions with messages in the last 30 min
    var tokens = 0
    var hasEstimate = false
    var weekInstructions: [Int] = [] // last 7 CST days, oldest → today
    var deepSeekCost: Double = 0     // today's DeepSeek cost, CNY
    var deepSeekCurrency: String = "CNY"
    /// Today's allocated cost in CNY: DeepSeek wallet spend + detected subscription
    /// monthly price × 7/30.44 × today's weekly-quota delta. No API-equivalent value.
    var totalCostCNY: Double? = nil
    /// Codex weekly-window consumption priced at official API rates (from local rollout
    /// logs, per-turn model-aware): exact cost so far, the log-reported window percent
    /// (used_percent of the latest in-window token_count event), and today's exact cost.
    /// Optional: absent in old persisted stats.
    var codexWindowCostUSD: Double? = nil
    var codexWindowTokens: Int? = nil
    var codexWindowStart: Date? = nil
    var codexWindowPct: Double? = nil
    var codexTodayCostUSD: Double? = nil
    /// An in-window turn used a model without a verified API price.
    /// Optional so older persisted snapshots remain decodable.
    var codexWindowUnpriced: Bool? = nil
    /// Claude weekly-window consumption priced at official API rates (from local
    /// session logs' exact per-message usage). The window percent is NOT in the logs —
    /// the caller pairs this cost with the API-reported weekly utilization.
    var claudeWindowCostUSD: Double? = nil
    var claudeWindowTokens: Int? = nil
    var claudeWindowStart: Date? = nil
    var claudeWindowUnpriced: Bool? = nil
    var claudeTodayTokens: Int? = nil
    var antigravityTodayTokens: Int? = nil
    var antigravityTodayInstructions: Int? = nil
    var antigravityTodayToolCalls: Int? = nil
    var antigravityWeekInstructions: [Int]? = nil
    var antigravityWindowCostUSD: Double? = nil
    var antigravityWindowTokens: Int? = nil
    var antigravityWindowStart: Date? = nil

    func codexCost(in boundary: Date?) -> Double {
        guard let boundary, let codexWindowStart, abs(codexWindowStart.timeIntervalSince(boundary)) < 1 else { return 0 }
        return codexWindowCostUSD ?? 0
    }

    func codexTokens(in boundary: Date?) -> Int {
        guard let boundary, let codexWindowStart, abs(codexWindowStart.timeIntervalSince(boundary)) < 1 else { return 0 }
        return codexWindowTokens ?? 0
    }
}

/// Scans pi / claude / codex / dsh session logs for today's activity.
/// Two tiers, both run off the main thread:
/// - `scanMtime`: cheap stat pass (conversations / active sessions), every refresh.
/// - `scanParse`: heavy JSONL parse (instructions / tool calls / tokens / week chart),
///   recomputed over the bounded day/week windows. Timestamp-only deltas lose
///   delayed/partially written JSONL records and retain counts from truncated logs.
///
/// "Today" is evaluated in **UTC+8** (China Standard Time) regardless of the
/// machine's local timezone: the day boundary is CST midnight, and only messages
/// timestamped at/after that boundary count (sessions spanning multiple days
/// contribute just their today part).
enum TodayStatsScanner {
    private static let cst: TimeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    private static let cstCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = cst
        return cal
    }()
    private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// Per-agent accumulator; sections are scanned in parallel and merged.
    struct Partial {
        var instructions = 0
        var toolCalls = 0
        var tokens = 0
        var hasEstimate = false
        var week = [Int](repeating: 0, count: 7)
        // Codex API-equivalent cost (USD), from rollout token_count × official prices.
        var codexWindowCost = 0.0   // additive: cost accumulated since the window start
        var codexWindowTokens = 0   // additive: tokens accumulated since the window start
        var codexTodayCost = 0.0    // additive: cost accumulated since CST midnight
        // Latest in-window used_percent seen (replacement semantics on merge, not additive).
        var codexWindowPct: (pct: Double, ts: Date)?
        var codexWindowUnpriced = false
        // Claude API-equivalent window cost (USD), additive since the window start.
        var claudeWindowCost = 0.0
        var claudeWindowTokens = 0
        var claudeWindowUnpriced = false
        var claudeTodayTokens: Int? = nil
        var antigravityTodayTokens: Int? = nil
        var antigravityTodayInstructions: Int? = nil
        var antigravityTodayToolCalls: Int? = nil
        var antigravityWeekInstructions: [Int]? = nil
        var antigravityWindowCost: Double? = nil
        var antigravityWindowTokens: Int? = nil
    }

    static func scan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date(),
        windowStarts: [String: Date]? = nil
    ) -> TodayStats {
        let todayStart = cstCalendar.startOfDay(for: now)
        guard let weekStart = cstCalendar.date(byAdding: .day, value: -6, to: todayStart),
              let tomorrowStart = cstCalendar.date(byAdding: .day, value: 1, to: todayStart)
        else { return TodayStats() }

        // Weekly-window starts (observed from snapshot history — see weeklyWindowStart).
        // Explicit inputs also permit offline fixture scans without reading user state.
        let codexWindowStart = windowStarts == nil ? Self.weeklyWindowStart(id: "codex") : windowStarts?["codex"]
        let claudeWindowStart = windowStarts == nil ? Self.weeklyWindowStart(id: "claude") : windowStarts?["claude"]
        let antigravityWindowStart = windowStarts == nil ? Self.weeklyWindowStart(id: "antigravity") : windowStarts?["antigravity"]
        // Rebuild contributions by replacement. A record can be completed after
        // the preceding scan even though its timestamp is before that scan's now.
        // The shared fresh/disk caches still provide immediate results to the UI.
        let cutoff = [weekStart, codexWindowStart, claudeWindowStart, antigravityWindowStart]
            .compactMap { $0 }.min() ?? weekStart
        var parsed = TodayStats()
        parsed.weekInstructions = Array(repeating: 0, count: 7)

        let lock = NSLock()
        let directory = home.appendingPathComponent(".config/howmanyusage", isDirectory: true)
        let indexURL = directory.appendingPathComponent("today-stats-index.json")
        let oldIndex = loadFileIndex(from: indexURL)
        var partials = [Partial?](repeating: nil, count: 3)
        var claudeCache: [String: ClaudeFileCache] = [:]
        var codexCache: [String: CodexFileCache] = [:]
        var antigravityCache: [String: AntigravityFileCache] = [:]
        var indexDirty = false

        DispatchQueue.concurrentPerform(iterations: 3) { i in
            switch i {
            case 0:
                let out = scanClaudeCached(
                    home: home, now: now, cutoff: cutoff, weekStart: weekStart,
                    todayStart: todayStart, tomorrowStart: tomorrowStart,
                    windowStart: claudeWindowStart, oldFiles: oldIndex.claude
                )
                lock.lock()
                partials[0] = out.partial
                claudeCache = out.files
                if out.dirty { indexDirty = true }
                lock.unlock()
            case 1:
                let out = scanCodexCached(
                    home: home, now: now, cutoff: cutoff, weekStart: weekStart,
                    todayStart: todayStart, tomorrowStart: tomorrowStart,
                    windowStart: codexWindowStart, oldFiles: oldIndex.codex
                )
                lock.lock()
                partials[1] = out.partial
                codexCache = out.files
                if out.dirty { indexDirty = true }
                lock.unlock()
            default:
                let out = scanAntigravityCached(
                    home: home, now: now, cutoff: cutoff, weekStart: weekStart,
                    todayStart: todayStart, tomorrowStart: tomorrowStart,
                    windowStart: antigravityWindowStart, oldFiles: oldIndex.antigravity
                )
                lock.lock()
                partials[2] = out.partial
                antigravityCache = out.files
                if out.dirty { indexDirty = true }
                lock.unlock()
            }
        }
        if indexDirty {
            let nextIndex = TodayStatsFileIndex(
                claude: claudeCache,
                codex: codexCache,
                antigravity: antigravityCache
            )
            saveFileIndex(nextIndex, to: indexURL, directory: directory)
        }
        for p in partials.compactMap({ $0 }) {
            parsed.instructions = UsageNumbers.sum(parsed.instructions, p.instructions)
            parsed.toolCalls = UsageNumbers.sum(parsed.toolCalls, p.toolCalls)
            parsed.tokens = UsageNumbers.sum(parsed.tokens, p.tokens)
            parsed.hasEstimate = parsed.hasEstimate || p.hasEstimate
            for i in 0..<7 { parsed.weekInstructions[i] = UsageNumbers.sum(parsed.weekInstructions[i], p.week[i]) }
            if p.codexWindowCost > 0 {
                parsed.codexWindowCostUSD = (parsed.codexWindowCostUSD ?? 0) + p.codexWindowCost
            }
            if p.codexWindowTokens > 0 {
                parsed.codexWindowTokens = UsageNumbers.sum(parsed.codexWindowTokens ?? 0, p.codexWindowTokens)
            }
            if p.codexWindowUnpriced { parsed.codexWindowUnpriced = true }
            if p.codexTodayCost > 0 {
                parsed.codexTodayCostUSD = (parsed.codexTodayCostUSD ?? 0) + p.codexTodayCost
            }
            // Replacement, not additive: the newest in-window used_percent wins.
            if let pct = p.codexWindowPct, pct.ts >= cutoff {
                parsed.codexWindowPct = pct.pct
            }
            if let tokens = p.claudeTodayTokens {
                parsed.tokens = UsageNumbers.sum(parsed.tokens, tokens)
                parsed.claudeTodayTokens = tokens
                parsed.claudeWindowCostUSD = p.claudeWindowCost
                parsed.claudeWindowTokens = p.claudeWindowTokens
                parsed.claudeWindowUnpriced = p.claudeWindowUnpriced
            }
            if let tokens = p.antigravityTodayTokens,
               let inst = p.antigravityTodayInstructions,
               let tools = p.antigravityTodayToolCalls,
               let week = p.antigravityWeekInstructions {
                parsed.tokens = UsageNumbers.sum(parsed.tokens, tokens)
                parsed.antigravityTodayTokens = tokens
                parsed.instructions = UsageNumbers.sum(parsed.instructions, inst)
                parsed.antigravityTodayInstructions = inst
                parsed.toolCalls = UsageNumbers.sum(parsed.toolCalls, tools)
                parsed.antigravityTodayToolCalls = tools
                for i in 0..<min(7, week.count) {
                    parsed.weekInstructions[i] = UsageNumbers.sum(parsed.weekInstructions[i], week[i])
                }
                parsed.antigravityWeekInstructions = week
                if let winCost = p.antigravityWindowCost {
                    parsed.antigravityWindowCostUSD = winCost
                }
                if let winTokens = p.antigravityWindowTokens {
                    parsed.antigravityWindowTokens = winTokens
                }
            }
        }

        parsed.claudeWindowStart = claudeWindowStart
        parsed.codexWindowStart = codexWindowStart
        parsed.antigravityWindowStart = antigravityWindowStart

        scanGate.lock()
        lastStats = (parsed, now)
        scanGate.unlock()
        return parsed
    }

    // MARK: - Shared scan cache

    /// Most recent completed scan (thread-safe); nil before the first scan.
    private static var lastStats: (stats: TodayStats, at: Date)?
    /// Whether a background scan is already in flight (dedupe concurrent requests).
    private static var scanning = false
    private static var scanCompletions: [(TodayStats) -> Void] = []
    private static let scanGate = NSLock()

    /// Latest cached stats (memory or disk) without kicking off a scan.
    static func cachedStats() -> TodayStats? {
        scanGate.lock()
        let mem = lastStats?.stats
        scanGate.unlock()
        return mem ?? StateStore.loadTodayStats()
    }

    /// The latest scan result if it is fresh (≤ 60 s), else nil.
    static func latestStats() -> TodayStats? {
        scanGate.lock(); defer { scanGate.unlock() }
        guard let last = lastStats, Date().timeIntervalSince(last.at) < 60 else { return nil }
        return last.stats
    }

    /// Returns the best stats available right now (fresh cache → last scan → disk),
    /// and kicks off a background scan when nothing is fresh. When a fresh scan finishes,
    /// `completion` runs on the main queue (used by the popover to repaint).
    static func ensureFreshStats(maxAge: TimeInterval = 60, completion: ((TodayStats) -> Void)? = nil) -> TodayStats? {
        scanGate.lock()
        if let last = lastStats, Date().timeIntervalSince(last.at) < maxAge {
            let stats = last.stats
            scanGate.unlock()
            return stats
        }
        let stale = lastStats?.stats
        if scanning {
            if let completion { scanCompletions.append(completion) }
            scanGate.unlock()
            return stale ?? StateStore.loadTodayStats()
        }
        scanning = true
        if let completion { scanCompletions.append(completion) }
        scanGate.unlock()
        Task.detached(priority: .utility) {
            let stats = scan()
            StateStore.saveTodayStats(stats)
            let completions = finishScan(stats)
            if !completions.isEmpty {
                DispatchQueue.main.async {
                    for completion in completions { completion(stats) }
                }
            }
        }
        return stale ?? StateStore.loadTodayStats()
    }

    /// Synchronous lock guard: mark the background scan as done (NSLock must not be
    /// touched directly from the async Task context).
    private static func finishScan(_ stats: TodayStats) -> [(TodayStats) -> Void] {
        scanGate.lock()
        scanning = false
        lastStats = (stats, Date())
        let completions = scanCompletions
        scanCompletions = []
        scanGate.unlock()
        return completions
    }

    private static func weeklyWindowStart(id: String) -> Date? {
        WeeklyWindow.start(id: id)
    }

    /// Today's consumption of each plan's weekly window, in percent points — from the
    /// app's own snapshot history (first snapshot of the CST day = morning baseline):
    /// delta = current % − morning %. If the window reset during the day, the baseline
    /// is 0 (fresh window counts from zero). This is what "today" actually consumed,
    /// unlike the raw weekly % which accumulates over the whole week.
    static func todayWeeklyDeltas() -> [String: Double] {
        let hist = StateStore.history()
        guard !hist.isEmpty else { return [:] }
        var cst = Calendar(identifier: .gregorian)
        cst.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let todayStart = cst.startOfDay(for: Date())

        func value(_ s: UsageSnapshot, _ id: String) -> Double? {
            switch id {
            case "codex": return s.codexWeekly
            case "claude": return s.claudeWeekly
            case "antigravity": return s.antigravityWeekly
            default: return nil
            }
        }
        func reset(_ s: UsageSnapshot, _ id: String) -> String? {
            switch id {
            case "codex": return s.codexWeeklyReset
            case "claude": return s.claudeWeeklyReset
            case "antigravity": return s.antigravityWeeklyReset
            default: return nil
            }
        }
        func sameWindow(_ a: String, _ b: String) -> Bool {
            guard let x = Double(a), let y = Double(b) else { return false }
            return abs(x - y) < 300 // tolerate the ~1s floating noise
        }

        var result: [String: Double] = [:]
        for id in ["codex", "claude", "antigravity"] {
            // Current value: the LAST snapshot that has one (throttled refreshes
            // used to write nil rows — never trust the bare tail).
            guard let current = hist.reversed().first(where: { value($0, id) != nil }) else { continue }
            guard let curPct = value(current, id) else { continue }
            let curReset = reset(current, id)

            var baseline: Double?
            var baselineReset: String?
            // Morning baseline: first snapshot of the CST day with a value.
            for s in hist where s.ts >= todayStart {
                guard let v = value(s, id) else { continue }
                baseline = v
                baselineReset = reset(s, id)
                break
            }
            // App was off at midnight: fall back to the last snapshot before today.
            if baseline == nil {
                for s in hist.reversed() where s.ts < todayStart {
                    guard let v = value(s, id) else { continue }
                    baseline = v
                    baselineReset = reset(s, id)
                    break
                }
            }
            if let baseline, let baselineReset, let curReset, sameWindow(baselineReset, curReset) {
                result[id] = max(0, curPct - baseline) // same window: today's delta
            } else {
                result[id] = max(0, curPct) // window reset today: fresh window from 0
            }
        }
        return result
    }

    /// Only show the "可能用不完" hint when projected usage at reset is below this percent.
    static let wasteThreshold = 90.0

    /// Only show the early-exhaustion warning when the quota is forecast to run
    /// out by 90% of the remaining window, leaving a 10% time buffer before reset.
    static let exhaustionTimeThreshold = 0.90

    /// Per-window quota pace from the snapshot history: the daily burn rate
    /// (%-points/day) within the CURRENT window, how long until the quota
    /// would hit 100% at that rate, and the projected usage % at the reset time.
    /// nil when there isn't enough in-window data (app just started / window just reset).
    /// Guards: same-window filtering (reset noise ≤ 5 min), ≥ 12 h of data,
    /// rate capped at ±80%/day so a burst doesn't produce absurd forecasts.
    static func quotaPace(id: String, history: [UsageSnapshot]? = nil, now: Date = Date(), resetAt: Date? = nil) -> (dailyRate: Double, exhaustsIn: TimeInterval?, projectedAtReset: Double?)? {
        let hist = (history ?? StateStore.history()).filter { $0.ts <= now }.sorted { $0.ts < $1.ts }
        guard !hist.isEmpty else { return nil }

        func value(_ s: UsageSnapshot) -> Double? {
            switch id {
            case "codex": return s.codexWeekly
            case "claude": return s.claudeWeekly
            case "antigravity": return s.antigravityWeekly
            default: return nil
            }
        }
        func reset(_ s: UsageSnapshot) -> String? {
            switch id {
            case "codex": return s.codexWeeklyReset
            case "claude": return s.claudeWeeklyReset
            case "antigravity": return s.antigravityWeeklyReset
            default: return nil
            }
        }
        func sameWindow(_ a: String, _ b: String) -> Bool {
            guard let x = Double(a), let y = Double(b) else { return false }
            return abs(x - y) < 300 // tolerate the ~1s floating noise
        }

        // Current value + the window it belongs to (never trust the nil tail).
        guard let cur = hist.reversed().first(where: { value($0) != nil }),
              let curPct = UsageNumbers.percent(value(cur)), let curReset = reset(cur),
              let resetEpoch = Double(curReset), resetEpoch.isFinite,
              let resetDate = UsageNumbers.date(epoch: resetEpoch),
              resetDate > now, resetDate.timeIntervalSince(now) <= 7 * 86400,
              let boundary = WeeklyWindow.start(id: id, resetAt: resetAt, history: hist) else { return nil }
        if let resetAt, abs(resetAt.timeIntervalSince(resetDate)) >= 300 { return nil }
        // Earliest sample inside the current window = pace baseline.
        guard let baseline = hist.first(where: { $0.ts >= boundary && UsageNumbers.percent(value($0)) != nil && reset($0).map { sameWindow($0, curReset) } == true }),
              let basePct = value(baseline)
        else { return nil }

        let elapsed = cur.ts.timeIntervalSince(baseline.ts)
        guard elapsed.isFinite, elapsed >= 12 * 3600 else { return nil } // need ≥ half a day of window data
        let dailyRate = min(80, max(-80, (curPct - basePct) / elapsed * 86_400))

        // Project how far the current window will get by its reset, using the same
        // capped rate. This powers the remaining-quota hint.
        let projectedAtReset: Double? = {
            // 工作日数据不能直接外推周末：剩余时间折算成工作日等效天数（周六 ×30%）。
            return min(100, max(0, curPct + dailyRate * weekendAwareDays(from: now, to: resetDate)))
        }()

        let remaining = 100 - curPct
        guard dailyRate > 0.05, remaining >= 1 else { return (dailyRate, nil, projectedAtReset) }

        // 耗尽时间同样走周六折算：剩余 %-points 需要 remaining/dailyRate 个工作日等效天数，
        // 再反推回真实时长（周六只按 30% 推进，所以跨过周六时真实时间更长）。
        let exhaustsIn = weekendAwareInterval(workdays: remaining / dailyRate, from: now)
        return (dailyRate, exhaustsIn, projectedAtReset)
    }

    /// weekendAwareDays 的逆运算：从 `from` 起，累计够 `workdays` 个工作日等效天数
    /// 所需的真实时长（周六按 30% 推进，逐日走到目标后按当天权重线性插值）。
    private static func weekendAwareInterval(workdays: Double, from start: Date) -> TimeInterval {
        guard workdays.isFinite, workdays > 0 else { return 0 }
        var cst = Calendar(identifier: .gregorian)
        cst.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        var remaining = workdays
        var cursor = start
        while remaining > 0 {
            let dayStart = cst.startOfDay(for: cursor)
            guard let nextDay = cst.date(byAdding: .day, value: 1, to: dayStart), nextDay > cursor else { break }
            let segment = nextDay.timeIntervalSince(cursor)
            let weight: Double = cst.component(.weekday, from: cursor) == 7 ? 0.3 : 1.0
            let capacity = segment / 86_400 * weight // 今天剩余时段能容纳的等效天数
            if remaining <= capacity {
                return cursor.timeIntervalSince(start) + remaining / weight * 86_400
            }
            remaining -= capacity
            cursor = nextDay
        }
        return cursor.timeIntervalSince(start)
    }

    /// 把一段真实时间折算成“工作日等效天数”（CST 日界）：周六按 30% 速率计，
    /// 其余天按 100%。工作日数据不能直接外推周末（用户周末工作量约为工作日三成），
    /// 投影（projectedAtReset）用折算后的天数，避免高估消耗。
    private static func weekendAwareDays(from start: Date, to end: Date) -> Double {
        guard end > start else { return 0 }
        var cst = Calendar(identifier: .gregorian)
        cst.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        var total = 0.0
        var cursor = start
        while cursor < end {
            let dayStart = cst.startOfDay(for: cursor)
            guard let nextDay = cst.date(byAdding: .day, value: 1, to: dayStart), nextDay > cursor else { break }
            let segment = min(nextDay, end).timeIntervalSince(cursor)
            let isSaturday = cst.component(.weekday, from: cursor) == 7 // 1=Sunday … 7=Saturday
            total += segment / 86_400 * (isSaturday ? 0.3 : 1.0)
            cursor = nextDay
        }
        return total
    }

    /// Whether the remaining time (until `resetAt`) contains a Saturday (CST).
    /// The green remaining-quota hint appends "(Sat)" when the weekend factor is at play.
    static func hasSaturday(until resetAt: Date?, now: Date = Date()) -> Bool {
        guard let resetAt, resetAt.timeIntervalSince1970.isFinite, resetAt > now else { return false }
        if resetAt.timeIntervalSince(now) >= 7 * 86400 { return true }
        var cst = Calendar(identifier: .gregorian)
        cst.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        var cursor = now
        while cursor < resetAt {
            if cst.component(.weekday, from: cursor) == 7 { return true }
            guard let next = cst.date(byAdding: .day, value: 1, to: cst.startOfDay(for: cursor)) else { break }
            cursor = next
        }
        return false
    }

    /// Whether an early exhaustion forecast is worth a red ⚠ warning. A small
    /// buffer avoids warning on a forecast that reaches 100% only at the reset.
    static func exhaustionWorthy(id: String, exhaustsIn: TimeInterval, reset: TimeInterval) -> Bool {
        guard reset.isFinite, exhaustsIn.isFinite, reset > 0, exhaustsIn >= 0 else { return false }
        return exhaustsIn < reset * exhaustionTimeThreshold
    }

    /// 7-day balance trend for a provider: the last snapshot value per CST day,
    /// oldest → today. nil when balance barely moved (spread < ¥0.10) or fewer
    /// than 2 days of data.
    static func balanceTrend(id: String) -> [Double]? {
        let hist = StateStore.history()
        guard !hist.isEmpty else { return nil }
        func balance(_ s: UsageSnapshot) -> Double? {
            switch id {
            case "deepseek": return s.dsBalance
            case "colab": return s.colabBalance
            default: return nil
            }
        }
        var byDay: [String: Double] = [:]
        var order: [String] = []
        if id == "colab" {
            for sample in PiUsage.allColabSamples() {
                let key = cstDayKey(sample.ts)
                if byDay[key] == nil { order.append(key) }
                byDay[key] = sample.balance
            }
        } else {
            for s in hist {
                guard let b = balance(s) else { continue }
                let key = cstDayKey(s.ts)
                if byDay[key] == nil { order.append(key) }
                byDay[key] = b // last snapshot of the day wins
            }
        }
        let days = order.suffix(7)
        let vals = days.compactMap { byDay[$0] }
        guard vals.count >= 2, let mn = vals.min(), let mx = vals.max(), mx - mn >= 0.10 else { return nil }
        return vals
    }

    /// DeepSeek cash spend per CST day for the last 7 days, oldest -> today.
    /// Sum observed drops within each day. Recharge jumps do not erase spend
    /// observed earlier that day. Missing days become 0.
    /// nil when no DeepSeek balance snapshots exist yet.
    static func deepSeekWeekSpend() -> [Double]? {
        let hist = StateStore.history().sorted { $0.ts < $1.ts }
        let samples = hist.compactMap { row -> (ts: Date, balance: Double)? in
            row.dsBalance.map { (row.ts, $0) }
        }
        guard !samples.isEmpty else { return nil }
        let todayStart = cstCalendar.startOfDay(for: Date())
        guard let weekStart = cstCalendar.date(byAdding: .day, value: -6, to: todayStart) else { return nil }
        return (0..<7).compactMap { offset in
            guard let start = cstCalendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
            return PiUsage.walletSpend(samples: samples, start: start,
                end: start.addingTimeInterval(86400 - 0.001))?.cost ?? 0
        }
    }

    static func colabWeekSpend() -> [Double]? {
        let samples = PiUsage.allColabSamples()
        guard !samples.isEmpty else { return nil }
        let todayStart = cstCalendar.startOfDay(for: Date())
        guard let weekStart = cstCalendar.date(byAdding: .day, value: -6, to: todayStart) else { return nil }
        return (0..<7).compactMap { offset in
            guard let start = cstCalendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
            return PiUsage.walletSpend(samples: samples, start: start,
                end: start.addingTimeInterval(86400 - 0.001))?.cost ?? 0
        }
    }

    // MARK: - Short-window burn spike detection

    /// Short-window burn spike thresholds:
    /// - Weekly quota jumping ≥ 8%-points within 45 min (>12× normal daily pace)
    /// - 5-hour quota jumping ≥ 25%-points within 45 min
    /// - DeepSeek balance dropping ≥ ¥10 within 45 min
    /// - Colab balance dropping ≥ 10 CU within 45 min
    static let spikeLookbackSeconds: TimeInterval = 45 * 60
    static let weeklySpikeThreshold = 8.0
    static let fiveHourSpikeThreshold = 25.0
    static let deepSeekSpikeThreshold = 10.0
    static let colabSpikeThreshold = 10.0

    /// Returns the short-window percentage-point jump when `id`'s `kind` ("weekly" or "fiveHour")
    /// quota spiked within `spikeLookbackSeconds` inside the same reset window; nil otherwise.
    static func quotaSpike(
        id: String, kind: String, history: [UsageSnapshot]? = nil, now: Date = Date()
    ) -> Double? {
        let hist = (history ?? StateStore.history()).sorted { $0.ts < $1.ts }
        guard hist.count >= 2 else { return nil }
        func value(_ s: UsageSnapshot) -> Double? {
            switch (id, kind) {
            case ("codex", "weekly"): return s.codexWeekly
            case ("codex", "fiveHour"): return s.codex5h
            case ("claude", "weekly"): return s.claudeWeekly
            case ("claude", "fiveHour"): return s.claude5h
            case ("antigravity", "weekly"): return s.antigravityWeekly
            case ("antigravity", "fiveHour"): return s.antigravity5h
            default: return nil
            }
        }
        func reset(_ s: UsageSnapshot) -> String? {
            switch (id, kind) {
            case ("codex", "weekly"): return s.codexWeeklyReset
            case ("codex", "fiveHour"): return s.codex5hReset
            case ("claude", "weekly"): return s.claudeWeeklyReset
            case ("claude", "fiveHour"): return s.claude5hReset
            case ("antigravity", "weekly"): return s.antigravityWeeklyReset
            case ("antigravity", "fiveHour"): return s.antigravity5hReset
            default: return nil
            }
        }
        func sameWindow(_ a: String?, _ b: String?) -> Bool {
            guard let a, let b, let x = Double(a), let y = Double(b) else { return true }
            return abs(x - y) < 300
        }
        guard let cur = hist.reversed().first(where: { value($0) != nil }),
              let curPct = UsageNumbers.percent(value(cur)),
              (0...spikeLookbackSeconds).contains(now.timeIntervalSince(cur.ts)) else { return nil }
        let curReset = reset(cur)
        let cutoff = cur.ts.addingTimeInterval(-spikeLookbackSeconds)
        var maxDelta = 0.0
        for s in hist where s.ts >= cutoff && s.ts < cur.ts {
            guard let basePct = UsageNumbers.percent(value(s)),
                  sameWindow(reset(s), curReset),
                  !QuotaValueEstimate.isResetDrop(from: basePct, to: curPct) else { continue }
            maxDelta = max(maxDelta, curPct - basePct)
        }
        let threshold = kind == "weekly" ? weeklySpikeThreshold : fiveHourSpikeThreshold
        return maxDelta >= threshold ? maxDelta : nil
    }

    /// Returns the short-window DeepSeek wallet spend (CNY) when observed balance drops
    /// within `spikeLookbackSeconds` reach `deepSeekSpikeThreshold`; nil otherwise.
    static func deepSeekBalanceSpike(
        history: [UsageSnapshot]? = nil, now: Date = Date()
    ) -> Double? {
        let hist = (history ?? StateStore.history()).sorted { $0.ts < $1.ts }
        let cutoff = now.addingTimeInterval(-spikeLookbackSeconds)
        let balances = hist.filter { $0.ts >= cutoff && $0.ts <= now }.compactMap(\.dsBalance)
        guard let spend = PiUsage.balanceSpend(balances)?.cost,
              spend >= deepSeekSpikeThreshold else { return nil }
        return spend
    }

    static func colabBalanceSpike(
        history: [UsageSnapshot]? = nil, now: Date = Date()
    ) -> Double? {
        let hist = (history ?? StateStore.history()).sorted { $0.ts < $1.ts }
        let cutoff = now.addingTimeInterval(-spikeLookbackSeconds)
        let balances = hist.filter { $0.ts >= cutoff && $0.ts <= now }.compactMap(\.colabBalance)
        guard let spend = PiUsage.balanceSpend(balances)?.cost,
              spend >= colabSpikeThreshold else { return nil }
        return spend
    }

    // MARK: - Shared helpers

    private static func cstDayKey(_ date: Date) -> String {
        let c = cstCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func entryDate(_ d: [String: Any]) -> Date? {
        if let t = (d["timestamp"] as? String) ?? (d["created_at"] as? String) {
            return isoFraction.date(from: t) ?? isoPlain.date(from: t)
        }
        if let ms = (d["time"] as? NSNumber)?.doubleValue ?? (d["created_at"] as? NSNumber)?.doubleValue {
            return UsageNumbers.date(epoch: ms / 1000)
        }
        return nil
    }

    /// Claude wraps tool results in "user" entries — those are not instructions.
    private static func isToolResultOnly(_ content: Any?) -> Bool {
        guard let arr = content as? [[String: Any]], !arr.isEmpty else { return false }
        return arr.allSatisfy { ($0["type"] as? String) == "tool_result" }
    }

    /// Bucket index (0 = oldest of the 7 days, 6 = today), nil outside the window.
    private static func dayIndex(_ ts: Date, weekStart: Date, tomorrowStart: Date) -> Int? {
        guard ts >= weekStart, ts < tomorrowStart else { return nil }
        guard let index = cstCalendar.dateComponents([.day], from: weekStart, to: ts).day,
              (0..<7).contains(index) else { return nil }
        return index
    }

    private static func fileMetadata(_ url: URL) -> (modified: Date, size: Int)? {
        guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
              v.isRegularFile == true,
              let m = v.contentModificationDate,
              let s = v.fileSize else { return nil }
        return (m, s)
    }

    private static func canReuseFileCache(
        modified: Date, size: Int, readStart: Date, now: Date,
        cachedModified: Date, cachedSize: Int, coveredFrom: Date, upperBound: Date, hadFutureEntries: Bool
    ) -> Bool {
        cachedModified == modified
            && cachedSize == size
            && coveredFrom <= readStart
            && (upperBound == now || (!hadFutureEntries && upperBound <= now))
    }

    /// Parse a JSONL file; entries before `cutoff` are skipped except requested
    /// context types, and entries at/after `upperBound` are always skipped.
    /// Returns whether any timestamped record fell at/after `upperBound` (cache guard).
    @discardableResult
    private static func parseFile(
        _ url: URL, cutoff: Date, upperBound: Date,
        skip: ((String) -> Bool)? = nil,
        includeEarlierTypes: Set<String> = [],
        handle: (Date, [String: Any]) -> Void
    ) -> Bool {
        var hadFutureEntries = false
        LocalJSONL.read(url, matching: { line in
            (line.contains("\"timestamp\"") || line.contains("\"time\"") || line.contains("\"created_at\""))
                && skip?(line) != true
        }) { _, obj in
            guard let ts = entryDate(obj) else { return }
            if ts >= upperBound {
                hadFutureEntries = true
                return
            }
            if ts < cutoff && !includeEarlierTypes.contains(obj["type"] as? String ?? "") { return }
            handle(ts, obj)
        }
        return hadFutureEntries
    }

    // MARK: - Per-file index cache

    private struct CachedClaudeRequest: Codable {
        let ids: [String]
        let timestamp: Date
        let start: Date?
        let model: String?
        let input: Int
        let cache5m: Int
        let cache1h: Int
        let cacheRead: Int
        let output: Int
    }

    private struct ClaudeFileCache: Codable {
        let modified: Date
        let size: Int
        let coveredFrom: Date
        let upperBound: Date
        let hadFutureEntries: Bool
        let requests: [CachedClaudeRequest]
        let unidentifiedStarts: [Date]
        let promptTimestamps: [Date]
        let toolCallTimestamps: [Date]
    }

    private struct CachedCodexUsage: Codable {
        let responseID: String?
        let ts: Date
        let turnStarted: Date?
        let cost: Double?
        let tokens: Int
    }

    private struct CachedCodexPct: Codable {
        let ts: Date
        let pct: Double
    }

    private struct CodexFileCache: Codable {
        let modified: Date
        let size: Int
        let coveredFrom: Date
        let upperBound: Date
        let hadFutureEntries: Bool
        let usages: [CachedCodexUsage]
        let pcts: [CachedCodexPct]
        let promptTimestamps: [Date]
        let toolCallTimestamps: [Date]
    }

    private struct CachedAntigravityStep: Codable {
        let ts: Date
        let tokens: Int
        let tools: Int
        let geminiCost: Double?
    }

    private struct AntigravityFileCache: Codable {
        let modified: Date
        let size: Int
        let coveredFrom: Date
        let upperBound: Date
        let hadFutureEntries: Bool
        let steps: [CachedAntigravityStep]
        let promptTimestamps: [Date]
    }

    private struct TodayStatsFileIndex: Codable {
        var version = 3
        var claude: [String: ClaudeFileCache] = [:]
        var codex: [String: CodexFileCache] = [:]
        var antigravity: [String: AntigravityFileCache] = [:]
    }

    private static func loadFileIndex(from url: URL) -> TodayStatsFileIndex {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(TodayStatsFileIndex.self, from: data),
              decoded.version == 3 else {
            return TodayStatsFileIndex()
        }
        return decoded
    }

    private static func saveFileIndex(_ index: TodayStatsFileIndex, to url: URL, directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    // MARK: - Agent sections

    /// claude: ~/.claude/projects/<project>/<sessionId>.jsonl
    /// Instructions: type "user" (excluding tool_result-only entries);
    /// tool calls: content blocks type "tool_use".
    /// Also prices every assistant message's exact usage at official API rates
    /// (per-message model) since `windowStart`, for the plan value estimate; the
    /// matching window percent comes from the API (logs carry no utilization).
    static func scanClaude(home: URL, now: Date, cutoff: Date, weekStart: Date, todayStart: Date, tomorrowStart: Date, windowStart: Date?) -> Partial {
        scanClaudeCached(
            home: home, now: now, cutoff: cutoff, weekStart: weekStart,
            todayStart: todayStart, tomorrowStart: tomorrowStart, windowStart: windowStart, oldFiles: [:]
        ).partial
    }

    private static func scanClaudeCached(
        home: URL, now: Date, cutoff: Date, weekStart: Date, todayStart: Date, tomorrowStart: Date,
        windowStart: Date?, oldFiles: [String: ClaudeFileCache]
    ) -> (partial: Partial, files: [String: ClaudeFileCache], dirty: Bool) {
        var result = Partial()
        result.claudeTodayTokens = 0
        struct Request {
            var ids: Set<String>
            let timestamp: Date
            var start: Date?
            let model: String?
            let input: Int
            let cache5m: Int
            let cache1h: Int
            let cacheRead: Int
            let output: Int
            var tokens: Int { UsageNumbers.sum(input, cache5m, cache1h, cacheRead, output) }
        }
        var requests: [String: Request] = [:]
        var aliases: [String: String] = [:]
        func mergeRequest(_ req: Request, into requests: inout [String: Request], aliases: inout [String: String]) {
            let sortedIDs = req.ids.sorted()
            guard let firstID = sortedIDs.first else { return }
            let existing = Set(sortedIDs.compactMap { aliases[$0] })
            let canonical = existing.sorted().first ?? firstID
            let candidates = existing.compactMap { requests[$0] } + [req]
            var best = candidates.max { $0.tokens < $1.tokens }!
            best.start = candidates.compactMap(\.start).min()
            best.ids = candidates.reduce(into: Set<String>()) { $0.formUnion($1.ids) }
            for key in existing { requests.removeValue(forKey: key) }
            if existing.count > 1 {
                for (alias, key) in aliases where existing.contains(key) { aliases[alias] = canonical }
            }
            for id in best.ids { aliases[id] = canonical }
            requests[canonical] = best
        }

        let readStart = min(windowStart ?? todayStart, todayStart, cutoff)
        let root = home.appendingPathComponent(".claude/projects")
        var nextFiles: [String: ClaudeFileCache] = [:]
        var dirty = false
        guard let files = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else {
            return (result, [:], !oldFiles.isEmpty)
        }
        for case let file as URL in files where file.pathExtension == "jsonl" {
            guard let meta = fileMetadata(file), meta.modified >= readStart else { continue }
            let key = file.path
            let entry: ClaudeFileCache
            if let old = oldFiles[key],
               canReuseFileCache(
                   modified: meta.modified, size: meta.size, readStart: readStart, now: now,
                   cachedModified: old.modified, cachedSize: old.size,
                   coveredFrom: old.coveredFrom, upperBound: old.upperBound, hadFutureEntries: old.hadFutureEntries
               ) {
                entry = old
            } else {
                dirty = true
                let child = file.pathComponents.contains("subagents")
                var requestStart: Date?
                var fileRequests: [String: Request] = [:]
                var fileAliases: [String: String] = [:]
                var unidentifiedStarts: [Date] = []
                var promptTimestamps: [Date] = []
                var toolCallTimestamps: [Date] = []
                let hadFuture = parseFile(file, cutoff: readStart, upperBound: now, includeEarlierTypes: ["user"]) { ts, row in
                    guard let message = row["message"] as? [String: Any] else { return }
                    if row["type"] as? String == "user" { requestStart = ts }
                    if row["type"] as? String == "assistant", let usage = message["usage"] as? [String: Any] {
                        let cache = usage["cache_creation"] as? [String: Any]
                        let oneHour = UsageNumbers.count(cache?["ephemeral_1h_input_tokens"])
                        let cacheTotal = UsageNumbers.count(usage["cache_creation_input_tokens"])
                        let ids = Set([(row["requestId"] as? String).flatMap { $0.isEmpty ? nil : "request:" + $0 },
                                       (message["id"] as? String).flatMap { $0.isEmpty ? nil : "message:" + $0 }].compactMap { $0 })
                        let request = Request(ids: ids, timestamp: ts, start: requestStart, model: message["model"] as? String,
                            input: UsageNumbers.count(usage["input_tokens"]),
                            cache5m: UsageNumbers.integer(cache?["ephemeral_5m_input_tokens"]).map { max(0, $0) } ?? max(0, cacheTotal - oneHour),
                            cache1h: oneHour, cacheRead: UsageNumbers.count(usage["cache_read_input_tokens"]),
                            output: UsageNumbers.count(usage["output_tokens"]))
                        if request.tokens > 0 {
                            if !ids.isEmpty {
                                mergeRequest(request, into: &fileRequests, aliases: &fileAliases)
                            } else if let requestStart {
                                unidentifiedStarts.append(requestStart)
                            }
                        }
                    }
                    guard ts >= readStart else { return }
                    let user = !child && row["type"] as? String == "user" && !isToolResultOnly(message["content"])
                    if user { promptTimestamps.append(ts) }
                    if let blocks = message["content"] as? [[String: Any]] {
                        let count = blocks.filter { $0["type"] as? String == "tool_use" }.count
                        if count > 0 {
                            for _ in 0..<count { toolCallTimestamps.append(ts) }
                        }
                    }
                }
                entry = ClaudeFileCache(
                    modified: meta.modified, size: meta.size, coveredFrom: readStart, upperBound: now,
                    hadFutureEntries: hadFuture,
                    requests: fileRequests.values.map {
                        CachedClaudeRequest(
                            ids: Array($0.ids), timestamp: $0.timestamp, start: $0.start, model: $0.model,
                            input: $0.input, cache5m: $0.cache5m, cache1h: $0.cache1h,
                            cacheRead: $0.cacheRead, output: $0.output
                        )
                    },
                    unidentifiedStarts: unidentifiedStarts,
                    promptTimestamps: promptTimestamps,
                    toolCallTimestamps: toolCallTimestamps
                )
            }
            nextFiles[key] = entry
            for r in entry.requests where r.timestamp >= readStart && r.timestamp < now {
                let req = Request(
                    ids: Set(r.ids), timestamp: r.timestamp, start: r.start, model: r.model,
                    input: r.input, cache5m: r.cache5m, cache1h: r.cache1h,
                    cacheRead: r.cacheRead, output: r.output
                )
                mergeRequest(req, into: &requests, aliases: &aliases)
            }
            for start in entry.unidentifiedStarts where WeeklyWindow.includesRequest(startedAt: start, boundary: windowStart) {
                result.claudeWindowUnpriced = true
            }
            for ts in entry.promptTimestamps where ts >= cutoff && ts < now {
                if let index = dayIndex(ts, weekStart: weekStart, tomorrowStart: tomorrowStart) { result.week[index] += 1 }
                if ts >= todayStart { result.instructions += 1 }
            }
            for ts in entry.toolCallTimestamps where ts >= cutoff && ts >= todayStart && ts < now {
                result.toolCalls += 1
            }
        }
        if nextFiles.count != oldFiles.count || Set(nextFiles.keys) != Set(oldFiles.keys) { dirty = true }
        for request in requests.values {
            if request.timestamp >= todayStart { result.claudeTodayTokens = UsageNumbers.sum(result.claudeTodayTokens ?? 0, request.tokens) }
            guard WeeklyWindow.includesRequest(startedAt: request.start, boundary: windowStart) else { continue }
            result.claudeWindowTokens = UsageNumbers.sum(result.claudeWindowTokens, request.tokens)
            if let cost = ClaudeValue.cost(model: request.model, input: request.input, cacheCreate5m: request.cache5m,
                cacheCreate1h: request.cache1h, cacheRead: request.cacheRead, output: request.output) {
                result.claudeWindowCost += cost
            } else { result.claudeWindowUnpriced = true }
        }
        return (result, nextFiles, dirty)
    }

    /// Codex keeps resumed chats in their original date directories. Discover by
    /// modification time, then price canonical response IDs once; legacy quota
    /// notifications may repeat last_token_usage without consuming any new tokens.
    static func scanCodex(home: URL, now: Date, cutoff: Date, weekStart: Date, todayStart: Date, tomorrowStart: Date, windowStart: Date?) -> Partial {
        scanCodexCached(
            home: home, now: now, cutoff: cutoff, weekStart: weekStart,
            todayStart: todayStart, tomorrowStart: tomorrowStart, windowStart: windowStart, oldFiles: [:]
        ).partial
    }

    private static func scanCodexCached(
        home: URL, now: Date, cutoff: Date, weekStart: Date, todayStart: Date, tomorrowStart: Date,
        windowStart: Date?, oldFiles: [String: CodexFileCache]
    ) -> (partial: Partial, files: [String: CodexFileCache], dirty: Bool) {
        var s = Partial()
        var events: [(ts: Date, cost: Double?, pct: Double?, tokens: Int)] = []
        var responseIDs = Set<String>()
        let readStart = min(cutoff, weekStart, windowStart ?? weekStart)
        var nextFiles: [String: CodexFileCache] = [:]
        var dirty = false
        guard let files = FileManager.default.enumerator(at: home.appendingPathComponent(".codex/sessions"),
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else {
            return (s, [:], !oldFiles.isEmpty)
        }
        for case let file as URL in files where file.pathExtension == "jsonl" {
            guard let meta = fileMetadata(file), meta.modified >= readStart else { continue }
            let key = file.path
            let entry: CodexFileCache
            if let old = oldFiles[key],
               canReuseFileCache(
                   modified: meta.modified, size: meta.size, readStart: readStart, now: now,
                   cachedModified: old.modified, cachedSize: old.size,
                   coveredFrom: old.coveredFrom, upperBound: old.upperBound, hadFutureEntries: old.hadFutureEntries
               ) {
                entry = old
            } else {
                dirty = true
                var turnStarted: Date?
                var model: String?
                var previousTotal: [String: Int]?
                var canonicalSinceLegacy = false
                var fileResponseIDs = Set<String>()
                var usages: [CachedCodexUsage] = []
                var pcts: [CachedCodexPct] = []
                var promptTimestamps: [Date] = []
                var toolCallTimestamps: [Date] = []

                func recordUsage(_ usage: [String: Any], responseID: String?, at ts: Date) {
                    guard ts >= readStart else { return }
                    let input = UsageNumbers.count(usage["input_tokens"])
                    let cached = UsageNumbers.count(usage["cached_input_tokens"])
                    let output = UsageNumbers.count(usage["output_tokens"])
                    let tokens = UsageNumbers.sum(input, output)
                    let cost = CodexValue.cost(model: model, input: input, cachedInput: cached, output: output)
                    usages.append(CachedCodexUsage(responseID: responseID, ts: ts, turnStarted: turnStarted, cost: cost, tokens: tokens))
                }
                let hadFuture = parseFile(file, cutoff: readStart, upperBound: now,
                          skip: { $0.contains("\"type\":\"reasoning\"") },
                          includeEarlierTypes: ["turn_context", "event_msg", "token_usage_record"]) { ts, row in
                    let payload = row["payload"] as? [String: Any] ?? [:]
                    switch row["type"] as? String {
                    case "turn_context":
                        turnStarted = ts
                        model = payload["model"] as? String
                    case "token_usage_record":
                        guard let id = payload["response_id"] as? String, !id.isEmpty,
                              let usage = payload["usage"] as? [String: Any] else { return }
                        canonicalSinceLegacy = true
                        if fileResponseIDs.insert(id).inserted { recordUsage(usage, responseID: id, at: ts) }
                    case "event_msg":
                        if payload["type"] as? String == "token_count" {
                            let info = payload["info"] as? [String: Any]
                            let total = info?["total_token_usage"] as? [String: Int]
                            let duplicate = total != nil && total == previousTotal
                            if let total { previousTotal = total }
                            if let last = info?["last_token_usage"] as? [String: Any] {
                                if !canonicalSinceLegacy, !duplicate { recordUsage(last, responseID: nil, at: ts) }
                                canonicalSinceLegacy = false
                            }
                            guard ts >= readStart else { return }
                            let limits = payload["rate_limits"] as? [String: Any]
                            let pct = weeklyPct(limits?["primary"] as? [String: Any])
                                ?? weeklyPct(limits?["secondary"] as? [String: Any])
                            if let pct { pcts.append(CachedCodexPct(ts: ts, pct: pct)) }
                        } else if payload["type"] as? String == "user_message", payload["message"] is String, ts >= readStart {
                            promptTimestamps.append(ts)
                        }
                    case "response_item":
                        if ts >= readStart, ["custom_tool_call", "function_call"].contains(payload["type"] as? String ?? "") {
                            toolCallTimestamps.append(ts)
                        }
                    default: break
                    }
                }
                entry = CodexFileCache(
                    modified: meta.modified, size: meta.size, coveredFrom: readStart, upperBound: now,
                    hadFutureEntries: hadFuture, usages: usages, pcts: pcts,
                    promptTimestamps: promptTimestamps, toolCallTimestamps: toolCallTimestamps
                )
            }
            nextFiles[key] = entry
            for u in entry.usages where u.ts >= readStart && u.ts < now {
                if let id = u.responseID, !responseIDs.insert(id).inserted { continue }
                if WeeklyWindow.includesRequest(startedAt: u.turnStarted, boundary: windowStart) {
                    events.append((u.ts, u.cost, nil, u.tokens))
                }
                if u.ts >= todayStart {
                    s.tokens = UsageNumbers.sum(s.tokens, u.tokens)
                    s.codexTodayCost += u.cost ?? 0
                }
            }
            for p in entry.pcts where p.ts >= readStart && p.ts < now {
                events.append((p.ts, 0, p.pct, 0))
            }
            for ts in entry.promptTimestamps where ts >= readStart && ts < now {
                if let i = dayIndex(ts, weekStart: weekStart, tomorrowStart: tomorrowStart) { s.week[i] += 1 }
                if ts >= todayStart { s.instructions += 1 }
            }
            for ts in entry.toolCallTimestamps where ts >= todayStart && ts < now {
                s.toolCalls += 1
            }
        }
        if nextFiles.count != oldFiles.count || Set(nextFiles.keys) != Set(oldFiles.keys) { dirty = true }
        events.sort { $0.ts < $1.ts }
        // Admitted turns are already bounded by WeeklyWindow.includesRequest; only fall
        // back to logReset when canonical windowStart is absent so the first post-reset
        // token_count drop cannot clip an earlier canonical token_usage_record.
        let ws = windowStart ?? lastPctDrop(events: events) ?? now
        for event in events where event.ts >= ws {
            if event.tokens > 0 && event.cost == nil { s.codexWindowUnpriced = true }
            s.codexWindowCost += event.cost ?? 0
            s.codexWindowTokens = UsageNumbers.sum(s.codexWindowTokens, event.tokens)
            if let pct = event.pct { s.codexWindowPct = (pct, event.ts) }
        }
        return (s, nextFiles, dirty)
    }

    /// used_percent of a rate-limit slot only when it is the 7-day window
    /// (window_minutes 10080). Codex currently reports the
    /// 5h slot as `primary` and the weekly slot as `secondary`; never fall back
    /// to the slot name here.
    private static func weeklyPct(_ slot: [String: Any]?) -> Double? {
        guard let slot else { return nil }
        guard integer(slot["window_minutes"]) == 10080 else { return nil }
        return UsageNumbers.percent(number(slot["used_percent"]))
    }

    private static func number(_ value: Any?) -> Double? {
        UsageNumbers.finite(value)
    }

    private static func integer(_ value: Any?) -> Int? {
        UsageNumbers.integer(value)
    }

    /// Fallback window-start detection: the last clear used_percent drop (a reset)
    /// among sorted events. Returns that event's timestamp, or nil if never dropped.
    private static func lastPctDrop(events: [(ts: Date, cost: Double?, pct: Double?, tokens: Int)]) -> Date? {
        var result: Date?
        var prev: Double?
        for e in events {
            if let pct = e.pct {
                if let prev, QuotaValueEstimate.isResetDrop(from: prev, to: pct) { result = e.ts }
                prev = pct
            }
        }
        return result
    }

    /// antigravity: ~/.gemini/{antigravity,antigravity-ide,antigravity-cli}/brain/<id>/.system_generated/logs/transcript.jsonl
    /// Instructions: USER_INPUT with source USER_EXPLICIT (excludes subagent system prompts).
    /// Tokens & tool calls: PLANNER_RESPONSE steps (deduplicated per conversation by step_index).
    /// Gemini quota-window totals are recomputed when any transcript changes and merged by replacement.
    static func scanAntigravity(home: URL, now: Date, cutoff: Date, weekStart: Date, todayStart: Date, tomorrowStart: Date, windowStart: Date? = nil) -> Partial {
        scanAntigravityCached(
            home: home, now: now, cutoff: cutoff, weekStart: weekStart,
            todayStart: todayStart, tomorrowStart: tomorrowStart, windowStart: windowStart, oldFiles: [:]
        ).partial
    }

    private static func scanAntigravityCached(
        home: URL, now: Date, cutoff: Date, weekStart: Date, todayStart: Date, tomorrowStart: Date,
        windowStart: Date?, oldFiles: [String: AntigravityFileCache]
    ) -> (partial: Partial, files: [String: AntigravityFileCache], dirty: Bool) {
        var s = Partial()
        let readStart = min(windowStart ?? weekStart, weekStart)
        let files = UsageHistoryScanner.antigravityTranscriptFiles(home: home, modifiedSince: readStart)
        var tokens = 0
        var instructions = 0
        var toolCalls = 0
        var windowCost = 0.0
        var windowTokens = 0
        var week = [Int](repeating: 0, count: 7)
        var nextFiles: [String: AntigravityFileCache] = [:]
        var dirty = false
        for file in files {
            guard let meta = fileMetadata(file) else { continue }
            let key = file.path
            let entry: AntigravityFileCache
            if let old = oldFiles[key],
               canReuseFileCache(
                   modified: meta.modified, size: meta.size, readStart: readStart, now: now,
                   cachedModified: old.modified, cachedSize: old.size,
                   coveredFrom: old.coveredFrom, upperBound: old.upperBound, hadFutureEntries: old.hadFutureEntries
               ) {
                entry = old
            } else {
                dirty = true
                var stepUsage: [Int: CachedAntigravityStep] = [:]
                var unindexedSteps: [CachedAntigravityStep] = []
                var promptTimestamps: [Date] = []
                var model: String?
                let hadFuture = parseFile(file, cutoff: readStart, upperBound: now, includeEarlierTypes: ["USER_INPUT", "PLANNER_RESPONSE"]) { ts, d in
                    let type = d["type"] as? String ?? ""
                    if let selected = AntigravitySpeedScanner.extractModel(from: d) {
                        model = selected.model
                    }
                    guard ts >= readStart else { return }
                    if type == "USER_INPUT", d["source"] as? String == "USER_EXPLICIT" {
                        promptTimestamps.append(ts)
                    } else if type == "PLANNER_RESPONSE" {
                        let inp = UsageNumbers.count(d["input_tokens"])
                        let cr = UsageNumbers.count(d["cache_read_tokens"])
                        let cw = UsageNumbers.count(d["cache_write_tokens"])
                        let out = UsageNumbers.count(d["output_tokens"])
                        let tok = UsageNumbers.sum(inp, cr, cw, out)
                        let tc = (d["tool_calls"] as? [[String: Any]])?.count ?? 0
                        let geminiCost = AntigravityValue.usesGeminiQuota(model)
                            ? AntigravityValue.cost(model: model, input: inp, cacheRead: cr, cacheWrite: cw, output: out)
                            : nil
                        if let step = (d["step_index"] as? NSNumber)?.intValue {
                            let prev = stepUsage[step] ?? CachedAntigravityStep(ts: ts, tokens: 0, tools: 0, geminiCost: nil)
                            stepUsage[step] = CachedAntigravityStep(
                                ts: ts,
                                tokens: max(prev.tokens, tok),
                                tools: max(prev.tools, tc),
                                geminiCost: tok >= prev.tokens ? geminiCost : prev.geminiCost
                            )
                        } else {
                            unindexedSteps.append(CachedAntigravityStep(ts: ts, tokens: tok, tools: tc, geminiCost: geminiCost))
                        }
                    }
                }
                entry = AntigravityFileCache(
                    modified: meta.modified, size: meta.size, coveredFrom: readStart, upperBound: now,
                    hadFutureEntries: hadFuture,
                    steps: Array(stepUsage.values) + unindexedSteps,
                    promptTimestamps: promptTimestamps
                )
            }
            nextFiles[key] = entry
            for ts in entry.promptTimestamps where ts >= readStart && ts < now {
                if let i = dayIndex(ts, weekStart: weekStart, tomorrowStart: tomorrowStart) {
                    week[i] += 1
                }
                if ts >= todayStart { instructions += 1 }
            }
            for v in entry.steps where v.ts >= readStart && v.ts < now {
                if v.ts >= todayStart {
                    tokens = UsageNumbers.sum(tokens, v.tokens)
                    toolCalls = UsageNumbers.sum(toolCalls, v.tools)
                }
                if let windowStart, v.ts >= windowStart, let geminiCost = v.geminiCost {
                    windowCost += geminiCost
                    windowTokens = UsageNumbers.sum(windowTokens, v.tokens)
                }
            }
        }
        if nextFiles.count != oldFiles.count || Set(nextFiles.keys) != Set(oldFiles.keys) { dirty = true }
        s.antigravityTodayTokens = tokens
        s.antigravityTodayInstructions = instructions
        s.antigravityTodayToolCalls = toolCalls
        s.antigravityWeekInstructions = week
        s.antigravityWindowCost = windowCost
        s.antigravityWindowTokens = windowTokens
        return (s, nextFiles, dirty)
    }

}
