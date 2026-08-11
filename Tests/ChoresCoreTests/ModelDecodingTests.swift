import Testing
import Foundation
@testable import ChoresCore

@Suite struct ModelDecodingTests {

    @Test func decodesFamilyAndResolvesTimeZone() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","name":"Koti",
         "timezone":"Europe/Helsinki","created_at":"2026-08-10T09:00:00Z"}
        """
        let family = try ChoresJSON.decoder.decode(Family.self, from: Data(json.utf8))
        #expect(family.name == "Koti")
        #expect(family.timeZone.identifier == "Europe/Helsinki")
    }

    @Test func decodesProfileWithNullAuthUser() throws {
        let json = """
        {"id":"22222222-2222-2222-2222-222222222222",
         "family_id":"11111111-1111-1111-1111-111111111111",
         "auth_user_id":null,"display_name":"Kid","role":"child",
         "color":"#FF8800","sort_order":2,"created_at":"2026-08-10T09:00:00Z"}
        """
        let profile = try ChoresJSON.decoder.decode(Profile.self, from: Data(json.utf8))
        #expect(profile.authUserID == nil)
        #expect(profile.role == .child)
        #expect(profile.sortOrder == 2)
    }

    @Test func decodesCompletionDueOnAsCalendarDay() throws {
        let json = """
        {"id":"33333333-3333-3333-3333-333333333333",
         "family_id":"11111111-1111-1111-1111-111111111111",
         "profile_id":"22222222-2222-2222-2222-222222222222",
         "chore_id":"44444444-4444-4444-4444-444444444444",
         "due_on":"2026-08-11","completed_at":"2026-08-11T15:00:00Z",
         "completed_by":"22222222-2222-2222-2222-222222222222"}
        """
        let completion = try ChoresJSON.decoder.decode(Completion.self, from: Data(json.utf8))
        #expect(completion.dueOn == CalendarDay(year: 2026, month: 8, day: 11))
    }

    /// PostgREST returns timestamps with fractional seconds in some columns and
    /// without in others, so both shapes must decode.
    @Test func decodesTimestampsWithAndWithoutFractionalSeconds() throws {
        let withFraction = """
        {"id":"11111111-1111-1111-1111-111111111111","name":"Koti",
         "timezone":"Europe/Helsinki","created_at":"2026-08-10T09:00:00.123456Z"}
        """
        let withoutFraction = """
        {"id":"11111111-1111-1111-1111-111111111111","name":"Koti",
         "timezone":"Europe/Helsinki","created_at":"2026-08-10T09:00:00Z"}
        """
        #expect(throws: Never.self) {
            _ = try ChoresJSON.decoder.decode(Family.self, from: Data(withFraction.utf8))
        }
        #expect(throws: Never.self) {
            _ = try ChoresJSON.decoder.decode(Family.self, from: Data(withoutFraction.utf8))
        }
    }

    @Test func encodesScheduleEntryWithSnakeCaseKeys() throws {
        let entry = ScheduleEntry(
            id: UUID(), familyID: UUID(), profileID: UUID(), choreID: UUID(), weekday: 3)
        let json = String(decoding: try ChoresJSON.encoder.encode(entry), as: UTF8.self)
        #expect(json.contains("\"profile_id\""))
        #expect(json.contains("\"chore_id\""))
        #expect(!json.contains("\"profileID\""))
    }

    @Test func unknownTimezoneFallsBackRatherThanCrashing() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","name":"Koti",
         "timezone":"Mars/Olympus_Mons","created_at":"2026-08-10T09:00:00Z"}
        """
        let family = try ChoresJSON.decoder.decode(Family.self, from: Data(json.utf8))
        #expect(family.timeZone == .gmt)
    }
}
