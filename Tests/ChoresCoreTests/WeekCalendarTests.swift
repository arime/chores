import Testing
@testable import ChoresCore

@Suite struct WeekCalendarTests {

    @Test func weekStartsOnMondayAndHasSevenDays() {
        // 2026-08-13 is a Thursday.
        let week = WeekCalendar.isoWeek(containing: CalendarDay(year: 2026, month: 8, day: 13))
        #expect(week.count == 7)
        #expect(week.first == CalendarDay(year: 2026, month: 8, day: 10))
        #expect(week.last == CalendarDay(year: 2026, month: 8, day: 16))
    }

    @Test func sundayBelongsToTheWeekThatStartedThePreviousMonday() {
        let week = WeekCalendar.isoWeek(containing: CalendarDay(year: 2026, month: 8, day: 16))
        #expect(week.first == CalendarDay(year: 2026, month: 8, day: 10))
    }

    @Test func mondayIsItsOwnWeekStart() {
        let week = WeekCalendar.isoWeek(containing: CalendarDay(year: 2026, month: 8, day: 10))
        #expect(week.first == CalendarDay(year: 2026, month: 8, day: 10))
    }

    @Test func weekSpanningAYearBoundaryIsContiguous() {
        // 2026-12-31 is a Thursday, so its week runs Mon 2026-12-28 … Sun 2027-01-03.
        let week = WeekCalendar.isoWeek(containing: CalendarDay(year: 2026, month: 12, day: 31))
        #expect(week.first == CalendarDay(year: 2026, month: 12, day: 28))
        #expect(week.last == CalendarDay(year: 2027, month: 1, day: 3))
    }
}
