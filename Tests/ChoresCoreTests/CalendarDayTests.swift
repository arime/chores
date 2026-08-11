import Testing
import Foundation
@testable import ChoresCore

private let helsinki = TimeZone(identifier: "Europe/Helsinki")!
private let utc = TimeZone(identifier: "UTC")!

@Suite struct CalendarDayTests {

    @Test func isoWeekdayMapsMondayToOne() {
        // 2026-08-10 is a Monday.
        #expect(CalendarDay(year: 2026, month: 8, day: 10).isoWeekday == 1)
        #expect(CalendarDay(year: 2026, month: 8, day: 11).isoWeekday == 2)
        #expect(CalendarDay(year: 2026, month: 8, day: 12).isoWeekday == 3)
        #expect(CalendarDay(year: 2026, month: 8, day: 13).isoWeekday == 4)
        #expect(CalendarDay(year: 2026, month: 8, day: 14).isoWeekday == 5)
        #expect(CalendarDay(year: 2026, month: 8, day: 15).isoWeekday == 6)
        #expect(CalendarDay(year: 2026, month: 8, day: 16).isoWeekday == 7)
    }

    @Test func localDayDiffersFromUTCDayLateInTheEvening() {
        // 2026-08-10T21:10Z is 2026-08-11T00:10 in Helsinki (+03:00).
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 10
        components.hour = 21; components.minute = 10
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = utc
        let instant = utcCalendar.date(from: components)!

        #expect(CalendarDay(instant, in: helsinki) == CalendarDay(year: 2026, month: 8, day: 11))
        #expect(CalendarDay(instant, in: utc) == CalendarDay(year: 2026, month: 8, day: 10))
    }

    @Test func addingDaysCrossesMonthAndYearBoundaries() {
        #expect(CalendarDay(year: 2026, month: 8, day: 31).adding(days: 1)
                == CalendarDay(year: 2026, month: 9, day: 1))
        #expect(CalendarDay(year: 2026, month: 1, day: 1).adding(days: -1)
                == CalendarDay(year: 2025, month: 12, day: 31))
    }

    @Test func addingDaysIsUnaffectedByDSTTransitions() {
        // EU DST ends on the last Sunday of October; 2026-10-25 in Helsinki has 25 hours.
        #expect(CalendarDay(year: 2026, month: 10, day: 24).adding(days: 1)
                == CalendarDay(year: 2026, month: 10, day: 25))
        #expect(CalendarDay(year: 2026, month: 10, day: 25).adding(days: 1)
                == CalendarDay(year: 2026, month: 10, day: 26))
    }

    @Test func codableRoundTripsAsISOString() throws {
        let day = CalendarDay(year: 2026, month: 8, day: 9)
        let data = try JSONEncoder().encode(day)
        #expect(String(decoding: data, as: UTF8.self) == "\"2026-08-09\"")
        #expect(try JSONDecoder().decode(CalendarDay.self, from: data) == day)
    }

    @Test func comparableOrdersChronologically() {
        #expect(CalendarDay(year: 2026, month: 1, day: 2) < CalendarDay(year: 2026, month: 2, day: 1))
    }
}
