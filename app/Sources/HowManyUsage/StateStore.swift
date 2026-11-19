import Foundation

/// Local state persisted at ~/.config/howmanyusage/state.json:
/// - last known resetAt per quota window (to detect resets)
/// - 7-day usage snapshots (history-based recovery, pace forecast, and short-window spike detection)
/// - provider data cache, today-work stats
struct UsageSnapshot: Codable {
    let ts: Date
    let codexWeekly: Double?
    let codexWeeklyReset: String?
    var codex5h: Double? = nil
    var codex5hReset: String? = nil
    let claudeWeekly: Double?
    let claudeWeeklyReset: String?
    let claude5h: Double?
    let claude5hReset: String?
    var antigravityWeekly: Double? = nil
    var antigravityWeeklyReset: String? = nil
    var antigravity5h: Double? = nil
    var antigravity5hReset: String? = nil
    let dsBalance: Double?
    let dsTodayTokens: Int?
    var colabBalance: Double? = nil
}

/// Last whole-window API-equivalent value and its preceding-window anchor.
/// The anchor keeps the display stable just after a quota reset, when an
/// integer 1% usage reading makes a direct cost/percent estimate very noisy.
struct QuotaValueEstimate: Codable {
    var resetEpoch: Double?
    var observedPercent: Double?
    var monthlyUSD: Double
    var previousMonthlyUSD: Double?
    /// Last value computed from a window this machine actually explains (no material
    /// cloud consumption). A cloud-heavy window must not overwrite it — otherwise the
    /// displayed multiple silently collapses toward 1×.
    var cleanMonthlyUSD: Double?

    static func isResetDrop(from old: Double, to new: Double) -> Bool {
        old.isFinite && new.isFinite && old - new >= 20 && new <= 20
    }

    static func updated(
        _ existing: Self?, resetEpoch: Double?, observedPercent: Double?, rawMonthlyUSD: Double?,
        isDiluted: Bool = false
    ) -> Self? {
        let raw = rawMonthlyUSD.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let pct = observedPercent.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        guard var value = existing else {
            guard let raw, !isDiluted else { return nil }
            return Self(resetEpoch: resetEpoch, observedPercent: pct,
                        monthlyUSD: raw, previousMonthlyUSD: nil, cleanMonthlyUSD: raw)
        }
        let resetChanged = value.resetEpoch.flatMap { old in
            resetEpoch.map { abs(old - $0) >= 300 }
        } ?? false
        let sharpDrop = value.observedPercent.flatMap { old in
            pct.map { isResetDrop(from: old, to: $0) }
        } ?? false
        if resetChanged || sharpDrop {
            value.previousMonthlyUSD = value.monthlyUSD
            value.resetEpoch = resetEpoch
        } else if let resetEpoch {
            value.resetEpoch = resetEpoch
        }
        if let pct { value.observedPercent = pct }
        if let raw {
            if let anchor = value.previousMonthlyUSD, let pct {
                let weight = min(1, pct / 20)
                value.monthlyUSD = anchor * (1 - weight) + raw * weight
            } else {
                value.monthlyUSD = raw
            }
            // Only an undiluted window may refresh the local-mix anchor.
            if !isDiluted { value.cleanMonthlyUSD = value.monthlyUSD }
        }
        return value
    }
}

// Lenient decode (extension keeps the memberwise init): a snapshot written by
// an older binary must never fail the whole history array — Swift's synthesized
// decoding ignores property defaults, so any newly added non-optional field
// would otherwise throw keyNotFound on old entries and drop every snapshot.
extension UsageSnapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts = try c.decode(Date.self, forKey: .ts)
        codexWeekly = try c.decodeIfPresent(Double.self, forKey: .codexWeekly)
        codexWeeklyReset = try c.decodeIfPresent(String.self, forKey: .codexWeeklyReset)
        codex5h = try c.decodeIfPresent(Double.self, forKey: .codex5h)
        codex5hReset = try c.decodeIfPresent(String.self, forKey: .codex5hReset)
        claudeWeekly = try c.decodeIfPresent(Double.self, forKey: .claudeWeekly)
        claudeWeeklyReset = try c.decodeIfPresent(String.self, forKey: .claudeWeeklyReset)
        claude5h = try c.decodeIfPresent(Double.self, forKey: .claude5h)
        claude5hReset = try c.decodeIfPresent(String.self, forKey: .claude5hReset)
        antigravityWeekly = try c.decodeIfPresent(Double.self, forKey: .antigravityWeekly)
        antigravityWeeklyReset = try c.decodeIfPresent(String.self, forKey: .antigravityWeeklyReset)
        antigravity5h = try c.decodeIfPresent(Double.self, forKey: .antigravity5h)
        antigravity5hReset = try c.decodeIfPresent(String.self, forKey: .antigravity5hReset)
        dsBalance = try c.decodeIfPresent(Double.self, forKey: .dsBalance)
        dsTodayTokens = try c.decodeIfPresent(Int.self, forKey: .dsTodayTokens)
        colabBalance = try c.decodeIfPresent(Double.self, forKey: .colabBalance)
    }
}

