import Foundation

/// Unified quota window
struct RateWindow: Sendable, Codable {
    let kind: String // "weekly" | "fiveHour"
    let usedPercent: Double?
    let used: Double?
    let limit: Double?
    let remaining: Double?
    let resetAt: Date?
    let resetsInSeconds: TimeInterval?

    var validUsedPercent: Double? { UsageNumbers.percent(usedPercent) }

    /// Absolute reset time wins over the countdown captured at the last fetch.
    func remainingSeconds(at now: Date = Date()) -> TimeInterval? {
        let seconds = resetAt.map { $0.timeIntervalSince(now) } ?? resetsInSeconds
        return seconds.flatMap { $0.isFinite ? $0 : nil }
    }
}

/// Account balance (pay-as-you-go accounts)
struct Balance: Sendable, Codable {
    let currency: String
    let total: Double
    let granted: Double
    let toppedUp: Double
}

/// Today's usage
struct DailyUsage: Sendable, Codable {
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let cost: Double
    let currency: String
    /// A recharge between wallet snapshots can hide some spend.
    var costIsEstimated: Bool? = nil
    var costIsLowerBound: Bool? = nil
    var costNote: String? = nil

    var isEmpty: Bool { totalTokens == 0 && cost == 0 && costIsLowerBound != true }
}

/// Result for a single tool
struct ProviderResult: Sendable, Codable {
    let id: String
    let name: String
    let plan: String?
    let weekly: RateWindow?
    let fiveHour: RateWindow?
    let balance: Balance?
    let todayUsage: DailyUsage?
    let error: String?
    /// True when this data is a cached copy (the live fetch failed) — rendered with a tinted background
    var stale: Bool = false

    var ok: Bool { error == nil }
}

extension ProviderResult {
    /// Whether the 5h window carries useful information: it exists AND the weekly
    /// window hasn't already hit 100% (then the 5h number is meaningless).
    /// Tools without a 5h limit return false and the row is omitted.
    var fiveHourValid: Bool {
        guard fiveHour != nil else { return false }
        if let weekly = weekly?.usedPercent, weekly >= 100 { return false }
        return true
    }
}
