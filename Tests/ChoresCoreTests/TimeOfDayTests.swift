import Testing
import Foundation
@testable import ChoresCore

@Suite struct TimeOfDayTests {

    let helsinki = TimeZone(identifier: "Europe/Helsinki")!

    @Test func decodesPostgresTimeWithSeconds() throws {
        let time = try ChoresJSON.decoder.decode(TimeOfDay.self, from: Data("\"20:00:00\"".utf8))
        #expect(time == TimeOfDay(hour: 20, minute: 0))
    }

    @Test func decodesHoursAndMinutesOnly() throws {
        let time = try ChoresJSON.decoder.decode(TimeOfDay.self, from: Data("\"07:45\"".utf8))
        #expect(time == TimeOfDay(hour: 7, minute: 45))
    }

    @Test func rejectsAnythingElse() {
        for raw in ["\"25:00:00\"", "\"20:60\"", "\"noon\"", "\"20\""] {
            #expect(throws: DecodingError.self) {
                _ = try ChoresJSON.decoder.decode(TimeOfDay.self, from: Data(raw.utf8))
            }
        }
    }

    @Test func encodesAsPostgresTime() throws {
        let json = String(decoding: try ChoresJSON.encoder.encode(TimeOfDay(hour: 9, minute: 5)),
                          as: UTF8.self)
        #expect(json == "\"09:05:00\"")
    }

    @Test func ordersByHourThenMinute() {
        #expect(TimeOfDay(hour: 9, minute: 30) < TimeOfDay(hour: 10, minute: 0))
        #expect(TimeOfDay(hour: 10, minute: 0) < TimeOfDay(hour: 10, minute: 1))
    }

    @Test func readsTheWallClockInAZone() {
        // 18:05 UTC is 21:05 in Helsinki in September.
        let instant = ISO8601DateFormatter().date(from: "2026-09-21T18:05:00Z")!
        #expect(TimeOfDay(instant, in: helsinki) == TimeOfDay(hour: 21, minute: 5))
    }

    @Test func placesItselfOnADayInAZone() {
        let day = CalendarDay(year: 2026, month: 9, day: 21)
        let date = TimeOfDay(hour: 21, minute: 0).date(on: day, in: helsinki)
        #expect(date == ISO8601DateFormatter().date(from: "2026-09-21T18:00:00Z")!)
    }
}
