import Foundation

/// DeepSeek's time-of-day pricing (effective 2026-09-10, V4.1 lineup): peak windows cost
/// more, off-peak is 50% of peak. Windows are published in UTC (peak: 01:00–04:00 and
/// 06:00–10:00 UTC); Beijing-time weekends and Chinese public holidays are off-peak
/// around the clock. Weekend makeup-work days remain off-peak because DeepSeek's
/// calendar rule follows the actual Saturday/Sunday date, not China's workday swap.
/// `Date` already carries an absolute instant, so the UTC window comparison is correct
/// no matter what timezone this machine's clock is set to. Weekend and holiday rules
/// use an explicit Asia/Shanghai calendar: Beijing Saturday 00:00 lands on Friday
/// 16:00 UTC.
enum DeepSeekPeak {
    /// (start, end) in UTC hour-of-day, e.g. 1.0..<4.0 = 01:00–04:00 UTC.
    static let peakWindowsUTC: [(start: Double, end: Double)] = [(1, 4), (6, 10)]

    private static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private static let beijing: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }()

    private static let chinese: Calendar = {
        var cal = Calendar(identifier: .chinese)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }()

    /// The 2026 State Council holiday windows. Keep the official schedule
    /// separate from the recurring fallback below because adjusted holiday
    /// periods are announced year by year and can span several calendar days.
    private static let officialHolidayRanges: [Int: [(month: Int, start: Int, end: Int)]] = [
        2026: [
            (1, 1, 3),    // New Year
            (2, 15, 23),  // Spring Festival
            (4, 4, 6),    // Qingming
            (5, 1, 5),    // Labour Day
            (6, 19, 21),  // Dragon Boat Festival
            (9, 25, 27),  // Mid-Autumn Festival
            (10, 1, 7),   // National Day
        ],
    ]

    static func hourOfDayUTC(_ date: Date = Date()) -> Double {
        let c = utc.dateComponents([.hour, .minute, .second], from: date)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
    }

    /// Whether `date` lands on a Beijing-time Saturday/Sunday (all off-peak).
    static func isWeekendBeijing(_ date: Date = Date()) -> Bool {
        let weekday = beijing.component(.weekday, from: date)
        return weekday == 1 || weekday == 7 // Sunday, Saturday
    }

    /// Whether `date` is within a Chinese public-holiday window. For years whose
    /// State Council schedule is not yet recorded, use the recurring Gregorian
    /// and lunar festival windows as a safe local fallback.
    static func isChineseHolidayBeijing(_ date: Date = Date()) -> Bool {
        let gregorian = beijing.dateComponents([.year, .month, .day], from: date)
        guard let year = gregorian.year, let month = gregorian.month, let day = gregorian.day else {
            return false
        }

        if let ranges = officialHolidayRanges[year] {
            return ranges.contains { $0.month == month && day >= $0.start && day <= $0.end }
        }

        // Fallback for future years until their official adjusted schedule is
        // published. The ranges cover the usual public-holiday windows; lunar
        // dates are read from Foundation's Chinese calendar.
        if (month == 1 && day <= 3)
            || (month == 4 && (4...6).contains(day))
            || (month == 5 && (1...5).contains(day))
            || (month == 10 && (1...7).contains(day)) {
            return true
        }

        let lunar = chinese.dateComponents([.month, .day], from: date)
        if #available(macOS 14.0, *) {
            let leap = chinese.dateComponents([.isLeapMonth], from: date)
            if leap.isLeapMonth == true { return false }
        }
        guard let lunarMonth = lunar.month,
              let lunarDay = lunar.day else {
            return false
        }
        return (lunarMonth == 12 && lunarDay >= 28)
            || (lunarMonth == 1 && lunarDay <= 7)
            || (lunarMonth == 5 && (5...7).contains(lunarDay))
            || (lunarMonth == 8 && (15...17).contains(lunarDay))
    }

    /// Whether `date` (default now) falls in a peak-price window. Beijing
    /// weekends and Chinese public holidays are always off-peak.
    static func isPeak(at date: Date = Date()) -> Bool {
        if isWeekendBeijing(date) || isChineseHolidayBeijing(date) { return false }
        let h = hourOfDayUTC(date)
        return peakWindowsUTC.contains { h >= $0.start && h < $0.end }
    }

    /// Current status: whether we're in peak right now, and seconds until the next
    /// peak↔off-peak transition. The next flip is found by scanning the boundary
    /// instants (UTC window edges each day, plus Beijing midnights where weekend or
    /// holiday rules engage) — so a long holiday is treated as one continuous
    /// off-peak block.
    static func status(at date: Date = Date()) -> (isPeak: Bool, untilTransition: TimeInterval) {
        let nowPeak = isPeak(at: date)
        var candidates: [Date] = []
        var utcDay = utc.startOfDay(for: date)
        var beijingDay = beijing.startOfDay(for: date)
        for _ in 0..<16 {
            for w in peakWindowsUTC {
                candidates.append(utcDay.addingTimeInterval(w.start * 3600))
                candidates.append(utcDay.addingTimeInterval(w.end * 3600))
            }
            candidates.append(beijingDay) // Beijing midnight: weekend/holiday edge
            utcDay = utcDay.addingTimeInterval(86_400)
            beijingDay = beijingDay.addingTimeInterval(86_400)
        }
        if let next = candidates.filter({ $0 > date && isPeak(at: $0) != nowPeak }).min() {
            return (nowPeak, next.timeIntervalSince(date))
        }
        return (nowPeak, 86_400) // unreachable: 16 days of candidates always contain a flip
    }
}
