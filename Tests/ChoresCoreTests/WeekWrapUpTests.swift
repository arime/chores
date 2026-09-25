import Testing
import Foundation
@testable import ChoresCore

@Suite struct WeekWrapUpTests {

    let helsinki = TimeZone(identifier: "Europe/Helsinki")!
    let utc = TimeZone(identifier: "UTC")!

    /// A wall-clock instant in `zone`.
    func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
            in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute))!
    }

    // 2026-09-21 is a Monday; 27 Sep is the Sunday of that week (ISO week 39).
    let week39 = WeekCalendar.isoWeek(containing: CalendarDay(year: 2026, month: 9, day: 21))

    // MARK: Window

    @Test func sundayBeforeSixIsNotYetTheWrapUp() {
        #expect(WeekWrapUp.current(now: at(2026, 9, 27, 17, 59, in: helsinki), timeZone: helsinki) == nil)
    }

    @Test func sundayAtSixReportsTheWeekJustEnding() {
        let wrapUp = WeekWrapUp.current(now: at(2026, 9, 27, 18, 0, in: helsinki), timeZone: helsinki)
        #expect(wrapUp?.moment == .sundayEvening)
        #expect(wrapUp?.week == week39)
        #expect(wrapUp?.key == "2026-W39")
    }

    @Test func mondayReportsThePreviousWeekAllDay() {
        let midnight = WeekWrapUp.current(now: at(2026, 9, 28, 0, 0, in: helsinki), timeZone: helsinki)
        let lateEvening = WeekWrapUp.current(now: at(2026, 9, 28, 23, 59, in: helsinki), timeZone: helsinki)
        #expect(midnight?.moment == .monday)
        #expect(midnight?.week == week39)
        #expect(midnight?.key == "2026-W39")
        #expect(lateEvening?.moment == .monday)
        #expect(lateEvening?.week == week39)
    }

    @Test func tuesdayHasNoCard() {
        #expect(WeekWrapUp.current(now: at(2026, 9, 29, 0, 0, in: helsinki), timeZone: helsinki) == nil)
    }

    @Test func theHourIsReadInTheFamilysZone() {
        // 18:00 in Helsinki is 15:00 in UTC, still afternoon there.
        let instant = at(2026, 9, 27, 18, 0, in: helsinki)
        #expect(WeekWrapUp.current(now: instant, timeZone: helsinki) != nil)
        #expect(WeekWrapUp.current(now: instant, timeZone: utc) == nil)
    }

    @Test func theSundayClocksGoBackStillOpensAtSix() {
        // 2026-10-25: Helsinki leaves DST at 04:00 that morning.
        let wrapUp = WeekWrapUp.current(now: at(2026, 10, 25, 18, 0, in: helsinki), timeZone: helsinki)
        #expect(wrapUp?.moment == .sundayEvening)
        #expect(wrapUp?.week.first == CalendarDay(year: 2026, month: 10, day: 19))
    }

    @Test func theWeekSpanningNewYearKeysAsWeek53() {
        // Monday 2026-12-28 starts ISO week 53 of 2026; Monday 2027-01-04 is 2027-W01.
        let wrapUp = WeekWrapUp.current(now: at(2027, 1, 4, 12, 0, in: helsinki), timeZone: helsinki)
        #expect(wrapUp?.moment == .monday)
        #expect(wrapUp?.week.first == CalendarDay(year: 2026, month: 12, day: 28))
        #expect(wrapUp?.key == "2026-W53")
    }

    // MARK: Percent and thresholds

    @Test func percentRoundsAndHandlesZero() {
        #expect(WeekWrapUp.percent(done: 0, total: 0) == 0)
        #expect(WeekWrapUp.percent(done: 1, total: 3) == 33)
        #expect(WeekWrapUp.percent(done: 2, total: 3) == 67)
        #expect(WeekWrapUp.percent(done: 3, total: 3) == 100)
    }

    @Test func kidVerdictAtEachBoundary() {
        #expect(WeekWrapUp.kidVerdict(done: 10, total: 10) == .complete)
        #expect(WeekWrapUp.kidVerdict(done: 8, total: 10) == .great)
        #expect(WeekWrapUp.kidVerdict(done: 7, total: 10) == .good)
        #expect(WeekWrapUp.kidVerdict(done: 5, total: 10) == .good)
        #expect(WeekWrapUp.kidVerdict(done: 4, total: 10) == .freshStart)
        #expect(WeekWrapUp.kidVerdict(done: 0, total: 0) == .freshStart)
    }

    @Test func parentToneAtEachBoundary() {
        #expect(WeekWrapUp.tone(done: 10, total: 10) == .complete)
        #expect(WeekWrapUp.tone(done: 6, total: 10) == .neutral)
        #expect(WeekWrapUp.tone(done: 5, total: 10) == .warn)
        #expect(WeekWrapUp.tone(done: 0, total: 0) == .neutral)
    }
}
