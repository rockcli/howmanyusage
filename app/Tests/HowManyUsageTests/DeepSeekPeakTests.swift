import Foundation
import Testing
@testable import HowManyUsage

struct DeepSeekPeakTests {
    private let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private func utcDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // Fixture week: 2026-08-28 is a Friday, 08-29/08-30 the Beijing weekend, 08-31 Monday.

    @Test func testWeekdayWindowsStillPeak() {
        #expect(DeepSeekPeak.isPeak(at: utcDate(2026, 8, 28, 2)))   // Fri 02:00 UTC, in 01–04
        #expect(DeepSeekPeak.isPeak(at: utcDate(2026, 8, 28, 7)))   // Fri 07:00 UTC, in 06–10
        #expect(!(DeepSeekPeak.isPeak(at: utcDate(2026, 8, 28, 12)))) // Fri 12:00 UTC, between windows
        #expect(!(DeepSeekPeak.isPeak(at: utcDate(2026, 8, 28, 0, 59))))
    }

    @Test func testBeijingWeekendIsAllOffPeak() {
        // Sat 10:00 Beijing = Sat 02:00 UTC — inside a UTC window, yet off-peak.
        let satMorning = utcDate(2026, 8, 29, 2)
        #expect(DeepSeekPeak.isWeekendBeijing(satMorning))
        #expect(!(DeepSeekPeak.isPeak(at: satMorning)))
        #expect(!(DeepSeekPeak.isPeak(at: utcDate(2026, 8, 30, 8, 30))))
        // Weekend edges: Beijing Saturday 00:00 = Friday 16:00 UTC.
        #expect(!(DeepSeekPeak.isWeekendBeijing(utcDate(2026, 8, 28, 15, 59))))
        #expect(DeepSeekPeak.isWeekendBeijing(utcDate(2026, 8, 28, 16)))
        // Monday 00:00 Beijing = Sunday 16:00 UTC: weekday rules resume.
        #expect(!(DeepSeekPeak.isWeekendBeijing(utcDate(2026, 8, 30, 16))))
        #expect(DeepSeekPeak.isPeak(at: utcDate(2026, 8, 31, 1, 30)))
    }

    @Test func testChinesePublicHolidayIsAllOffPeak() {
        // 2026 National Day: Thursday 10:00 Beijing would normally be a peak
        // window, but the official holiday schedule makes it off-peak.
        let nationalDayMorning = utcDate(2026, 10, 1, 2)
        #expect(DeepSeekPeak.isChineseHolidayBeijing(nationalDayMorning))
        #expect(!(DeepSeekPeak.isPeak(at: nationalDayMorning)))

        // 2026 Mid-Autumn Festival is also a weekday holiday.
        let midAutumnMorning = utcDate(2026, 9, 25, 2)
        #expect(DeepSeekPeak.isChineseHolidayBeijing(midAutumnMorning))
        #expect(!(DeepSeekPeak.isPeak(at: midAutumnMorning)))
    }

    @Test func testWeekendMakeupWorkdayIsStillOffPeak() {
        // 2026-09-20 is an official makeup-work Sunday, but the pricing rule
        // follows the actual weekend date rather than the workday adjustment.
        let makeupWorkday = utcDate(2026, 9, 20, 2)
        #expect(DeepSeekPeak.isWeekendBeijing(makeupWorkday))
        #expect(!(DeepSeekPeak.isPeak(at: makeupWorkday)))
    }

    @Test func testFridayEveningNextTransitionIsMondayPeak() {
        // Fri 12:00 UTC: past all windows and tomorrow is off-peak, so the next flip
        // is Monday 01:00 UTC — 61h out, not Saturday 01:00 as the old wrap gave.
        let (isPeak, until) = DeepSeekPeak.status(at: utcDate(2026, 8, 28, 12))
        #expect(!(isPeak))
        #expect(abs(until - (61 * 3600)) <= 1)
    }

    @Test func testWeekendNextTransitionIsMondayPeak() {
        // Sat 02:00 UTC (would be peak on a weekday) → Monday 01:00 UTC = 47h out.
        let (isPeak, until) = DeepSeekPeak.status(at: utcDate(2026, 8, 29, 2))
        #expect(!(isPeak))
        #expect(abs(until - (47 * 3600)) <= 1)
    }

    @Test func testFridayPeakStillEndsAtWindowEdge() {
        let (isPeak, until) = DeepSeekPeak.status(at: utcDate(2026, 8, 28, 7))
        #expect(isPeak)
        #expect(abs(until - (3 * 3600)) <= 1)
    }

    @Test func testWeekdayNightNextTransitionIsTomorrowFirstWindow() {
        // Thu 12:00 UTC (2026-08-27): next flip is Friday 01:00 UTC = 13h out.
        let (isPeak, until) = DeepSeekPeak.status(at: utcDate(2026, 8, 27, 12))
        #expect(!(isPeak))
        #expect(abs(until - (13 * 3600)) <= 1)
    }
}