/// A malformed snapshot must not erase every other provider's seven-day history.
/// Decode each element through its own decoder so a failed entry still advances
/// the array cursor; retain the original state file before saving a repaired one.
struct SnapshotHistory: Decodable {
    private struct Entry: Decodable {
        let snapshot: UsageSnapshot?
        init(from decoder: Decoder) throws {
            snapshot = try? UsageSnapshot(from: decoder)
        }
    }
    let snapshots: [UsageSnapshot]
    let discardedEntries: Bool

    init(from decoder: Decoder) throws {
        let entries = try [Entry](from: decoder)
        snapshots = entries.compactMap(\.snapshot)
        discardedEntries = snapshots.count != entries.count
    }
}

struct StateStore {
    private struct State: Codable {
        var lastResetAt: [String: String] = [:]
        var history: [UsageSnapshot] = []
        var providerCache: [String: ProviderResult] = [:]
        var todayStats: TodayStats?
        var todayStatsSavedAt: Date?
        var todayStatsSource: String?
        var quotaValueEstimates: [String: QuotaValueEstimate] = [:]
        /// Server-side Codex usage attribution (cloud vs local tokens, per-conversation
        /// quota shares). Undocumented endpoints: cached so a failed fetch degrades to
        /// the previous snapshot instead of blanking the section.
        var codexServerUsage: CodexServerUsage.Snapshot?
        var codexServerUsageSavedAt: Date?
        /// Schema marker for `QuotaValueEstimate.cleanMonthlyUSD` (see ensureLoaded).
        var cleanAnchorVersion: String?
        var antigravityGeminiQuota = true
        var repairedHistory = false

        init() {}

        enum CodingKeys: String, CodingKey {
            case lastResetAt, history, providerCache
            case todayStats, todayStatsSavedAt, todayStatsSource, quotaValueEstimates
            case codexServerUsage, codexServerUsageSavedAt, cleanAnchorVersion
            case antigravityGeminiQuota
        }

