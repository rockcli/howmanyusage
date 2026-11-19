import Foundation

/// A single conservative boundary for local logs and server attribution.
/// The interval before the first post-reset observation cannot safely be assigned.
enum WeeklyWindow {
    /// A factual heads-up, with no rate history required. When a projection exists,
    /// require it to confirm substantial unused quota; exhaustion/spikes take priority.
    static func expiringUnusedPercent(
        window: RateWindow, stale: Bool, projectedAtReset: Double?,
        exhaustsIn: TimeInterval?, spikeDelta: Double?, now: Date = Date()
    ) -> Double? {
        guard window.kind == "weekly", !stale,
              let remaining = window.remainingSeconds(at: now), remaining > 0, remaining <= 6 * 3600,
              let used = window.validUsedPercent, used <= 70 else { return nil }
        if let projectedAtReset {
            guard let projected = UsageNumbers.percent(projectedAtReset), projected <= 70 else { return nil }
        }
        if let exhaustsIn {
            guard exhaustsIn.isFinite, exhaustsIn >= remaining else { return nil }
        }
        if let spikeDelta {
            guard spikeDelta.isFinite, spikeDelta == 0 else { return nil }
        }
        return 100 - used
    }

    static func includesRequest(startedAt: Date?, boundary: Date?) -> Bool {
        guard let startedAt, let boundary else { return false }
        return startedAt >= boundary
    }

    static func start(id: String, resetAt: Date? = nil, history: [UsageSnapshot]? = nil) -> Date? {
        guard ["codex", "claude", "antigravity"].contains(id) else { return nil }
        let rows = (history ?? StateStore.history()).sorted { $0.ts < $1.ts }
        func fields(_ row: UsageSnapshot) -> (Double?, Double?) {
            switch id {
            case "codex":
                return (row.codexWeekly, row.codexWeeklyReset.flatMap(Double.init))
            case "claude":
                return (row.claudeWeekly, row.claudeWeeklyReset.flatMap(Double.init))
            default:
                return (row.antigravityWeekly, row.antigravityWeeklyReset.flatMap(Double.init))
            }
        }
        let valid = rows.filter { let (pct, reset) = fields($0); return pct?.isFinite == true && reset?.isFinite == true }
        guard let latest = valid.last else {
            if id == "antigravity", let epoch = resetAt?.timeIntervalSince1970, epoch.isFinite {
                return Date(timeIntervalSince1970: epoch - 7 * 86400)
            }
            return nil
        }
        let (_, latestReset) = fields(latest)
        guard let epoch = resetAt?.timeIntervalSince1970 ?? latestReset, epoch.isFinite else { return nil }
        let nominal = Date(timeIntervalSince1970: epoch - 7 * 86400)
        if id == "antigravity" {
            return nominal
        }
        // A freshly fetched reset not yet in history: exclude everything until it is recorded.
        guard abs((latestReset ?? 0) - epoch) < 300 else { return nil }
        var first = latest
        guard var pct = fields(latest).0 else { return nil }
        for row in valid.dropLast().reversed() {
            let (olderPct, olderReset) = fields(row)
            guard let olderReset, let olderPct,
                  abs(olderReset - epoch) < 300, olderPct <= pct + 0.000001 else { break }
            first = row
            pct = olderPct
        }
        return max(nominal, first.ts)
    }
}