        // Field-isolated decode: one cache field written in an older shape (a
        // binary built before a struct change) must not fail the whole file and
        // silently wipe quota history — that is how the today-marker baseline
        // was lost on 2026-08-31.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lastResetAt = (try? c.decode([String: String].self, forKey: .lastResetAt)) ?? [:]
            let decodedHistory = try? c.decode(SnapshotHistory.self, forKey: .history)
            history = decodedHistory?.snapshots ?? []
            repairedHistory = decodedHistory?.discardedEntries == true
                || (c.contains(.history) && decodedHistory == nil)
            providerCache = (try? c.decode([String: ProviderResult].self, forKey: .providerCache)) ?? [:]
            todayStats = (try? c.decodeIfPresent(TodayStats.self, forKey: .todayStats)) ?? nil
            todayStatsSavedAt = (try? c.decodeIfPresent(Date.self, forKey: .todayStatsSavedAt)) ?? nil
            todayStatsSource = (try? c.decodeIfPresent(String.self, forKey: .todayStatsSource)) ?? nil
            quotaValueEstimates = (try? c.decode([String: QuotaValueEstimate].self, forKey: .quotaValueEstimates)) ?? [:]
            codexServerUsage = (try? c.decodeIfPresent(CodexServerUsage.Snapshot.self, forKey: .codexServerUsage)) ?? nil
            codexServerUsageSavedAt = (try? c.decodeIfPresent(Date.self, forKey: .codexServerUsageSavedAt)) ?? nil
            cleanAnchorVersion = (try? c.decodeIfPresent(String.self, forKey: .cleanAnchorVersion)) ?? nil
            antigravityGeminiQuota = (try? c.decode(Bool.self, forKey: .antigravityGeminiQuota)) ?? false
        }
    }

    private static var state = State()
    private static let lock = NSLock()
    private static var loaded = false
    // Version changes when model prices or window accounting change, so an
    // installed upgrade never displays a value calculated by the old binary.
    private static let todayStatsSourceID = "today-stats.raw-scan.v13"
    /// Bumped when the meaning of `QuotaValueEstimate.cleanMonthlyUSD` changes. Builds
    /// that wrote the anchor without the cloud-dilution guard must not be trusted.
    private static let cleanAnchorVersionID = "codex-clean-anchor.v2"

    private static func url() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/howmanyusage/state.json")
    }

    private static func ensureLoaded() {
        if loaded { return }
        loaded = true
        guard let data = try? Data(contentsOf: url()) else { return }
        if let decoded = try? JSONDecoder().decode(State.self, from: data) {
            state = decoded
            if decoded.repairedHistory {
                try? data.write(to: url().appendingPathExtension("bak"), options: [.atomic])
            }
        } else if !data.isEmpty {
            // Undecodable state (corrupt, or written by a binary with drifted
            // cache shapes): keep the original for inspection instead of letting
            // the next save overwrite the only copy.
            try? data.write(to: url().appendingPathExtension("bak"), options: [.atomic])
        }
        if state.todayStatsSource != todayStatsSourceID {
            state.quotaValueEstimates = [:]
        }
        // Kimi was retired from the app. Drop its cached provider data and reset
        // markers on the first load; the next save also rewrites old snapshots
        // without the removed Kimi fields.
        // The local-mix anchor may only be written by an undiluted window. Earlier builds
        // of this feature seeded it from a diluted window, so drop those values once.
        if state.cleanAnchorVersion != cleanAnchorVersionID {
            for (id, var estimate) in state.quotaValueEstimates where estimate.cleanMonthlyUSD != nil {
                estimate.cleanMonthlyUSD = nil
                state.quotaValueEstimates[id] = estimate
            }
            // A Codex estimate recorded while the weekly quota was consumed mostly
            // off-machine carries no information about this machine's rate — every field
            // of it (including the reset anchor) is diluted, so start that entry over.
            // The row shows "estimating" until an undiluted window completes.
            let usedPercent = state.providerCache["codex"]?.weekly?.usedPercent
            if state.codexServerUsage?.isDiluted(usedPercent: usedPercent) == true {
                state.quotaValueEstimates.removeValue(forKey: "codex")
            }
            state.cleanAnchorVersion = cleanAnchorVersionID
            save()
        }
        let hadRetiredCache = state.providerCache.removeValue(forKey: "kimi") != nil
        let previousWindowCount = state.lastResetAt.count
        state.lastResetAt = state.lastResetAt.filter { !$0.key.hasPrefix("kimi.") }
        // Trim history to 7 days
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        state.history = state.history.filter { $0.ts >= cutoff }
        let migrateAntigravityQuota = !state.antigravityGeminiQuota
        if migrateAntigravityQuota {
            // Older samples could come from either model group, with no group ID recorded.
            state.providerCache.removeValue(forKey: "antigravity")
            state.lastResetAt.removeValue(forKey: "antigravity.weekly")
            state.lastResetAt.removeValue(forKey: "antigravity.fiveHour")
            for index in state.history.indices {
                state.history[index].antigravityWeekly = nil
                state.history[index].antigravityWeeklyReset = nil
                state.history[index].antigravity5h = nil
                state.history[index].antigravity5hReset = nil
            }
            state.todayStats?.antigravityWindowStart = nil
            state.todayStats?.antigravityWindowTokens = nil
            state.todayStats?.antigravityWindowCostUSD = nil
            state.antigravityGeminiQuota = true
        }
        if migrateAntigravityQuota || hadRetiredCache || state.lastResetAt.count != previousWindowCount {
            save()
        }
    }

    private static func save() {
        // Caller holds the lock; never lock here (NSLock is not reentrant).
        let dir = url().deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url(), options: [.atomic])
        }
    }

    // MARK: - Reset detection (green dot)

    /// Returns true if any window reset since the last refresh, and records the new baselines.
    static func updateWindows(_ windows: [String: String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        ensureLoaded()
        if state.lastResetAt.isEmpty {
            // First run: baseline only, no dot
            state.lastResetAt = windows
            save()
            return false
        }
        var dot = false
        // Claude's resets_at carries ~1s of floating noise (recomputed per request),
        // so compare with tolerance: differences < 5 min mean "same window".
        // A real reset shifts the window by 5h or 7d, far beyond the tolerance.
        let value = { (s: String) -> Double? in Double(s) }
        for (key, resetAt) in windows {
            guard let prev = state.lastResetAt[key], !prev.isEmpty,
                  let a = value(prev), let b = value(resetAt)
            else { continue }
            if abs(a - b) >= 300 {
                dot = true
            }
        }
        state.lastResetAt = windows
        save()
        return dot
    }

    // MARK: - History

    static func appendSnapshot(_ snapshot: UsageSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        ensureLoaded()
        state.history.append(snapshot)
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        state.history = state.history.filter { $0.ts >= cutoff }
        save()
    }

    static func history() -> [UsageSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        ensureLoaded()
        return state.history
    }

    /// Blend the previous window's value with the new window's raw estimate.
    /// Returns nil only when no usable current or historical estimate exists.
    static func monthlyQuotaValue(
        id: String, resetAt: Date?, observedPercent: Double?, rawMonthlyUSD: Double?
    ) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        ensureLoaded()
        guard let value = QuotaValueEstimate.updated(
            state.quotaValueEstimates[id], resetEpoch: resetAt?.timeIntervalSince1970,
            observedPercent: observedPercent, rawMonthlyUSD: rawMonthlyUSD
        ) else { return nil }
        state.quotaValueEstimates[id] = value
        save()
        return value.monthlyUSD
    }

    // MARK: - Provider data cache (persisted, survives restarts)

    static func loadProviderCache() -> [String: ProviderResult] {
        lock.lock()
        defer { lock.unlock() }
        ensureLoaded()
        return state.providerCache
    }

    static func saveProviderCache(_ p: ProviderResult) {
        lock.lock()
        defer { lock.unlock() }
        ensureLoaded()
        state.providerCache[p.id] = p
        save()
    }

    // MARK: - Today-work stats cache (persisted: shown instantly while the rescan runs)

    static func loadTodayStats() -> TodayStats? {
        lock.lock()
        defer { lock.unlock() }
        ensureLoaded()
        guard state.todayStatsSource == todayStatsSourceID else { return nil }
        return state.todayStats
    }

    static func saveTodayStats(_ stats: TodayStats) {
        lock.lock()
        defer { lock.unlock() }
        ensureLoaded()
        state.todayStats = stats
        state.todayStatsSavedAt = Date()
        state.todayStatsSource = todayStatsSourceID
        save()
    }

    // MARK: - Server-side Codex usage attribution

    /// Compatibility accessor: only the supplied current-window estimate is admissible.
    /// No persisted prior-window value is read or written.
    static func codexQuotaValue(
        resetAt: Date?, observedPercent: Double?, rawMonthlyUSD: Double?, isDiluted: Bool
    ) -> (monthly: Double, isPrior: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        ensureLoaded()
        // A previous-window anchor must not leak pre-reset consumption into this estimate.
        guard let rawMonthlyUSD, rawMonthlyUSD.isFinite, rawMonthlyUSD > 0 else { return nil }
        return (rawMonthlyUSD, false)
    }

    /// Last successfully fetched server attribution, regardless of age — the menu
    /// prefers a stale split (with its timestamp) over showing nothing.
    static func loadCodexServerUsage() -> CodexServerUsage.Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        ensureLoaded()
        return state.codexServerUsage
    }

    static func saveCodexServerUsage(_ snapshot: CodexServerUsage.Snapshot) {
        lock.lock()
        defer { lock.unlock() }
        ensureLoaded()
        state.codexServerUsage = snapshot
        state.codexServerUsageSavedAt = Date()
        save()
    }

}
