# Parent Evening Push Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A parent gets a push notification at a time of their own choosing when a child in the family still has a chore for today that nobody has ticked off.

**Architecture:** The decision logic lives in Postgres — which parents are due, what counts as undone, and a claim row that makes a double-send impossible — and is tested with pgTAP. A `pg_cron` job every five minutes calls that SQL and, only when there is work, posts it to a Deno Edge Function that signs an APNs JWT and talks to Apple. The iOS app registers its device token through an RPC in parent mode, forgets it before any session ends, and lets each parent set or switch off their time from Manage.

**Tech Stack:** Postgres 17 (pgTAP, pg_cron, pg_net, Vault), Supabase Edge Functions (Deno 2, Web Crypto ES256), Swift 6 / SwiftUI (iOS 17+), `UNUserNotificationCenter`, APNs HTTP/2 token auth.

**Spec:** `docs/superpowers/specs/2026-09-17-parent-evening-push-design.md`. Sections referenced below as §N.

## Global Constraints

- Every migration is run by the project owner by hand (`supabase db push`); the plan never runs it. Local verification uses `supabase db reset && supabase test db`.
- Every user-facing string goes through `App/Chores/Localizable.xcstrings` with an `fi` value. The Finnish values in this plan are the spec's proposals.
- Shell commands in this plan use single quotes and no `cd` before `git`.
- Payload carries no names: `title-loc-key`, `loc-key`, one numeric `loc-arg`.
- Children's devices register no token, ever.
- Parent-only RPC guards raise `P0005`, matching `20260816100500_ways_out_sqlstate.sql`.
- Bundle id / APNs topic: `com.metsahalme.Chores`. Team id: `HPD6U8BLB5`.
- Unit tests: `swift test`. pgTAP: `supabase db reset && supabase test db` (needs Docker). UI tests: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' test`.
- Commit after every task with the `commit-commands:commit` skill; never push.

## File structure

**ChoresCore (Swift package)**

| File | Responsibility |
|---|---|
| `Sources/ChoresCore/Models/TimeOfDay.swift` *(new)* | Wall-clock time value: Codable as Postgres `time`, date arithmetic in a timezone |
| `Sources/ChoresCore/Models/Profile.swift` | Two new optional `TimeOfDay` fields |
| `Sources/ChoresCore/Notifications/PushEnvironment.swift` *(new)* | `development` / `production` |
| `Sources/ChoresCore/Notifications/PushRegistrar.swift` *(new)* | When to register or forget a token, independent of arrival order |
| `Sources/ChoresCore/Repositories/Repositories.swift` | Two new protocol methods |
| `Sources/ChoresCore/Repositories/InMemory/InMemoryChoresBackend.swift` | Token map, role defaults on insert, cascade |
| `Sources/ChoresCore/Repositories/Supabase/SupabaseChoresBackend.swift` | `ProfileUpdate` sends explicit nulls; two RPC calls |

**Database**

| File | Responsibility |
|---|---|
| `supabase/migrations/20260918100000_reminder_times.sql` | Columns on `profiles`, role-default trigger, backfill |
| `supabase/migrations/20260918100100_device_tokens.sql` | Table, select policy, grant, the two client RPCs |
| `supabase/migrations/20260918100200_evening_reminder.sql` | `evening_reminder_sends`, `family_undone_count`, `evening_reminder_work`, `evening_reminder_record`, `device_tokens_forget` |
| `supabase/migrations/20260918100300_evening_reminder_job.sql` | `pg_cron` + `pg_net`, the scheduled job |
| `supabase/tests/02_evening_reminder.sql` *(new)* | pgTAP for everything above |

**Edge Function**

| File | Responsibility |
|---|---|
| `supabase/functions/evening-reminder/apns.ts` *(new)* | Pure helpers: gateway, payload, outcome classification, JWT |
| `supabase/functions/evening-reminder/apns_test.ts` *(new)* | Deno tests for the helpers |
| `supabase/functions/evening-reminder/index.ts` *(new)* | The handler: auth, send, report back |
| `supabase/config.toml` | `verify_jwt = false` for the function |

**App**

| File | Responsibility |
|---|---|
| `App/Chores/Chores.entitlements` | `aps-environment` |
| `App/Chores/AppDelegate.swift` *(new)* | Receive the device token |
| `App/Chores/ChoresApp.swift` | Delegate adaptor, wire token to registrar |
| `App/Chores/Notifications.swift` *(new)* | The shared permission request |
| `App/Chores/AppEnvironment.swift` | Owns a `PushRegistrar` |
| `App/Chores/Parent/ParentRootView.swift` | Register on appear; forget in `perform`; hub row + destination |
| `App/Chores/Parent/EveningReminderView.swift` *(new)* | The settings screen |
| `App/Chores/DesignSystem/ReminderTimeControl.swift` *(new)* | Toggle + time picker bound to `TimeOfDay?` |
| `App/Chores/Kid/KidRootView.swift`, `App/Chores/Kid/ReminderScheduler.swift` | Use the shared permission request; comment |
| `App/Chores/Localizable.xcstrings` | Push keys and settings strings |
| `App/Chores/PrivacyInfo.xcprivacy` | Device ID |
| `App/ChoresUITests/EveningReminderUITests.swift` *(new)* | The settings screen round trip |

**Documents**

`docs/site/privacy/index.html`, `docs/site/privacy/fi/index.html`, `docs/RELEASING.md`.

---

### Task 1: `TimeOfDay` and the two fields on `Profile`

**Files:**
- Create: `Sources/ChoresCore/Models/TimeOfDay.swift`
- Modify: `Sources/ChoresCore/Models/Profile.swift`
- Test: `Tests/ChoresCoreTests/TimeOfDayTests.swift` (new), `Tests/ChoresCoreTests/ModelDecodingTests.swift`

**Interfaces:**
- Produces: `public struct TimeOfDay: Hashable, Sendable, Comparable, Codable { let hour: Int; let minute: Int; init(hour:minute:); init(_ date: Date, in: TimeZone); func date(on day: CalendarDay, in: TimeZone) -> Date }`
- Produces: `Profile.afternoonReminderAt: TimeOfDay?`, `Profile.eveningReminderAt: TimeOfDay?`, both defaulting to `nil` in `Profile.init`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ChoresCoreTests/TimeOfDayTests.swift`:

```swift
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
```

Add to `Tests/ChoresCoreTests/ModelDecodingTests.swift`, inside the suite:

```swift
    @Test func decodesProfileReminderTimes() throws {
        let json = """
        {"id":"22222222-2222-2222-2222-222222222222",
         "family_id":"11111111-1111-1111-1111-111111111111",
         "auth_user_id":null,"display_name":"Kid","role":"child",
         "color":"#FF8800","sort_order":2,"created_at":"2026-08-10T09:00:00Z",
         "afternoon_reminder_at":"15:00:00","evening_reminder_at":null}
        """
        let profile = try ChoresJSON.decoder.decode(Profile.self, from: Data(json.utf8))
        #expect(profile.afternoonReminderAt == TimeOfDay(hour: 15, minute: 0))
        #expect(profile.eveningReminderAt == nil)
    }

    /// A snapshot cached before the columns existed has no such keys. It must
    /// still open — it is what the app draws before the first refresh lands.
    @Test func decodesProfileWithoutReminderKeys() throws {
        let json = """
        {"id":"22222222-2222-2222-2222-222222222222",
         "family_id":"11111111-1111-1111-1111-111111111111",
         "auth_user_id":null,"display_name":"Kid","role":"child",
         "color":"#FF8800","sort_order":2,"created_at":"2026-08-10T09:00:00Z"}
        """
        let profile = try ChoresJSON.decoder.decode(Profile.self, from: Data(json.utf8))
        #expect(profile.afternoonReminderAt == nil)
        #expect(profile.eveningReminderAt == nil)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter 'TimeOfDayTests|ModelDecodingTests'`
Expected: compile error — `TimeOfDay` not found.

- [ ] **Step 3: Write `TimeOfDay`**

Create `Sources/ChoresCore/Models/TimeOfDay.swift`:

```swift
import Foundation

/// A wall-clock time with no date and no zone: when a reminder fires, in the
/// family's timezone. Encodes as Postgres `time` does — "HH:MM:SS" — and decodes
/// "HH:MM" too, so a hand-written value works as well as a stored one.
public struct TimeOfDay: Hashable, Sendable, Comparable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    /// The wall-clock time `date` shows in `timeZone`.
    public init(_ date: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: components.hour!, minute: components.minute!)
    }

    /// This time on `day`, in `timeZone`.
    public func date(on day: CalendarDay, in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = day.year
        components.month = day.month
        components.day = day.day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }
}

extension TimeOfDay: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let parts = raw.split(separator: ":")
        guard (2...3).contains(parts.count),
              let hour = Int(parts[0]), (0...23).contains(hour),
              let minute = Int(parts[1]), (0...59).contains(minute) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Expected HH:MM or HH:MM:SS, got \(raw)"))
        }
        self.init(hour: hour, minute: minute)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(format: "%02d:%02d:00", hour, minute))
    }
}
```

- [ ] **Step 4: Add the fields to `Profile`**

In `Sources/ChoresCore/Models/Profile.swift`, after `public var sortOrder: Int`:

```swift
    /// When this person's reminders fire, in the family's timezone; nil is off.
    /// A child has both — a local heads-up and a local nag. A parent has only
    /// the evening one, which is a push sent by the server. Defaults are filled
    /// by the database on insert, by role.
    public var afternoonReminderAt: TimeOfDay?
    public var eveningReminderAt: TimeOfDay?
```

Extend the initialiser signature and body:

```swift
    public init(id: UUID, familyID: UUID, authUserID: UUID? = nil, displayName: String,
                role: Role, color: String = "#4C8BF5", sortOrder: Int = 0,
                afternoonReminderAt: TimeOfDay? = nil, eveningReminderAt: TimeOfDay? = nil,
                createdAt: Date = .init()) {
        self.id = id
        self.familyID = familyID
        self.authUserID = authUserID
        self.displayName = displayName
        self.role = role
        self.color = color
        self.sortOrder = sortOrder
        self.afternoonReminderAt = afternoonReminderAt
        self.eveningReminderAt = eveningReminderAt
        self.createdAt = createdAt
    }
```

And two coding keys:

```swift
        case afternoonReminderAt = "afternoon_reminder_at"
        case eveningReminderAt = "evening_reminder_at"
```

Synthesised `Decodable` uses `decodeIfPresent` for optionals, which is what makes the cached-snapshot test pass without a hand-written decoder.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test`
Expected: all pass, including the two new suites' cases.

- [ ] **Step 6: Commit**

Use `commit-commands:commit` with only `Sources/ChoresCore/Models/TimeOfDay.swift`, `Sources/ChoresCore/Models/Profile.swift`, `Tests/ChoresCoreTests/TimeOfDayTests.swift`, `Tests/ChoresCoreTests/ModelDecodingTests.swift`. Suggested subject: `Give a profile two reminder times`.

---

### Task 2: `updateProfile` carries the times, and the in-memory backend fills role defaults

**Files:**
- Modify: `Sources/ChoresCore/Repositories/Supabase/SupabaseChoresBackend.swift:195-203` (`updateProfile`) and `:365-375` (`ProfileUpdate`)
- Modify: `Sources/ChoresCore/Repositories/InMemory/InMemoryChoresBackend.swift:97-110` (`createFamily`), `:153-166` (`addChild`, `addParent`)
- Test: `Tests/ChoresCoreTests/InMemoryBackendTests.swift`, `Tests/ChoresCoreTests/ModelDecodingTests.swift`

**Interfaces:**
- Consumes: `TimeOfDay`, `Profile.afternoonReminderAt`, `Profile.eveningReminderAt` (Task 1).
- Produces: `struct ProfileUpdate` (internal, no longer `private`) whose JSON always contains `afternoon_reminder_at` and `evening_reminder_at`, as a time string or `null`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ChoresCoreTests/ModelDecodingTests.swift`:

```swift
    /// PostgREST reads an omitted column as "leave it alone". Switching a
    /// reminder off has to send an explicit null, or it silently does nothing.
    @Test func profileUpdateEncodesNilReminderAsNull() throws {
        let update = ProfileUpdate(displayName: "Kid", color: "#FF8800", sortOrder: 1,
                                   afternoonReminderAt: TimeOfDay(hour: 15, minute: 0),
                                   eveningReminderAt: nil)
        let json = String(decoding: try ChoresJSON.encoder.encode(update), as: UTF8.self)
        #expect(json.contains("\"afternoon_reminder_at\":\"15:00:00\""))
        #expect(json.contains("\"evening_reminder_at\":null"))
    }
```

Add to `Tests/ChoresCoreTests/InMemoryBackendTests.swift` (a new suite at the bottom of the file is fine):

```swift
@Suite struct InMemoryReminderDefaultsTests {

    @Test func aNewParentGetsTheEveningDefaultOnly() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInWithApple(idToken: "apple-1", nonce: "n")
        _ = try await backend.createFamily(familyName: "Koti", parentName: "Parent",
                                           timezone: "Europe/Helsinki")
        let parent = try #require(try await backend.currentProfile())
        #expect(parent.eveningReminderAt == TimeOfDay(hour: 21, minute: 0))
        #expect(parent.afternoonReminderAt == nil)
    }

    @Test func aNewChildGetsBothDefaults() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInWithApple(idToken: "apple-1", nonce: "n")
        let familyID = try await backend.createFamily(familyName: "Koti", parentName: "Parent",
                                                      timezone: "Europe/Helsinki")
        let child = try await backend.addChild(familyID: familyID, name: "Kid",
                                               color: "#FF8800", sortOrder: 0)
        #expect(child.afternoonReminderAt == TimeOfDay(hour: 15, minute: 0))
        #expect(child.eveningReminderAt == TimeOfDay(hour: 20, minute: 0))
    }

    @Test func switchingAReminderOffPersistsAsNil() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInWithApple(idToken: "apple-1", nonce: "n")
        let familyID = try await backend.createFamily(familyName: "Koti", parentName: "Parent",
                                                      timezone: "Europe/Helsinki")
        var child = try await backend.addChild(familyID: familyID, name: "Kid",
                                               color: "#FF8800", sortOrder: 0)
        child.eveningReminderAt = nil
        try await backend.updateProfile(child)
        let snapshot = try await backend.fetchSnapshot(
            familyID: familyID, weekOf: CalendarDay(year: 2026, month: 9, day: 21))
        let stored = try #require(snapshot.profiles.first { $0.id == child.id })
        #expect(stored.eveningReminderAt == nil)
        #expect(stored.afternoonReminderAt == TimeOfDay(hour: 15, minute: 0))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter 'InMemoryReminderDefaultsTests|profileUpdateEncodesNilReminderAsNull'`
Expected: `ProfileUpdate` inaccessible / missing arguments; the two default assertions fail with `nil`.

- [ ] **Step 3: Rewrite `ProfileUpdate` and `updateProfile`**

In `SupabaseChoresBackend.swift` replace the `ProfileUpdate` struct with:

```swift
struct ProfileUpdate: Encodable {
    let displayName: String
    let color: String
    let sortOrder: Int
    let afternoonReminderAt: TimeOfDay?
    let eveningReminderAt: TimeOfDay?

    enum CodingKeys: String, CodingKey {
        case color
        case displayName = "display_name"
        case sortOrder = "sort_order"
        case afternoonReminderAt = "afternoon_reminder_at"
        case eveningReminderAt = "evening_reminder_at"
    }

    /// Hand-written so that nil becomes an explicit JSON null. The synthesised
    /// encoder omits a nil key, and PostgREST reads an omitted column as
    /// "leave it alone" — which would make switching a reminder off a no-op.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(color, forKey: .color)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(afternoonReminderAt, forKey: .afternoonReminderAt)
        try container.encode(eveningReminderAt, forKey: .eveningReminderAt)
    }
}
```

(`private` dropped so the test target can build one.) Update `updateProfile`:

```swift
    public func updateProfile(_ profile: Profile) async throws {
        try await run {
            let payload = ProfileUpdate(displayName: profile.displayName,
                                        color: profile.color,
                                        sortOrder: profile.sortOrder,
                                        afternoonReminderAt: profile.afternoonReminderAt,
                                        eveningReminderAt: profile.eveningReminderAt)
            _ = try await client
                .from("profiles").update(payload).eq("id", value: profile.id).execute()
        }
    }
```

- [ ] **Step 4: Mirror the database trigger in the in-memory backend**

In `InMemoryChoresBackend.swift`, `createFamily`:

```swift
        let parent = Profile(id: UUID(), familyID: family.id, authUserID: userID,
                             displayName: parentName, role: .parent,
                             eveningReminderAt: TimeOfDay(hour: 21, minute: 0))
```

`addChild`:

```swift
        let profile = Profile(id: UUID(), familyID: familyID, displayName: name,
                              role: .child, color: color, sortOrder: sortOrder,
                              afternoonReminderAt: TimeOfDay(hour: 15, minute: 0),
                              eveningReminderAt: TimeOfDay(hour: 20, minute: 0))
```

`addParent`:

```swift
        let profile = Profile(id: UUID(), familyID: familyID, displayName: name,
                              role: .parent, color: "#8E8E93", sortOrder: 0,
                              eveningReminderAt: TimeOfDay(hour: 21, minute: 0))
```

Add above `createFamily` a comment tying the three together:

```swift
    // The database fills reminder defaults by role in a BEFORE INSERT trigger
    // (20260918100000_reminder_times.sql). The three insert paths below fill the
    // same values, so a test here proves the same thing a pgTAP test proves.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test`
Expected: all pass.

- [ ] **Step 6: Commit**

`commit-commands:commit` with the two backend files and the two test files. Suggested subject: `Save reminder times, and send null when one is off`.

---

### Task 3: `ChoresBackend` learns to register and forget a device token

**Files:**
- Create: `Sources/ChoresCore/Notifications/PushEnvironment.swift`
- Modify: `Sources/ChoresCore/Repositories/Repositories.swift:100-105`
- Modify: `Sources/ChoresCore/Repositories/InMemory/InMemoryChoresBackend.swift` (Store, new methods, `deleteProfile`)
- Modify: `Sources/ChoresCore/Repositories/Supabase/SupabaseChoresBackend.swift` (two RPC calls)
- Modify: `Tests/ChoresCoreTests/TestDoubles.swift` (`ForwardingBackend`, `UnavailableBackend`)
- Test: `Tests/ChoresCoreTests/InMemoryBackendTests.swift`

**Interfaces:**
- Produces: `public enum PushEnvironment: String, Codable, Sendable { case development, production }`
- Produces on `ChoresBackend`: `func registerDeviceToken(_ token: String, environment: PushEnvironment) async throws` and `func forgetDeviceToken(_ token: String) async throws`
- Produces on `InMemoryChoresBackend`: `public struct DeviceTokenRecord: Equatable, Sendable { profileID, familyID, environment }` and `public func deviceTokens() -> [String: DeviceTokenRecord]` for assertions.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ChoresCoreTests/InMemoryBackendTests.swift`:

```swift
@Suite struct InMemoryDeviceTokenTests {

    func parentBackend() async throws -> (InMemoryChoresBackend, Profile) {
        let backend = InMemoryChoresBackend()
        try await backend.signInWithApple(idToken: "apple-1", nonce: "n")
        _ = try await backend.createFamily(familyName: "Koti", parentName: "Parent",
                                           timezone: "Europe/Helsinki")
        return (backend, try #require(try await backend.currentProfile()))
    }

    @Test func registeringRecordsTheCallersProfile() async throws {
        let (backend, parent) = try await parentBackend()
        try await backend.registerDeviceToken("abc123", environment: .development)
        let record = try #require(backend.deviceTokens()["abc123"])
        #expect(record.profileID == parent.id)
        #expect(record.familyID == parent.familyID)
        #expect(record.environment == .development)
    }

    @Test func aTokenFollowsTheDeviceToItsNewHolder() async throws {
        let (backend, first) = try await parentBackend()
        try await backend.registerDeviceToken("abc123", environment: .production)
        try await backend.signOut()

        // A different parent signs in on the same phone.
        try await backend.signInWithApple(idToken: "apple-2", nonce: "n")
        _ = try await backend.createFamily(familyName: "Toinen", parentName: "Other",
                                           timezone: "Europe/Helsinki")
        let second = try #require(try await backend.currentProfile())
        try await backend.registerDeviceToken("abc123", environment: .production)

        #expect(backend.deviceTokens()["abc123"]?.profileID == second.id)
        #expect(backend.deviceTokens().values.filter { $0.profileID == first.id }.isEmpty)
    }

    @Test func aChildCannotRegister() async throws {
        let backend = InMemoryChoresBackend()
        backend.seedClaimedChild(childName: "Kid", choreNames: ["Bins"], onISOWeekdays: [1])
        await #expect(throws: ChoresBackendError.notPermitted) {
            try await backend.registerDeviceToken("kid-token", environment: .development)
        }
        #expect(backend.deviceTokens().isEmpty)
    }

    @Test func forgettingRemovesOnlyTheCallersOwnRow() async throws {
        let (backend, _) = try await parentBackend()
        try await backend.registerDeviceToken("mine", environment: .production)
        try await backend.signOut()
        try await backend.signInWithApple(idToken: "apple-2", nonce: "n")
        _ = try await backend.createFamily(familyName: "Toinen", parentName: "Other",
                                           timezone: "Europe/Helsinki")

        try await backend.forgetDeviceToken("mine")   // not this caller's
        #expect(backend.deviceTokens()["mine"] != nil)

        try await backend.registerDeviceToken("theirs", environment: .production)
        try await backend.forgetDeviceToken("theirs")
        #expect(backend.deviceTokens()["theirs"] == nil)
    }

    @Test func deletingAProfileTakesItsTokens() async throws {
        let (backend, parent) = try await parentBackend()
        let child = try await backend.addChild(familyID: parent.familyID, name: "Kid",
                                               color: "#FF8800", sortOrder: 0)
        // Seat a token directly on the child to prove the cascade, since a child
        // cannot register one.
        backend.withStore { $0.deviceTokens["kid"] = InMemoryChoresBackend.DeviceTokenRecord(
            profileID: child.id, familyID: parent.familyID, environment: .development) }
        try await backend.deleteChild(profileID: child.id)
        #expect(backend.deviceTokens()["kid"] == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter InMemoryDeviceTokenTests`
Expected: compile errors — no such methods.

- [ ] **Step 3: Add the environment type and the protocol methods**

Create `Sources/ChoresCore/Notifications/PushEnvironment.swift`:

```swift
import Foundation

/// Which of Apple's two push gateways a device token belongs to. A token is
/// valid on exactly one: debug builds get sandbox tokens, anything archived —
/// TestFlight or the store — gets production ones.
public enum PushEnvironment: String, Codable, Sendable {
    case development
    case production
}
```

In `Repositories.swift`, after the `// MARK: Completions` methods, add:

```swift
    // MARK: Push

    /// Records this device's APNs token against the caller's own profile. The
    /// server derives profile and family from the session, and takes the token
    /// over from whoever held it before — a token proves possession of the
    /// phone. Parents only; a child device never has one.
    func registerDeviceToken(_ token: String, environment: PushEnvironment) async throws
    /// Removes the caller's own row for this token. Call it *before* ending a
    /// session: after sign-out there is no identity left to delete with.
    func forgetDeviceToken(_ token: String) async throws
```

- [ ] **Step 4: Implement in the in-memory backend**

In `InMemoryChoresBackend.swift`, add to `Store`:

```swift
        var deviceTokens: [String: DeviceTokenRecord] = [:]
```

Add after `ClaimCodeRecord`:

```swift
    public struct DeviceTokenRecord: Equatable, Sendable {
        public let profileID: UUID
        public let familyID: UUID
        public let environment: PushEnvironment

        public init(profileID: UUID, familyID: UUID, environment: PushEnvironment) {
            self.profileID = profileID
            self.familyID = familyID
            self.environment = environment
        }
    }
```

Add a `// MARK: Push` section before the closing brace:

```swift
    // MARK: Push

    public func registerDeviceToken(_ token: String, environment: PushEnvironment) async throws {
        guard let me = try await currentProfile(), me.role == .parent else {
            throw ChoresBackendError.notPermitted
        }
        withStore {
            $0.deviceTokens[token] = DeviceTokenRecord(
                profileID: me.id, familyID: me.familyID, environment: environment)
        }
    }

    public func forgetDeviceToken(_ token: String) async throws {
        guard let me = try await currentProfile() else { return }
        withStore { store in
            if store.deviceTokens[token]?.profileID == me.id {
                store.deviceTokens[token] = nil
            }
        }
    }

    /// For assertions: every registered token and who holds it.
    public func deviceTokens() -> [String: DeviceTokenRecord] {
        withStore { $0.deviceTokens }
    }
```

In `deleteProfile(_:in:)`, add after the claim-code line:

```swift
        store.deviceTokens = store.deviceTokens.filter { $0.value.profileID != id }
```

`withStore` is currently internal; the cascade test above calls it from the test target through `@testable import`, which is fine as is.

- [ ] **Step 5: Implement in the Supabase backend**

In `SupabaseChoresBackend.swift`, after `uncomplete`:

```swift
    // MARK: Push

    public func registerDeviceToken(_ token: String, environment: PushEnvironment) async throws {
        try await run {
            try await client
                .rpc("device_token_register",
                     params: ["p_token": token, "p_environment": environment.rawValue])
                .execute()
        }
    }

    public func forgetDeviceToken(_ token: String) async throws {
        try await run {
            try await client
                .rpc("device_token_forget", params: ["p_token": token])
                .execute()
        }
    }
```

- [ ] **Step 6: Keep the test doubles compiling**

In `TestDoubles.swift`, add to `ForwardingBackend`:

```swift
    func registerDeviceToken(_ token: String, environment: PushEnvironment) async throws {
        try await inner.registerDeviceToken(token, environment: environment)
    }
    func forgetDeviceToken(_ token: String) async throws {
        try await inner.forgetDeviceToken(token)
    }
```

and to `UnavailableBackend`:

```swift
    func registerDeviceToken(_ token: String, environment: PushEnvironment) async throws { throw error }
    func forgetDeviceToken(_ token: String) async throws { throw error }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test`
Expected: all pass. (`SupabaseErrorMapping` already maps `P0005` to `.notPermitted`; nothing to add there.)

- [ ] **Step 8: Commit**

`commit-commands:commit` with the six touched files. Suggested subject: `Let a parent's device register its push token`.

---

### Task 4: `PushRegistrar` — register when both halves have arrived, forget before a session ends

**Files:**
- Create: `Sources/ChoresCore/Notifications/PushRegistrar.swift`
- Test: `Tests/ChoresCoreTests/PushRegistrarTests.swift` (new)

**Interfaces:**
- Consumes: `ChoresBackend.registerDeviceToken(_:environment:)`, `forgetDeviceToken(_:)`, `PushEnvironment`, `Profile` (Task 3).
- Produces: `public actor PushRegistrar { init(backend:environment:); func tokenDidArrive(_ token: String) async; func parentDidAppear(_ profile: Profile) async; func sessionWillEnd() async }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ChoresCoreTests/PushRegistrarTests.swift`:

```swift
import Testing
import Foundation
@testable import ChoresCore

@Suite struct PushRegistrarTests {

    func signedInParent() async throws -> (InMemoryChoresBackend, Profile) {
        let backend = InMemoryChoresBackend()
        try await backend.signInWithApple(idToken: "apple-1", nonce: "n")
        _ = try await backend.createFamily(familyName: "Koti", parentName: "Parent",
                                           timezone: "Europe/Helsinki")
        return (backend, try #require(try await backend.currentProfile()))
    }

    @Test func registersOnceBothTokenAndParentAreKnown_tokenFirst() async throws {
        let (backend, parent) = try await signedInParent()
        let registrar = PushRegistrar(backend: backend, environment: .development)

        await registrar.tokenDidArrive("tok")
        #expect(backend.deviceTokens().isEmpty, "a token alone is not enough")

        await registrar.parentDidAppear(parent)
        #expect(backend.deviceTokens()["tok"]?.profileID == parent.id)
        #expect(backend.deviceTokens()["tok"]?.environment == .development)
    }

    @Test func registersOnceBothTokenAndParentAreKnown_parentFirst() async throws {
        let (backend, parent) = try await signedInParent()
        let registrar = PushRegistrar(backend: backend, environment: .production)

        await registrar.parentDidAppear(parent)
        #expect(backend.deviceTokens().isEmpty, "a parent alone is not enough")

        await registrar.tokenDidArrive("tok")
        #expect(backend.deviceTokens()["tok"]?.profileID == parent.id)
    }

    @Test func doesNotRepeatAnIdenticalRegistration() async throws {
        let (backend, parent) = try await signedInParent()
        let counting = CountingBackend(inner: backend)
        let registrar = PushRegistrar(backend: counting, environment: .production)

        await registrar.tokenDidArrive("tok")
        await registrar.parentDidAppear(parent)
        await registrar.parentDidAppear(parent)
        await registrar.tokenDidArrive("tok")

        #expect(counting.registerCalls == 1)
    }

    @Test func aChangedTokenIsRegisteredAgain() async throws {
        let (backend, parent) = try await signedInParent()
        let registrar = PushRegistrar(backend: backend, environment: .production)

        await registrar.parentDidAppear(parent)
        await registrar.tokenDidArrive("old")
        await registrar.tokenDidArrive("new")

        #expect(backend.deviceTokens()["new"]?.profileID == parent.id)
    }

    @Test func endingTheSessionForgetsTheTokenWhileTheIdentityStillExists() async throws {
        let (backend, parent) = try await signedInParent()
        let registrar = PushRegistrar(backend: backend, environment: .production)
        await registrar.tokenDidArrive("tok")
        await registrar.parentDidAppear(parent)

        await registrar.sessionWillEnd()
        #expect(backend.deviceTokens().isEmpty)
    }

    @Test func aParentReappearingAfterAnEndedSessionRegistersAgain() async throws {
        let (backend, parent) = try await signedInParent()
        let registrar = PushRegistrar(backend: backend, environment: .production)
        await registrar.tokenDidArrive("tok")
        await registrar.parentDidAppear(parent)
        await registrar.sessionWillEnd()

        // The sign-out failed, say, and the same parent is still here.
        await registrar.parentDidAppear(parent)
        #expect(backend.deviceTokens()["tok"]?.profileID == parent.id)
    }

    @Test func aRefusedRegistrationIsSwallowed() async throws {
        let (_, parent) = try await signedInParent()
        let registrar = PushRegistrar(backend: UnavailableBackend(), environment: .production)
        await registrar.tokenDidArrive("tok")
        await registrar.parentDidAppear(parent)
        // Reaching here without a throw is the assertion.
    }
}

/// Counts registrations so a test can prove a repeat was skipped.
final class CountingBackend: ForwardingBackend, @unchecked Sendable {
    private(set) var registerCalls = 0

    override func registerDeviceToken(_ token: String, environment: PushEnvironment) async throws {
        registerCalls += 1
        try await super.registerDeviceToken(token, environment: environment)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PushRegistrarTests`
Expected: compile error — `PushRegistrar` not found.

- [ ] **Step 3: Write `PushRegistrar`**

Create `Sources/ChoresCore/Notifications/PushRegistrar.swift`:

```swift
import Foundation

/// Decides when this device's APNs token is written to the server.
///
/// Two things have to be known first and they arrive in either order: the
/// token, which UIKit hands to the application delegate whenever it likes, and
/// the parent profile, which the session resolves. This holds whichever came
/// first and acts when the second arrives. It is an actor because those two
/// arrivals come from different tasks.
///
/// Kept in ChoresCore so the ordering rules are tested against the in-memory
/// backend; the UIKit glue that feeds it stays in the app target.
public actor PushRegistrar {
    private let backend: any ChoresBackend
    private let environment: PushEnvironment

    private var token: String?
    private var parent: Profile?
    /// What was last sent, so a repeat arrival does not hit the server again.
    private var registered: (token: String, profileID: UUID)?

    public init(backend: any ChoresBackend, environment: PushEnvironment) {
        self.backend = backend
        self.environment = environment
    }

    public func tokenDidArrive(_ token: String) async {
        self.token = token
        await registerIfReady()
    }

    /// Parent mode is on screen for this profile. Called on every launch into
    /// it, which is what makes a token that changed between launches reach the
    /// server.
    public func parentDidAppear(_ profile: Profile) async {
        parent = profile
        await registerIfReady()
    }

    /// The session is about to end — sign-out, leaving, or deleting the account.
    /// Must run *before* it does: afterwards there is no identity to delete
    /// with, and the phone would keep receiving a family it no longer shows.
    /// The token itself is kept; it belongs to the phone, not the session.
    public func sessionWillEnd() async {
        parent = nil
        registered = nil
        guard let token else { return }
        try? await backend.forgetDeviceToken(token)
    }

    private func registerIfReady() async {
        guard let token, let parent else { return }
        if let registered, registered.token == token, registered.profileID == parent.id {
            return
        }
        do {
            try await backend.registerDeviceToken(token, environment: environment)
            registered = (token, parent.id)
        } catch {
            // Offline, or refused. The next launch into parent mode tries again;
            // nothing else in the app depends on this having worked.
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test`
Expected: all pass.

- [ ] **Step 5: Commit**

`commit-commands:commit` with the two files. Suggested subject: `Register the push token once both halves have arrived`.

---

### Task 5: Migration — reminder times on `profiles`, with role defaults

**Files:**
- Create: `supabase/migrations/20260918100000_reminder_times.sql`
- Create: `supabase/tests/02_evening_reminder.sql`

**Interfaces:**
- Produces: columns `profiles.afternoon_reminder_at time`, `profiles.evening_reminder_at time`; trigger `profiles_default_reminders`.

- [ ] **Step 1: Write the failing pgTAP tests**

Create `supabase/tests/02_evening_reminder.sql`. The fixtures here are shared by Tasks 6–8, which append to this file; the dates are chosen so that `2026-09-21` is a Monday and Helsinki is on summer time (UTC+3).

```sql
-- The evening reminder: reminder times, device tokens, the nightly work.
--
-- Everything that decides whether a parent's phone buzzes lives in SQL, and a
-- wrong decision is silent — a family that is never reminded, or one that is
-- reminded twice. These assertions are the gate. Run with:
--   supabase db reset && supabase test db

begin;
set local search_path to public, extensions;

select plan(6);

-- ---------------------------------------------------------------------------
-- Helpers (same shape as 01_rls_and_rpcs.sql; each file is its own transaction)
-- ---------------------------------------------------------------------------

create schema tests;
grant usage on schema tests to authenticated;

create function tests.auth_as(p_uid uuid, p_anonymous boolean default false)
returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid::text,
                      'role', 'authenticated',
                      'is_anonymous', p_anonymous)::text, true);
end $$;

create function tests.as_admin() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

-- ---------------------------------------------------------------------------
-- Fixtures. Family A is in Helsinki (UTC+3 on 2026-09-21), family B in UTC.
-- 2026-09-21 is a Monday. Every schedule entry below is for Monday unless said.
-- ---------------------------------------------------------------------------

insert into auth.users (id) values
  ('a0000000-0000-0000-0000-000000000001'),  -- P1, parent, family A
  ('a0000000-0000-0000-0000-000000000002'),  -- P2, parent, family A, reminds at 23:30
  ('a0000000-0000-0000-0000-000000000003'),  -- C1, child,  family A
  ('b0000000-0000-0000-0000-000000000001');  -- PB, parent, family B

insert into public.families (id, name, timezone) values
  ('11111111-1111-1111-1111-111111111111', 'Family A', 'Europe/Helsinki'),
  ('22222222-2222-2222-2222-222222222222', 'Family B', 'UTC');

-- Inserted without reminder columns on purpose: the trigger is under test.
insert into public.profiles (id, family_id, auth_user_id, display_name, role) values
  ('aaaa0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'a0000000-0000-0000-0000-000000000001', 'P1', 'parent'),
  ('aaaa0000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   'a0000000-0000-0000-0000-000000000003', 'C1', 'child'),
  ('aaaa0000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111',
   null, 'C2', 'child'),
  ('bbbb0000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
   'b0000000-0000-0000-0000-000000000001', 'PB', 'parent'),
  ('bbbb0000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222',
   null, 'CB', 'child');

-- P2 provides an explicit time.
insert into public.profiles (id, family_id, auth_user_id, display_name, role, evening_reminder_at) values
  ('aaaa0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'a0000000-0000-0000-0000-000000000002', 'P2', 'parent', time '23:30');

insert into public.chores (id, family_id, name, is_archived) values
  ('cccc0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Bins',  false),
  ('cccc0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Old',   true),
  ('cccc0000-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222', 'B chore', false);

insert into public.schedule_entries (family_id, profile_id, chore_id, weekday) values
  -- C1: Bins on Monday and Tuesday, the archived chore on Monday.
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
   'cccc0000-0000-0000-0000-000000000001', 1),
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
   'cccc0000-0000-0000-0000-000000000001', 2),
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
   'cccc0000-0000-0000-0000-000000000002', 1),
  -- C2: Bins on Monday. The same chore on two children counts twice.
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000004',
   'cccc0000-0000-0000-0000-000000000001', 1),
  -- P1 put themselves on the schedule. A parent's own chores are not the child's.
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000001',
   'cccc0000-0000-0000-0000-000000000001', 1),
  -- Family B: the child has a chore on Monday; the parent put themselves on too.
  ('22222222-2222-2222-2222-222222222222', 'bbbb0000-0000-0000-0000-000000000002',
   'cccc0000-0000-0000-0000-000000000003', 1),
  ('22222222-2222-2222-2222-222222222222', 'bbbb0000-0000-0000-0000-000000000001',
   'cccc0000-0000-0000-0000-000000000003', 1);

-- ---------------------------------------------------------------------------
-- Reminder times: defaults by role, and who may change them
-- ---------------------------------------------------------------------------

select is(
  (select evening_reminder_at from public.profiles
     where id = 'aaaa0000-0000-0000-0000-000000000001'),
  time '21:00', 'a new parent reminds themselves at 21:00');

select is(
  (select afternoon_reminder_at from public.profiles
     where id = 'aaaa0000-0000-0000-0000-000000000001'),
  null::time, 'and has no afternoon reminder');

select is(
  (select (afternoon_reminder_at, evening_reminder_at)::text from public.profiles
     where id = 'aaaa0000-0000-0000-0000-000000000003'),
  '(15:00:00,20:00:00)', 'a new child gets 15:00 and 20:00');

select is(
  (select evening_reminder_at from public.profiles
     where id = 'aaaa0000-0000-0000-0000-000000000002'),
  time '23:30', 'a time given at insert is kept');

-- A child's UPDATE on their own row is filtered by the policy: zero rows, no error.
select tests.auth_as('a0000000-0000-0000-0000-000000000003');
with attempted as (
  update public.profiles set evening_reminder_at = null
   where id = 'aaaa0000-0000-0000-0000-000000000003'
  returning 1
)
select is((select count(*)::int from attempted), 0,
          'a child cannot change their own reminder times');

select tests.auth_as('a0000000-0000-0000-0000-000000000001');
select lives_ok(
  $$update public.profiles set evening_reminder_at = null
     where id = 'aaaa0000-0000-0000-0000-000000000001'$$,
  'a parent may switch their own reminder off');

-- Put it back for the tests that follow.
select tests.as_admin();
update public.profiles set evening_reminder_at = time '21:00'
 where id = 'aaaa0000-0000-0000-0000-000000000001';

select tests.as_admin();
select * from finish();
rollback;
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `supabase db reset && supabase test db`
Expected: `02_evening_reminder.sql` fails at the fixture insert — column `evening_reminder_at` does not exist.

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260918100000_reminder_times.sql`:

```sql
-- When each person's reminders fire, in the family's timezone.
--
-- Both columns are nullable and null means off. What they mean depends on the
-- role: a child has an afternoon heads-up and an evening nag, both scheduled
-- locally on the child's phone; a parent has only the evening one, which the
-- server sends as a push (20260918100200_evening_reminder.sql). A parent's
-- afternoon column is ignored.
--
-- Defaults come from a trigger rather than a column default because they differ
-- by role. Consequence, accepted: a profile is always created with reminders on
-- and switched off afterwards. There is no way to create one with them off,
-- which is what removes the ambiguity between "not provided" and "off".
--
-- See docs/superpowers/specs/2026-09-17-parent-evening-push-design.md §3.1.

alter table public.profiles
  add column afternoon_reminder_at time,
  add column evening_reminder_at   time;

create or replace function public.profiles_default_reminders()
returns trigger language plpgsql as $$
begin
  if new.role = 'parent' then
    new.evening_reminder_at   := coalesce(new.evening_reminder_at, time '21:00');
    new.afternoon_reminder_at := null;
  else
    new.afternoon_reminder_at := coalesce(new.afternoon_reminder_at, time '15:00');
    new.evening_reminder_at   := coalesce(new.evening_reminder_at,   time '20:00');
  end if;
  return new;
end $$;

create trigger profiles_default_reminders
  before insert on public.profiles
  for each row execute function public.profiles_default_reminders();

-- Everyone who already exists gets the same defaults the trigger would give.
update public.profiles
   set evening_reminder_at = coalesce(evening_reminder_at, time '21:00')
 where role = 'parent';

update public.profiles
   set afternoon_reminder_at = coalesce(afternoon_reminder_at, time '15:00'),
       evening_reminder_at   = coalesce(evening_reminder_at,   time '20:00')
 where role = 'child';

-- No policy or grant changes: profiles_update already lets a parent set these,
-- and profiles_select already lets everyone in the family read them.
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `supabase db reset && supabase test db`
Expected: both files pass; `02` reports 6/6.

- [ ] **Step 5: Commit**

`commit-commands:commit` with the migration and the test file. Suggested subject: `Store when each person is reminded`.

---

### Task 6: Migration — `device_tokens` and its two client RPCs

**Files:**
- Create: `supabase/migrations/20260918100100_device_tokens.sql`
- Modify: `supabase/tests/02_evening_reminder.sql`

**Interfaces:**
- Produces: table `device_tokens(token pk, family_id, profile_id, environment, updated_at)`; RPCs `device_token_register(p_token text, p_environment text)` and `device_token_forget(p_token text)` for `authenticated`.

- [ ] **Step 1: Append the failing tests**

In `supabase/tests/02_evening_reminder.sql`, change `select plan(6);` to `select plan(12);` and insert this block before the final `select tests.as_admin(); select * from finish();`:

```sql
-- ---------------------------------------------------------------------------
-- Device tokens: a token belongs to whoever holds the phone
-- ---------------------------------------------------------------------------

select tests.auth_as('a0000000-0000-0000-0000-000000000001');   -- P1
select lives_ok(
  $$select public.device_token_register('tok-p1-a', 'production')$$,
  'a parent may register their phone');
select public.device_token_register('tok-p1-b', 'development');

select tests.auth_as('b0000000-0000-0000-0000-000000000001');   -- PB
select public.device_token_register('tok-pb', 'production');

select tests.auth_as('a0000000-0000-0000-0000-000000000001');   -- P1 again
select is((select count(*)::int from public.device_tokens), 2,
          'a parent sees their own tokens and nobody else''s');

select tests.auth_as('a0000000-0000-0000-0000-000000000003');   -- C1
select throws_ok(
  $$select public.device_token_register('tok-kid', 'development')$$,
  'P0005', null, 'a child cannot register a token');
select is((select count(*)::int from public.device_tokens), 0,
          'and sees none');

-- P2 signs in on the phone that used to be P1's: the row moves.
select tests.auth_as('a0000000-0000-0000-0000-000000000002');   -- P2
select public.device_token_register('tok-p1-a', 'production');
select tests.as_admin();
select is(
  (select profile_id from public.device_tokens where token = 'tok-p1-a'),
  'aaaa0000-0000-0000-0000-000000000002'::uuid,
  'registering a token another parent held takes it over');

-- P1's late forget of the phone they no longer hold must not undo that.
select tests.auth_as('a0000000-0000-0000-0000-000000000001');   -- P1
select public.device_token_forget('tok-p1-a');
select tests.as_admin();
select is(
  (select profile_id from public.device_tokens where token = 'tok-p1-a'),
  'aaaa0000-0000-0000-0000-000000000002'::uuid,
  'forget removes only the caller''s own row');

-- Leave the fixtures as the later sections expect: P1 holds tok-p1-a and
-- tok-p1-b, P2 holds nothing, PB holds tok-pb.
select tests.auth_as('a0000000-0000-0000-0000-000000000002');   -- P2
select public.device_token_forget('tok-p1-a');
select tests.auth_as('a0000000-0000-0000-0000-000000000001');   -- P1
select public.device_token_register('tok-p1-a', 'production');
select tests.as_admin();
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `supabase db reset && supabase test db`
Expected: `02` fails — function `device_token_register` does not exist.

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260918100100_device_tokens.sql`:

```sql
-- One row per parent's phone: the APNs token the evening reminder is sent to.
--
-- The token is the primary key on purpose. Apple issues it per device and app,
-- so when a phone changes hands — one parent signs out, another signs in — the
-- row has to follow the phone, not stay with the previous person. That is why
-- clients do not write this table through RLS: a per-row policy would refuse
-- parent B's registration while parent A's row still held the token. Writes go
-- through two SECURITY DEFINER functions instead, and the token itself is the
-- proof of possession.
--
-- Children's devices never register. Their reminders are scheduled locally.
--
-- See docs/superpowers/specs/2026-09-17-parent-evening-push-design.md §4.1.

create table public.device_tokens (
  token       text primary key,
  family_id   uuid not null references public.families(id) on delete cascade,
  profile_id  uuid not null references public.profiles(id) on delete cascade,
  environment text not null check (environment in ('development', 'production')),
  updated_at  timestamptz not null default now()
);
create index device_tokens_profile_idx on public.device_tokens(profile_id);

alter table public.device_tokens enable row level security;

-- Read your own; nobody has a reason to read anyone else's.
create policy device_tokens_select on public.device_tokens for select
  using (profile_id = public.current_profile_id());

grant select on public.device_tokens to authenticated;

-- Registers the caller's phone, taking the token over from whoever held it.
create or replace function public.device_token_register(p_token text, p_environment text)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_profile public.profiles%rowtype;
begin
  select * into v_profile from public.profiles where auth_user_id = auth.uid();
  if v_profile.id is null or v_profile.role <> 'parent' then
    raise exception 'only a parent may register a device' using errcode = 'P0005';
  end if;

  insert into public.device_tokens (token, family_id, profile_id, environment)
  values (p_token, v_profile.family_id, v_profile.id, p_environment)
  on conflict (token) do update
    set family_id   = excluded.family_id,
        profile_id  = excluded.profile_id,
        environment = excluded.environment,
        updated_at  = now();
end $$;

-- Removes the caller's own row for this token, if it is theirs. Scoped to the
-- caller so a forget sent late from a phone's previous holder cannot remove
-- the new holder's registration.
create or replace function public.device_token_forget(p_token text)
returns void language sql security definer set search_path = public
as $$
  delete from public.device_tokens
   where token = p_token
     and profile_id = public.current_profile_id();
$$;

revoke execute on function public.device_token_register(text, text) from public, anon;
grant  execute on function public.device_token_register(text, text) to authenticated;
revoke execute on function public.device_token_forget(text) from public, anon;
grant  execute on function public.device_token_forget(text) to authenticated;
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `supabase db reset && supabase test db`
Expected: `02` reports 12/12.

- [ ] **Step 5: Commit**

`commit-commands:commit` with the migration and the test file. Suggested subject: `Keep the push token of a parent's phone`.

---

### Task 7: Migration — the evening's work in SQL

**Files:**
- Create: `supabase/migrations/20260918100200_evening_reminder.sql`
- Modify: `supabase/tests/02_evening_reminder.sql`

**Interfaces:**
- Produces: table `evening_reminder_sends`; functions `family_undone_count(uuid, date) -> int`, `evening_reminder_work(timestamptz default now()) -> setof (profile_id uuid, local_date date, undone_count int, token text, environment text)`, `evening_reminder_record(uuid, date, timestamptz, text)`, `device_tokens_forget(text[])`. All `service_role` only.
- The Edge Function (Task 9) consumes the row shape of `evening_reminder_work` verbatim as JSON.

- [ ] **Step 1: Append the failing tests**

Change `select plan(12);` to `select plan(43);` and insert before the final `finish()` block:

```sql
-- ---------------------------------------------------------------------------
-- What counts as undone
-- ---------------------------------------------------------------------------

select tests.as_admin();

select is(public.family_undone_count('11111111-1111-1111-1111-111111111111', date '2026-09-21'), 2,
          'undone counts each child''s open chores: the same chore on two children is two, an archived chore is not counted, a parent''s own entry is not counted');

insert into public.completions (family_id, profile_id, chore_id, due_on, completed_by) values
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
   'cccc0000-0000-0000-0000-000000000001', date '2026-09-21', 'aaaa0000-0000-0000-0000-000000000003');
select is(public.family_undone_count('11111111-1111-1111-1111-111111111111', date '2026-09-21'), 1,
          'a completion takes one off');

insert into public.completions (family_id, profile_id, chore_id, due_on, completed_by) values
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000004',
   'cccc0000-0000-0000-0000-000000000001', date '2026-09-21', 'aaaa0000-0000-0000-0000-000000000001');
select is(public.family_undone_count('11111111-1111-1111-1111-111111111111', date '2026-09-21'), 0,
          'a parent ticking on the child''s behalf counts the same');

select is(public.family_undone_count('11111111-1111-1111-1111-111111111111', date '2026-09-23'), 0,
          'a weekday with no entries has nothing undone');

-- Back to an unfinished Monday for the work() tests.
delete from public.completions where due_on = date '2026-09-21';

-- ---------------------------------------------------------------------------
-- The work: who is due, and the claim that stops a double-send
-- 18:05Z is 21:05 in Helsinki: P1 (21:00) is due, P2 (23:30) is not.
-- Family B is on UTC, so PB (21:00) is not due at 18:05Z.
-- ---------------------------------------------------------------------------

select is((select count(*)::int from public.evening_reminder_work(timestamptz '2026-09-21 17:55:00+00')), 0,
          'nobody is due at 20:55');
select is((select count(*)::int from public.evening_reminder_sends), 0,
          'and nothing was claimed');

select is((select count(*)::int from public.evening_reminder_work(timestamptz '2026-09-21 18:05:00+00')), 2,
          'at 21:05 P1 is due, once per device');
select is((select count(*)::int from public.evening_reminder_sends), 1,
          'one claim row per parent, not per device');
select is(
  (select (undone_count, device_count, sent_at is null)::text
     from public.evening_reminder_sends
    where profile_id = 'aaaa0000-0000-0000-0000-000000000001'
      and local_date = date '2026-09-21'),
  '(2,2,t)', 'the claim records the counts and is not yet sent');
select is((select count(*)::int from public.evening_reminder_sends
            where profile_id = 'bbbb0000-0000-0000-0000-000000000001'), 0,
          'a parent whose local clock says 18:05 is not due');
select is((select count(*)::int from public.evening_reminder_sends
            where profile_id = 'aaaa0000-0000-0000-0000-000000000002'), 0,
          'a parent set to 23:30 is not due at 21:05');

select is((select count(*)::int from public.evening_reminder_work(timestamptz '2026-09-21 18:10:00+00')), 0,
          'the next tick finds P1 already claimed and returns nothing');

-- PB, on UTC: after the hour is too late; inside it is fine.
select is((select count(*)::int from public.evening_reminder_work(timestamptz '2026-09-21 22:05:00+00')), 0,
          'an hour after their time a parent is no longer due');
select is((select count(*)::int from public.evening_reminder_work(timestamptz '2026-09-21 21:10:00+00')), 1,
          'PB is due at 21:10 UTC');
select is((select token from public.evening_reminder_work(timestamptz '2026-09-21 21:10:00+00')), null::text,
          'and only once');

-- P2 at 23:30, no phone registered: claimed, recorded with no devices, nothing returned.
select is((select count(*)::int from public.evening_reminder_work(timestamptz '2026-09-21 20:45:00+00')), 0,
          'a due parent with no phone returns no work');
select is(
  (select device_count from public.evening_reminder_sends
    where profile_id = 'aaaa0000-0000-0000-0000-000000000002'
      and local_date = date '2026-09-21'),
  0, 'but is recorded with zero devices, so the absence can be explained');

-- The window is clipped at midnight: 21:10Z is 00:10 on the 22nd in Helsinki.
-- Tuesday has an unfinished chore too, so only the window can say no.
select is((select count(*)::int from public.evening_reminder_work(timestamptz '2026-09-21 21:10:00+00')), 0,
          'a 23:30 window does not spill into the next day');
select is((select count(*)::int from public.evening_reminder_sends
            where profile_id = 'aaaa0000-0000-0000-0000-000000000002'), 1,
          'and no claim was made for the 22nd');

-- Switched off means never due. Clear P1's claim so the window is open again.
update public.profiles set evening_reminder_at = null
 where id = 'aaaa0000-0000-0000-0000-000000000001';
delete from public.evening_reminder_sends
 where profile_id = 'aaaa0000-0000-0000-0000-000000000001';
select is((select count(*)::int from public.evening_reminder_work(timestamptz '2026-09-21 18:05:00+00')), 0,
          'a parent with the reminder off is never due');
update public.profiles set evening_reminder_at = time '21:00'
 where id = 'aaaa0000-0000-0000-0000-000000000001';

-- A finished day is nothing to say. Complete everything, then P1 is due but not claimed.
insert into public.completions (family_id, profile_id, chore_id, due_on, completed_by) values
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
   'cccc0000-0000-0000-0000-000000000001', date '2026-09-21', 'aaaa0000-0000-0000-0000-000000000003'),
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000004',
   'cccc0000-0000-0000-0000-000000000001', date '2026-09-21', 'aaaa0000-0000-0000-0000-000000000004');
select is((select count(*)::int from public.evening_reminder_work(timestamptz '2026-09-21 18:05:00+00')), 0,
          'a family whose day is done gets no reminder');
select is((select count(*)::int from public.evening_reminder_sends
            where profile_id = 'aaaa0000-0000-0000-0000-000000000001'), 0,
          'and no claim row either');
delete from public.completions where due_on = date '2026-09-21';

-- ---------------------------------------------------------------------------
-- Reporting back
-- ---------------------------------------------------------------------------

select public.evening_reminder_record(
  'bbbb0000-0000-0000-0000-000000000001', date '2026-09-21',
  timestamptz '2026-09-21 21:10:04+00', null);
select is(
  (select (sent_at, failure)::text from public.evening_reminder_sends
    where profile_id = 'bbbb0000-0000-0000-0000-000000000001'),
  '("2026-09-21 21:10:04+00",)', 'record() marks the claim sent');

select public.evening_reminder_record(
  'aaaa0000-0000-0000-0000-000000000002', date '2026-09-21', null, 'apns 403');
select is(
  (select failure from public.evening_reminder_sends
    where profile_id = 'aaaa0000-0000-0000-0000-000000000002'),
  'apns 403', 'record() keeps a failure where it can be read');

select public.device_tokens_forget(array['tok-pb', 'never-existed']);
select is((select count(*)::int from public.device_tokens where token = 'tok-pb'), 0,
          'forget() removes the tokens Apple called dead');
select is((select count(*)::int from public.device_tokens), 2,
          'and leaves the others');

-- ---------------------------------------------------------------------------
-- None of this is reachable from a phone
-- ---------------------------------------------------------------------------

select tests.auth_as('a0000000-0000-0000-0000-000000000001');
select throws_ok($$select public.evening_reminder_work()$$, '42501', null,
                 'a signed-in user cannot run the work');
select throws_ok($$select public.family_undone_count('11111111-1111-1111-1111-111111111111', current_date)$$,
                 '42501', null, 'nor count another family''s undone chores');
select throws_ok($$select public.evening_reminder_record('aaaa0000-0000-0000-0000-000000000001', current_date, now(), null)$$,
                 '42501', null, 'nor mark a send');
select throws_ok($$select public.device_tokens_forget(array['tok-p1-a'])$$, '42501', null,
                 'nor forget tokens wholesale');
-- No grant on the table at all, so this is a refusal rather than an empty result.
select throws_ok($$select count(*) from public.evening_reminder_sends$$, '42501', null,
                 'and cannot read the log');
select tests.as_admin();
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `supabase db reset && supabase test db`
Expected: `02` fails — `family_undone_count` does not exist.

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260918100200_evening_reminder.sql`:

```sql
-- The evening reminder, decided in SQL.
--
-- A parent is due when their family's local clock has passed their own
-- evening_reminder_at, for an hour. If the family's day is unfinished — some
-- child still has a scheduled chore with no completion for today — a claim row
-- is written and the parent's phones are returned to whoever will do the
-- sending. The claim comes *before* the send: a second run in the same hour
-- finds it and returns nothing, so a reminder can never arrive twice. The cost
-- is that a send which fails after claiming is not retried that evening; it
-- sits in the table with `failure` set, where it can be read.
--
-- Every function here runs as the service role only. Phones reach none of it.
--
-- See docs/superpowers/specs/2026-09-17-parent-evening-push-design.md §4.2, §5.

create table public.evening_reminder_sends (
  profile_id   uuid not null references public.profiles(id) on delete cascade,
  local_date   date not null,
  claimed_at   timestamptz not null default now(),
  sent_at      timestamptz,
  undone_count int  not null,
  device_count int  not null,
  failure      text,
  primary key (profile_id, local_date)
);

-- Enabled with no policies: nothing a phone can do reaches this table.
alter table public.evening_reminder_sends enable row level security;

-- How many of a family's scheduled chores for `p_date` no child has ticked off.
-- Its own function so pgTAP can test the rule in isolation, and so a future
-- per-child push could reuse it.
create or replace function public.family_undone_count(p_family_id uuid, p_date date)
returns int language sql stable security definer set search_path = public
as $$
  select count(*)::int
    from public.schedule_entries se
    join public.chores   c on c.id = se.chore_id and not c.is_archived
    join public.profiles p on p.id = se.profile_id and p.role = 'child'
   where se.family_id = p_family_id
     and se.weekday = extract(isodow from p_date)
     and not exists (select 1 from public.completions co
                      where co.profile_id = se.profile_id
                        and co.chore_id   = se.chore_id
                        and co.due_on     = p_date);
$$;

-- Claims every parent who is due right now, then returns their phones.
-- `p_now` is a parameter so the window can be tested; the job passes nothing.
create or replace function public.evening_reminder_work(p_now timestamptz default now())
returns table (profile_id uuid, local_date date, undone_count int, token text, environment text)
language plpgsql security definer set search_path = public
as $$
-- The RETURNS TABLE columns are also PL/pgSQL variables, and an unqualified
-- `profile_id` in the query below would be ambiguous between the two. Every
-- reference is qualified anyway; this makes the column win if one is missed.
#variable_conflict use_column
begin
  return query
  with due as (
    select p.id                                       as profile_id,
           (p_now at time zone f.timezone)::date      as local_date,
           f.id                                       as family_id
      from public.profiles p
      join public.families f on f.id = p.family_id
     where p.role = 'parent'
       and p.evening_reminder_at is not null
       -- The hour after the configured time, on timestamps rather than times so
       -- a 23:30 setting is clipped at midnight instead of wrapping.
       and (p_now at time zone f.timezone)
             >= (p_now at time zone f.timezone)::date + p.evening_reminder_at
       and (p_now at time zone f.timezone)
             <  (p_now at time zone f.timezone)::date + p.evening_reminder_at + interval '1 hour'
       and not exists (select 1 from public.evening_reminder_sends s
                        where s.profile_id = p.id
                          and s.local_date = (p_now at time zone f.timezone)::date)
  ),
  claimed as (
    insert into public.evening_reminder_sends (profile_id, local_date, undone_count, device_count)
    select d.profile_id,
           d.local_date,
           public.family_undone_count(d.family_id, d.local_date),
           (select count(*) from public.device_tokens t where t.profile_id = d.profile_id)
      from due d
     where public.family_undone_count(d.family_id, d.local_date) > 0
    returning evening_reminder_sends.profile_id,
              evening_reminder_sends.local_date,
              evening_reminder_sends.undone_count
  )
  select c.profile_id, c.local_date, c.undone_count, t.token, t.environment
    from claimed c
    join public.device_tokens t on t.profile_id = c.profile_id;
end $$;

-- The sender's report: when it went, or why it did not.
create or replace function public.evening_reminder_record(
  p_profile_id uuid, p_local_date date, p_sent_at timestamptz, p_failure text)
returns void language sql security definer set search_path = public
as $$
  update public.evening_reminder_sends
     set sent_at = p_sent_at, failure = p_failure
   where profile_id = p_profile_id and local_date = p_local_date;
$$;

-- Tokens Apple reported dead. Without this they accumulate forever and every
-- evening pays for them.
create or replace function public.device_tokens_forget(p_tokens text[])
returns void language sql security definer set search_path = public
as $$
  delete from public.device_tokens where token = any(p_tokens);
$$;

-- Service role only. Functions are executable by PUBLIC unless told otherwise,
-- and PostgREST would expose them to every signed-in phone.
revoke execute on function public.family_undone_count(uuid, date)                  from public, anon, authenticated;
revoke execute on function public.evening_reminder_work(timestamptz)                from public, anon, authenticated;
revoke execute on function public.evening_reminder_record(uuid, date, timestamptz, text) from public, anon, authenticated;
revoke execute on function public.device_tokens_forget(text[])                      from public, anon, authenticated;
grant  execute on function public.family_undone_count(uuid, date)                  to service_role;
grant  execute on function public.evening_reminder_work(timestamptz)                to service_role;
grant  execute on function public.evening_reminder_record(uuid, date, timestamptz, text) to service_role;
grant  execute on function public.device_tokens_forget(text[])                      to service_role;
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `supabase db reset && supabase test db`
Expected: `02` reports 43/43. If the `'("2026-09-21 21:10:04+00",)'` comparison fails on the timestamp's text form, replace that assertion with two: `sent_at = timestamptz '2026-09-21 21:10:04+00'` via `is(...)` and `failure is null` via `is(..., null::text, ...)`.

- [ ] **Step 5: Commit**

`commit-commands:commit` with the migration and the test file. Suggested subject: `Decide the evening reminder in SQL, and claim before sending`.

---

### Task 8: Migration — the five-minute job

**Files:**
- Create: `supabase/migrations/20260918100300_evening_reminder_job.sql`
- Modify: `supabase/tests/02_evening_reminder.sql`

**Interfaces:**
- Consumes: `evening_reminder_work()` (Task 7); Vault secrets `evening_reminder_url` and `evening_reminder_secret` (created by hand, Task 12's RELEASING section).
- Produces: `cron.job` named `evening-reminder`.

- [ ] **Step 1: Append the failing test**

Change `select plan(43);` to `select plan(44);` and insert before the final `finish()` block:

```sql
-- ---------------------------------------------------------------------------
-- The job exists
-- ---------------------------------------------------------------------------

select tests.as_admin();
select is(
  (select schedule from cron.job where jobname = 'evening-reminder'),
  '*/5 * * * *', 'the evening reminder runs every five minutes');
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `supabase db reset && supabase test db`
Expected: `02` fails — relation `cron.job` does not exist (or zero rows).

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260918100300_evening_reminder_job.sql`:

```sql
-- Every five minutes: claim what is due and, only if there is any, hand it to
-- the Edge Function that talks to Apple.
--
-- Most ticks find nothing and stop at the query. The function URL and the
-- bearer secret it expects come from Vault at run time, so this file holds
-- nothing sensitive and the same job works locally and hosted. Seeding the two
-- Vault entries is a once-per-project step; docs/RELEASING.md has it. Until
-- they exist the job runs, claims, and posts nowhere — the null guard below —
-- which is visible as claim rows with sent_at null.
--
-- `materialized` because work() has side effects and is named twice; it must
-- run exactly once per tick.

create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net  with schema extensions;

select cron.schedule('evening-reminder', '*/5 * * * *', $job$
  with work as materialized (
    select * from public.evening_reminder_work()
  ),
  target as (
    select (select decrypted_secret from vault.decrypted_secrets
             where name = 'evening_reminder_url')    as url,
           (select decrypted_secret from vault.decrypted_secrets
             where name = 'evening_reminder_secret') as secret
  )
  select net.http_post(
           url     := target.url,
           headers := jsonb_build_object(
                        'Content-Type',  'application/json',
                        'Authorization', 'Bearer ' || target.secret),
           body    := jsonb_build_object('work', (select jsonb_agg(to_jsonb(w)) from work w)))
    from target
   where exists (select 1 from work)
     and target.url is not null
     and target.secret is not null;
$job$);
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `supabase db reset && supabase test db`
Expected: `02` reports 44/44. If `create extension pg_cron with schema pg_catalog` is refused locally, drop the `with schema` clause — the hosted platform accepts either.

- [ ] **Step 5: Commit**

`commit-commands:commit` with the migration and the test file. Suggested subject: `Run the evening reminder every five minutes`.

---

### Task 9: The Edge Function

**Files:**
- Create: `supabase/functions/evening-reminder/apns.ts`
- Create: `supabase/functions/evening-reminder/apns_test.ts`
- Create: `supabase/functions/evening-reminder/index.ts`
- Modify: `supabase/config.toml` (append a `[functions.evening-reminder]` table)

**Interfaces:**
- Consumes: the JSON body `{ work: WorkRow[] }` that Task 8's job posts, `WorkRow = { profile_id, local_date, undone_count, token, environment }`; RPCs `evening_reminder_record` and `device_tokens_forget` (Task 7).
- Consumes secrets: `EVENING_REMINDER_SECRET`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`, plus the platform-provided `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`.
- Produces: string catalog keys the device must know — `EVENING_PUSH_TITLE`, `EVENING_PUSH_BODY_ONE`, `EVENING_PUSH_BODY_MANY` (added in Task 11).

- [ ] **Step 1: Write the failing Deno tests**

Create `supabase/functions/evening-reminder/apns_test.ts`:

```ts
import { assertEquals } from "jsr:@std/assert@1";
import {
  bodyKey,
  classify,
  gateway,
  jwtClaims,
  jwtHeader,
  payload,
  TOPIC,
} from "./apns.ts";

Deno.test("one chore uses the singular key, more the plural", () => {
  assertEquals(bodyKey(1), "EVENING_PUSH_BODY_ONE");
  assertEquals(bodyKey(2), "EVENING_PUSH_BODY_MANY");
  assertEquals(bodyKey(7), "EVENING_PUSH_BODY_MANY");
});

Deno.test("the payload carries keys and a count, never a name", () => {
  const p = payload(3) as { aps: { alert: Record<string, unknown>; sound: string } };
  assertEquals(p.aps.alert["title-loc-key"], "EVENING_PUSH_TITLE");
  assertEquals(p.aps.alert["loc-key"], "EVENING_PUSH_BODY_MANY");
  assertEquals(p.aps.alert["loc-args"], ["3"]);
  assertEquals(p.aps.sound, "default");
  assertEquals(Object.keys(p.aps.alert).length, 3);
});

Deno.test("410, and 400 BadDeviceToken, mean the token is dead", () => {
  assertEquals(classify(200, undefined), "delivered");
  assertEquals(classify(410, "Unregistered"), "dead");
  assertEquals(classify(400, "BadDeviceToken"), "dead");
});

Deno.test("anything else is a failure to report, not a token to drop", () => {
  assertEquals(classify(400, "BadTopic"), "failed");
  assertEquals(classify(403, "InvalidProviderToken"), "failed");
  assertEquals(classify(429, "TooManyRequests"), "failed");
  assertEquals(classify(503, undefined), "failed");
});

Deno.test("development tokens go to the sandbox gateway", () => {
  assertEquals(gateway("development"), "https://api.sandbox.push.apple.com");
  assertEquals(gateway("production"), "https://api.push.apple.com");
});

Deno.test("the JWT names the key and the team", () => {
  assertEquals(jwtHeader("KEY123"), { alg: "ES256", kid: "KEY123" });
  assertEquals(jwtClaims("HPD6U8BLB5", 1_700_000_000), { iss: "HPD6U8BLB5", iat: 1_700_000_000 });
});

Deno.test("the topic is the bundle id", () => {
  assertEquals(TOPIC, "com.metsahalme.Chores");
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `deno test supabase/functions/evening-reminder/`
Expected: module not found — `./apns.ts`.

- [ ] **Step 3: Write the helpers**

Create `supabase/functions/evening-reminder/apns.ts`:

```ts
// Everything about talking to Apple that does not need a network: kept apart
// from index.ts so it can be tested with `deno test` and nothing else.

export type Environment = "development" | "production";

/** One row of evening_reminder_work(), exactly as Postgres serialises it. */
export interface WorkRow {
  profile_id: string;
  local_date: string; // YYYY-MM-DD
  undone_count: number;
  token: string;
  environment: Environment;
}

export const TOPIC = "com.metsahalme.Chores";

export function gateway(environment: Environment): string {
  return environment === "development"
    ? "https://api.sandbox.push.apple.com"
    : "https://api.push.apple.com";
}

/**
 * loc-args are strings, so the device cannot choose a plural form from them.
 * The server chooses the key; the device renders it in its own language.
 */
export function bodyKey(undone: number): string {
  return undone === 1 ? "EVENING_PUSH_BODY_ONE" : "EVENING_PUSH_BODY_MANY";
}

/** Three keys and a number. No names cross this boundary. */
export function payload(undone: number): Record<string, unknown> {
  return {
    aps: {
      alert: {
        "title-loc-key": "EVENING_PUSH_TITLE",
        "loc-key": bodyKey(undone),
        "loc-args": [String(undone)],
      },
      sound: "default",
    },
  };
}

export type Outcome = "delivered" | "dead" | "failed";

/**
 * 410 is Apple saying the token no longer exists. 400 BadDeviceToken is the
 * same fact for a token registered against the wrong gateway — a debug build's
 * token sent to production, say. Both mean: stop sending to it. Everything
 * else is our problem or Apple's, and the token stays.
 */
export function classify(status: number, reason: string | undefined): Outcome {
  if (status === 200) return "delivered";
  if (status === 410) return "dead";
  if (status === 400 && reason === "BadDeviceToken") return "dead";
  return "failed";
}

export function jwtHeader(keyID: string) {
  return { alg: "ES256", kid: keyID };
}

export function jwtClaims(teamID: string, issuedAt: number) {
  return { iss: teamID, iat: issuedAt };
}

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** The .p8 Apple hands out is PKCS#8 PEM; Web Crypto wants the DER inside. */
export async function importKey(pem: string): Promise<CryptoKey> {
  const body = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

/** ES256 over header.claims. Web Crypto's ECDSA output is already r‖s, which is what JWS wants. */
export async function signJWT(
  key: CryptoKey,
  keyID: string,
  teamID: string,
  issuedAt: number,
): Promise<string> {
  const encoder = new TextEncoder();
  const header = base64url(encoder.encode(JSON.stringify(jwtHeader(keyID))));
  const claims = base64url(encoder.encode(JSON.stringify(jwtClaims(teamID, issuedAt))));
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    encoder.encode(`${header}.${claims}`),
  );
  return `${header}.${claims}.${base64url(new Uint8Array(signature))}`;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `deno test supabase/functions/evening-reminder/`
Expected: 7 passed.

- [ ] **Step 5: Write the handler**

Create `supabase/functions/evening-reminder/index.ts`:

```ts
// The evening reminder's sender. Called by the pg_cron job with the rows
// evening_reminder_work() claimed; signs an APNs token, posts one alert per
// device, and reports back through two service-role RPCs. Nothing here decides
// who is due — that is SQL's job and pgTAP's to test.

import { createClient } from "npm:@supabase/supabase-js@2";
import {
  classify,
  gateway,
  importKey,
  type Outcome,
  payload,
  signJWT,
  TOPIC,
  type WorkRow,
} from "./apns.ts";

const SECRET = Deno.env.get("EVENING_REMINDER_SECRET") ?? "";
const KEY_ID = Deno.env.get("APNS_KEY_ID") ?? "";
const TEAM_ID = Deno.env.get("APNS_TEAM_ID") ?? "";
const PRIVATE_KEY = Deno.env.get("APNS_PRIVATE_KEY") ?? "";

// Apple honours a provider token for an hour and rate-limits minting them, so
// one is kept for as long as this instance stays warm.
let cached: { jwt: string; issuedAt: number } | null = null;

async function providerToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cached && now - cached.issuedAt < 50 * 60) return cached.jwt;
  const key = await importKey(PRIVATE_KEY);
  cached = { jwt: await signJWT(key, KEY_ID, TEAM_ID, now), issuedAt: now };
  return cached.jwt;
}

function constantTimeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

async function send(row: WorkRow, jwt: string): Promise<{ outcome: Outcome; status: number }> {
  const response = await fetch(`${gateway(row.environment)}/3/device/${row.token}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${jwt}`,
      "apns-topic": TOPIC,
      "apns-push-type": "alert",
      "apns-priority": "10",
      // A phone that is off overnight should not get yesterday's reminder at breakfast.
      "apns-expiration": String(Math.floor(Date.now() / 1000) + 3 * 3600),
    },
    body: JSON.stringify(payload(row.undone_count)),
  });
  let reason: string | undefined;
  if (response.status === 200) {
    await response.body?.cancel();
  } else {
    try {
      reason = (await response.json() as { reason?: string }).reason;
    } catch {
      // No body, or not JSON. The status alone decides.
    }
  }
  return { outcome: classify(response.status, reason), status: response.status };
}

Deno.serve(async (request) => {
  const auth = request.headers.get("authorization") ?? "";
  if (SECRET === "" || !constantTimeEqual(auth, `Bearer ${SECRET}`)) {
    return new Response("unauthorized", { status: 401 });
  }

  const { work } = await request.json() as { work: WorkRow[] | null };
  if (!work || work.length === 0) {
    return Response.json({ sent: 0, dead: 0 });
  }

  const jwt = await providerToken();
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // Grouped by claim, because record() is per (parent, date) and a parent
  // may have more than one phone.
  const claims = new Map<string, { row: WorkRow; delivered: number; failures: number[] }>();
  const dead: string[] = [];

  for (const row of work) {
    const key = `${row.profile_id}|${row.local_date}`;
    const claim = claims.get(key) ?? { row, delivered: 0, failures: [] };
    const { outcome, status } = await send(row, jwt);
    if (outcome === "delivered") claim.delivered += 1;
    else if (outcome === "dead") dead.push(row.token);
    else claim.failures.push(status);
    claims.set(key, claim);
  }

  if (dead.length > 0) {
    await supabase.rpc("device_tokens_forget", { p_tokens: dead });
  }

  for (const { row, delivered, failures } of claims.values()) {
    const failure = delivered > 0
      ? null
      : failures.length > 0
      ? `apns ${failures.join(",")}`
      : "no live device";
    await supabase.rpc("evening_reminder_record", {
      p_profile_id: row.profile_id,
      p_local_date: row.local_date,
      p_sent_at: delivered > 0 ? new Date().toISOString() : null,
      p_failure: failure,
    });
  }

  return Response.json({ sent: work.length, dead: dead.length });
});
```

- [ ] **Step 6: Turn off Supabase's own JWT check for this function**

Append to `supabase/config.toml`:

```toml
# The evening reminder is called by the pg_cron job with its own bearer secret,
# not by a signed-in user, so the platform's JWT check would only refuse it.
[functions.evening-reminder]
verify_jwt = false
```

- [ ] **Step 7: Verify it serves**

Run: `supabase functions serve evening-reminder --no-verify-jwt` in one terminal and, in another:

`curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:54321/functions/v1/evening-reminder -H 'Content-Type: application/json' -d '{"work":[]}'`

Expected: `401` (no bearer). Then with `-H 'Authorization: Bearer x'` and `EVENING_REMINDER_SECRET=x` in `supabase/functions/.env`: `200` and the body `{"sent":0,"dead":0}`. Stop the server.

- [ ] **Step 8: Commit**

`commit-commands:commit` with the three function files and `supabase/config.toml`. Suggested subject: `Send the evening reminder through APNs`.

---

### Task 10: The app registers in parent mode and forgets before a session ends

**Files:**
- Modify: `App/Chores/Chores.entitlements`
- Create: `App/Chores/AppDelegate.swift`
- Create: `App/Chores/Notifications.swift`
- Modify: `App/Chores/ChoresApp.swift`
- Modify: `App/Chores/AppEnvironment.swift:6-17`
- Modify: `App/Chores/Parent/ParentRootView.swift:60` (`.task`), `:328-337` (`perform`)
- Modify: `App/Chores/Kid/KidRootView.swift:30-37`
- Modify: `App/Chores/Kid/ReminderScheduler.swift:1-17`

**Interfaces:**
- Consumes: `PushRegistrar` (Task 4), `PushEnvironment` (Task 3).
- Produces: `AppEnvironment.pushRegistrar: PushRegistrar`; `enum Notifications { static func requestAuthorization() async }`.

- [ ] **Step 1: Add the entitlement**

`App/Chores/Chores.entitlements` becomes:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>aps-environment</key>
	<string>development</string>
	<key>com.apple.developer.applesignin</key>
	<array>
		<string>Default</string>
	</array>
</dict>
</plist>
```

The archive export rewrites `development` to `production` from the distribution profile; the source file always says `development`. Automatic signing regenerates the profiles once the Push Notifications capability is on the App ID — open the target's Signing & Capabilities tab once in Xcode if the build complains about a missing entitlement.

- [ ] **Step 2: The delegate and the shared permission request**

Create `App/Chores/AppDelegate.swift`:

```swift
import UIKit

/// Exists for one callback: the APNs device token, which UIKit hands only to
/// the application delegate. Everything else about push lives in
/// `PushRegistrar`, and this forwards to it without knowing anything about it.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set by `ChoresApp` before any token can arrive.
    var onDeviceToken: ((String) -> Void)?

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        onDeviceToken?(hex)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No token means no reminder on this phone. Nothing else in the app
        // depends on it, so there is nothing to show anyone.
    }
}
```

Create `App/Chores/Notifications.swift`:

```swift
import UserNotifications

/// The one permission both sides of the app ask for: a child for its local
/// reminders, a parent for the push.
enum Notifications {
    static func requestAuthorization() async {
        // A refusal is fine — the app simply never notifies.
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }
}
```

In `App/Chores/Kid/ReminderScheduler.swift`, delete `requestAuthorization()` (lines 13–17) and change the header comment to:

```swift
/// The child's reminders, entirely on-device: no APNs, no certificates, no push
/// tokens on this side of the app. The parent's evening reminder is the push,
/// and lives on the server.
```

In `App/Chores/Kid/KidRootView.swift:35`, replace `await ReminderScheduler.requestAuthorization()` with `await Notifications.requestAuthorization()`.

- [ ] **Step 3: Wire the token through the environment**

In `App/Chores/AppEnvironment.swift`, add a stored property and create it in `init`:

```swift
    let pushRegistrar: PushRegistrar
```

```swift
    init(backend: any ChoresBackend, directory: URL, appleTokens: any AppleTokenProviding) {
        self.backend = backend
        self.snapshotCache = SnapshotCache(directory: directory)
        self.outbox = Outbox(directory: directory, backend: backend)
        self.appleTokens = appleTokens
        self.pushRegistrar = PushRegistrar(backend: backend, environment: Self.pushEnvironment)
    }

    /// Debug builds hold sandbox tokens; anything archived — TestFlight or the
    /// store — holds production ones. The same discriminator as `credentials`,
    /// for the same reason: Release is the only configuration an archive can be
    /// built from.
    private static var pushEnvironment: PushEnvironment {
        #if DEBUG
        return .development
        #else
        return .production
        #endif
    }
```

`App/Chores/ChoresApp.swift` becomes:

```swift
import SwiftUI

@main
struct ChoresApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
                .onAppear {
                    // The token cannot arrive before parent mode asks for it,
                    // and parent mode cannot appear before the root has, so
                    // this is early enough.
                    let registrar = environment.pushRegistrar
                    delegate.onDeviceToken = { token in
                        Task { await registrar.tokenDidArrive(token) }
                    }
                }
        }
    }
}
```

- [ ] **Step 4: Register on the parent's screen, forget in `perform`**

In `App/Chores/Parent/ParentRootView.swift`, replace `.task { await store.start() }` (line 60) with:

```swift
        .task {
            await store.start()
            // The system permission alert would block UI tests, and the fake
            // backend has nowhere to send a token anyway.
            if !AppEnvironment.isUITesting {
                await Notifications.requestAuthorization()
                UIApplication.shared.registerForRemoteNotifications()
            }
            await environment.pushRegistrar.parentDidAppear(profile)
        }
```

Replace `perform` (lines 328–337) with:

```swift
    private func perform(_ action: @escaping () async throws -> Void) async {
        // The token row goes first: after sign-out there is no identity left to
        // delete it with, and the phone would keep receiving a family it no
        // longer shows.
        await environment.pushRegistrar.sessionWillEnd()
        do {
            try await action()
            await environment.snapshotCache.clear()
            await environment.outbox.clear()
            await onSessionChanged()
        } catch {
            errorMessage = String(localized: "Couldn't do that. Check your connection and try again.")
            // Still here, still this parent: put the registration back.
            await environment.pushRegistrar.parentDidAppear(parent)
        }
    }
```

- [ ] **Step 5: Build and run the UI suite**

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: builds. If it fails on `aps-environment`, enable Push Notifications on the App ID (Xcode → target → Signing & Capabilities → + Capability) and build again.

Run the UI tests (Global Constraints). Expected: all existing tests still pass — nothing here has visible UI yet.

- [ ] **Step 6: Commit**

`commit-commands:commit` with the eight files. Suggested subject: `Register a parent's phone for the evening push`.

---

### Task 11: The setting, and the strings the device needs

**Files:**
- Create: `App/Chores/DesignSystem/ReminderTimeControl.swift`
- Create: `App/Chores/Parent/EveningReminderView.swift`
- Modify: `App/Chores/Parent/ParentRootView.swift:79-84` (`ManageDestination`), `:162-172` (destinations), `:216-238` (`hub`)
- Modify: `App/Chores/Localizable.xcstrings`
- Create: `App/ChoresUITests/EveningReminderUITests.swift`

**Interfaces:**
- Consumes: `TimeOfDay` (Task 1), `Profile.eveningReminderAt`, `backend.updateProfile` (Task 2), `HubRow`, `BackButton`, `ScreenHeader`, `Footnote`, `Theme`.
- Produces: `ReminderTimeControl(label:time:defaultTime:identifier:)`, reused twice by the child reminders plan.

- [ ] **Step 1: Write the failing UI test**

Create `App/ChoresUITests/EveningReminderUITests.swift`:

```swift
import XCTest

/// The parent's own evening reminder: on by default, and the hub says what it
/// is set to.
final class EveningReminderUITests: ParentUITestCase {

    func testTurningTheReminderOffIsReflectedOnTheHub() {
        let app = launchIntoParentMode()
        app.manageTab.tap()

        let row = app.buttons["manage.reminder"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        // CONTAINS rather than an exact match: iOS puts a narrow no-break space
        // before "PM", and the test locale decides between 21:00 and 9:00 PM.
        XCTAssertTrue(row.staticTexts.containing(
            NSPredicate(format: "label CONTAINS '21:00' OR label CONTAINS '9:00'")).firstMatch.exists,
            "a new parent starts at 21:00")
        row.tap()

        let toggle = app.switches["reminder.evening.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1", "the switch starts on")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0")

        app.buttons["nav.back"].tap()
        XCTAssertTrue(app.buttons["manage.reminder"].staticTexts["Off"].waitForExistence(timeout: 5),
                      "the hub row should now say Off")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ChoresUITests/EveningReminderUITests`
Expected: fails — no `manage.reminder`.

- [ ] **Step 3: The control**

Create `App/Chores/DesignSystem/ReminderTimeControl.swift`:

```swift
import SwiftUI
import ChoresCore

/// A reminder time as a row: a label, a switch, and — while on — a picker for
/// the hour and minute. `nil` is off. The parent's own evening reminder uses
/// it once; a child's edit sheet uses it twice.
struct ReminderTimeControl: View {
    let label: Text
    @Binding var time: TimeOfDay?
    /// What "on" starts at when the switch is flipped from off.
    let defaultTime: TimeOfDay
    let identifier: String

    /// Any fixed day will do: only the hour and minute survive the round trip.
    private static let anchorDay = CalendarDay(year: 2000, month: 1, day: 1)

    private var isOn: Binding<Bool> {
        Binding(get: { time != nil },
                set: { on in time = on ? (time ?? defaultTime) : nil })
    }

    private var pickerDate: Binding<Date> {
        Binding(get: { (time ?? defaultTime).date(on: Self.anchorDay, in: .current) },
                set: { time = TimeOfDay($0, in: .current) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: isOn) {
                label
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.text)
            }
            .tint(Theme.accent)
            .accessibilityIdentifier("\(identifier).toggle")

            if time != nil {
                DatePicker("", selection: pickerDate, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .tint(Theme.accent)
                    .accessibilityIdentifier("\(identifier).picker")
            }
        }
        .ruledRow(minHeight: 52, verticalPadding: 8)
        .animation(.easeInOut(duration: 0.15), value: time != nil)
    }
}
```

- [ ] **Step 4: The screen**

Create `App/Chores/Parent/EveningReminderView.swift`:

```swift
import SwiftUI
import ChoresCore

/// The parent's own evening reminder — theirs, not the family's, so one parent
/// switching it off does not silence the other. Saves on every change; there
/// is nothing to confirm.
struct EveningReminderView: View {
    let store: FamilyStore
    let backend: any ChoresBackend
    /// The parent using this device.
    let me: Profile

    @State private var time: TimeOfDay?
    @State private var errorMessage: String?

    init(store: FamilyStore, backend: any ChoresBackend, me: Profile) {
        self.store = store
        self.backend = backend
        self.me = me
        _time = State(initialValue: me.eveningReminderAt)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.blockGap) {
                BackButton(label: Text("Manage"))
                    .padding(.leading, -6)

                ScreenHeader(kicker: Text("Manage"), title: Text("Evening reminder"))

                ReminderTimeControl(label: Text("Remind me"),
                                    time: $time,
                                    defaultTime: TimeOfDay(hour: 21, minute: 0),
                                    identifier: "reminder.evening")

                Footnote(text: Text("Sent to this phone at this time when a child still has chores unticked. Off means never."))

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.danger)
                }
            }
            .padding(.horizontal, Theme.screenInset)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .background(Theme.bg)
        .nocturneNavigation()
        .onChange(of: time) { _, newValue in
            Task { await save(newValue) }
        }
    }

    private func save(_ newValue: TimeOfDay?) async {
        var updated = store.snapshot?.profiles.first { $0.id == me.id } ?? me
        updated.eveningReminderAt = newValue
        do {
            try await backend.updateProfile(updated)
            await store.reloadAfterEdit()
        } catch {
            errorMessage = String(localized: "Couldn't save. Check your connection and try again.")
        }
    }
}
```

- [ ] **Step 5: The hub row and the destination**

In `App/Chores/Parent/ParentRootView.swift`:

`ManageDestination` gains a case:

```swift
enum ManageDestination: Hashable {
    case people
    case chores
    case schedule
    case reminder
}
```

The `switch destination` gains:

```swift
                    case .reminder:
                        EveningReminderView(store: store, backend: environment.backend, me: me)
```

`ManageView` gains two computed properties beside `childCount`:

```swift
    /// This parent as the snapshot has them now, so the hub reflects a change
    /// the moment it is saved rather than what the session loaded.
    private var me: Profile { store.snapshot?.profiles.first { $0.id == parent.id } ?? parent }

    private var reminderMeta: Text {
        if let time = me.eveningReminderAt {
            return Text(time.date(on: store.today, in: store.timeZone), style: .time)
        }
        return Text("Off")
    }
```

`hub` gains a fourth row after the schedule one:

```swift
            NavigationLink(value: ManageDestination.reminder) {
                HubRow(systemImage: "bell", label: Text("Evening reminder"),
                       meta: reminderMeta)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("manage.reminder")
```

Update the doc comment above `ManageView` from "The hub: People, Chores and Schedule behind three rows" to "The hub: People, Chores, Schedule and the evening reminder behind four rows".

- [ ] **Step 6: Strings**

Add to `App/Chores/Localizable.xcstrings`, following the existing entry shape (`"localizations" → "fi" → "stringUnit"` with `"state": "translated"`; English is the source language and needs no entry):

| Key | fi |
|---|---|
| `EVENING_PUSH_TITLE` | Illan tehtävät |
| `EVENING_PUSH_BODY_ONE` | 1 tehtävä on vielä kuittaamatta. |
| `EVENING_PUSH_BODY_MANY` | %@ tehtävää on vielä kuittaamatta. |
| `Evening reminder` | Iltamuistutus |
| `Remind me` | Muistuta minua |
| `Off` | Pois |
| `Sent to this phone at this time when a child still has chores unticked. Off means never.` | Lähetetään tähän puhelimeen tähän aikaan, jos lapsella on vielä kuittaamattomia tehtäviä. Pois tarkoittaa ei koskaan. |

The three `EVENING_PUSH_*` keys are looked up by the notification system, not by code, so they also need **English** entries (`"en"` → `stringUnit`): `Chores tonight`, `1 chore is still unticked.`, `%@ chores are still unticked.` — a key that is not a sentence has no implicit English value to fall back on.

- [ ] **Step 7: Run the UI test to verify it passes**

Run: the `-only-testing:ChoresUITests/EveningReminderUITests` command from Step 2.
Expected: passes. Then the whole UI suite; expected: all pass.

- [ ] **Step 8: Commit**

`commit-commands:commit` with the five files. Suggested subject: `Let each parent choose their evening reminder, or none`.

---

### Task 12: Privacy manifest, the privacy pages, and RELEASING

**Files:**
- Modify: `App/Chores/PrivacyInfo.xcprivacy:21-51`
- Modify: `docs/site/privacy/index.html:14`, `:30-43`, `:76-80`
- Modify: `docs/site/privacy/fi/index.html:14`, `:30-43`, `:78-82`
- Modify: `docs/RELEASING.md` — the App Privacy table and paragraph (§"The App Privacy answers"), and a new subsection under "## First-time setup of the hosted project"

**Interfaces:** none in code. This task is what keeps the manifest, the store answers and the policy in agreement (spec §8).

- [ ] **Step 1: The manifest**

In `App/Chores/PrivacyInfo.xcprivacy`, add a third dict inside `NSPrivacyCollectedDataTypes`, after the user-content one:

```xml
		<!-- The APNs token of a parent's phone, kept so the server can send the
		     evening reminder. Linked: it sits beside the profile it belongs to.
		     Children's devices register none; their reminders stay local. -->
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeDeviceID</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
```

Run: `plutil -lint App/Chores/PrivacyInfo.xcprivacy`
Expected: `OK`.

- [ ] **Step 2: The English policy**

In `docs/site/privacy/index.html`:

Line 14: `<p class="updated">Last updated 18 September 2026.</p>`

Add a bullet at the end of the "What the app stores" list (after the anonymous-session one):

```html
	<li>For a parent's phone: the push token Apple issues to it for this app, so the
		server can send that parent's evening reminder. See Notifications below.</li>
```

Replace the Notifications section:

```html
<h2>Notifications</h2>

<p>A child's reminders are scheduled by the app on the child's own device. Nothing about
them leaves the phone, and a child's device holds no push token.</p>

<p>A parent's evening reminder is different. It is sent by the server, because only the
server knows whether a chore ticked off on a child's phone is still open. To deliver it,
the app stores the push token Apple issues to the parent's phone for this app, beside
that parent's profile. The token identifies the phone to Apple's notification service
and nothing else. The reminder itself carries a count of unticked chores and no names.
The token is deleted when the parent signs out, leaves the family or deletes their
account. Declining the notification permission, or switching the reminder off under
<strong>Manage → Evening reminder</strong>, means no reminder.</p>
```

- [ ] **Step 3: The Finnish policy**

In `docs/site/privacy/fi/index.html`:

Line 14: `<p class="updated">Päivitetty 18.9.2026.</p>`

The new bullet:

```html
	<li>Vanhemman puhelimesta: Applen tälle sovellukselle antama push-tunniste, jotta
		palvelin voi lähettää kyseisen vanhemman iltamuistutuksen. Katso Ilmoitukset alla.</li>
```

The Notifications section:

```html
<h2>Ilmoitukset</h2>

<p>Lapsen muistutukset ajastaa sovellus itse lapsen laitteella. Niistä ei lähde mitään
puhelimesta ulos, eikä lapsen laitteella ole push-tunnistetta.</p>

<p>Vanhemman iltamuistutus on eri asia. Sen lähettää palvelin, koska vain palvelin tietää,
onko lapsen puhelimella kuitattu tehtävä yhä auki. Toimitusta varten sovellus tallentaa
Applen vanhemman puhelimelle tälle sovellukselle antaman push-tunnisteen kyseisen
vanhemman profiilin yhteyteen. Tunniste yksilöi puhelimen Applen ilmoituspalvelulle eikä
mitään muuta. Itse muistutuksessa on kuittaamattomien tehtävien lukumäärä, ei nimiä.
Tunniste poistetaan, kun vanhempi kirjautuu ulos, poistuu perheestä tai poistaa tilinsä.
Jos ilmoituslupaa ei anna tai muistutuksen kytkee pois kohdasta
<strong>Hallinta → Iltamuistutus</strong>, muistutusta ei tule.</p>
```

- [ ] **Step 4: RELEASING — the App Privacy answers**

In `docs/RELEASING.md`, under "### The App Privacy answers", the table becomes:

```markdown
| Data | Collected | Linked to the user | Tracking | Purpose |
|---|---|---|---|---|
| Contact Info → Name | yes | yes | no | App Functionality |
| User Content → Other User Content | yes | yes | no | App Functionality |
| Identifiers → Device ID | yes | yes | no | App Functionality |
```

and the paragraph after it becomes:

```markdown
Nothing else. No usage data, no diagnostics: there is no analytics or crash-reporting
SDK in the project. The one identifier is the APNs token of a parent's phone, which the
evening reminder is sent to; children's devices register none, and their reminders are
local notifications. "Do you or your third-party partners use data for tracking?" is
**no**.
```

And the sentence beginning "The names are the display names…" gains: "The device ID is the push token, held in `device_tokens` and deleted with the session."

- [ ] **Step 5: RELEASING — the once-per-project setup**

Under "## First-time setup of the hosted project", after the Anonymous sign-ins paragraph, add:

````markdown
### The evening reminder: APNs key, secrets, Vault, deploy

Once per project. Nothing here recurs per release.

1. **An APNs key.** Developer portal → Certificates, Identifiers & Profiles → Keys → +,
   tick *Apple Push Notifications service (APNs)*, download the `.p8` — it is offered
   once. Note its Key ID. The Team ID is `HPD6U8BLB5`, the `DEVELOPMENT_TEAM` in the
   project. This is a different key from the App Store Connect API key in
   `~/.appstoreconnect/`; the two do nothing for each other.
2. **Function secrets.**

       supabase secrets set APNS_KEY_ID=<key id> APNS_TEAM_ID=HPD6U8BLB5
       supabase secrets set APNS_PRIVATE_KEY="$(cat ~/Downloads/AuthKey_<key id>.p8)"
       supabase secrets set EVENING_REMINDER_SECRET="$(openssl rand -hex 32)"

3. **Vault entries**, in the hosted project's SQL editor, so the cron job can find the
   function and prove who it is. The secret is the same value as above.

       select vault.create_secret('https://<project ref>.supabase.co/functions/v1/evening-reminder',
                                  'evening_reminder_url');
       select vault.create_secret('<EVENING_REMINDER_SECRET>', 'evening_reminder_secret');

4. **Deploy.** `supabase functions deploy evening-reminder`.
5. **Watch it run.** The migration created the job; the next evening,
   `select * from evening_reminder_sends order by claimed_at desc limit 5` shows a row
   for every parent who was due with an unfinished day — `device_count = 0` and
   `sent_at null` until a build with push has registered a phone, `sent_at` set after.
   No rows on an evening you know was unfinished means the job is not running:
   `select * from cron.job_run_details order by start_time desc limit 5`.

If the `.p8` leaks, revoke it in the portal, make another, repeat step 2. Nothing in the
database changes.

### Testing a push end to end

A debug build on a real phone registers a `development` token; find it with
`select token from device_tokens`. Put the four secrets in `supabase/functions/.env`
(gitignored), then:

    supabase functions serve evening-reminder
    curl -X POST http://127.0.0.1:54321/functions/v1/evening-reminder \
      -H 'Authorization: Bearer <EVENING_REMINDER_SECRET>' \
      -H 'Content-Type: application/json' \
      -d '{"work":[{"profile_id":"<your profile id>","local_date":"2026-09-21",
                    "undone_count":2,"token":"<token>","environment":"development"}]}'

The notification arrives within a second. `evening_reminder_record` updates nothing,
since no claim row exists for a hand-made request; that is expected.
````

- [ ] **Step 6: Check the pages still render and the doc reads**

Run: `open docs/site/privacy/index.html` and the `fi` one; read the Notifications sections. Run: `git diff --stat` and confirm exactly five files changed.

- [ ] **Step 7: Commit**

`commit-commands:commit` with the five files. Suggested subject: `Declare the push token in the four places that must agree`.

---

### Task 13: Rollout

Not code. Each step is a checkbox because each is a place to stop and look.

- [ ] **Step 1: Migrations.** The owner runs `supabase db push` for the four `20260918*` files. Confirm with `select column_name from information_schema.columns where table_name = 'profiles' and column_name like '%reminder%'` — two rows.
- [ ] **Step 2: Secrets, Vault, deploy** — RELEASING's new section, steps 1–4.
- [ ] **Step 3: Wait one evening.** `evening_reminder_sends` shows a claim for each parent who was due with an unfinished day, `device_count = 0`. This is the job proving itself before any phone is registered.
- [ ] **Step 4: TestFlight.** Bump `MARKETING_VERSION` if not already on the 1.1 train; `tools/testflight.sh`. On a real phone: sign in as a parent, accept the permission, check `select * from device_tokens` shows a `production` row. Leave a chore unticked and wait for your evening time — or set it five minutes ahead in Manage.
- [ ] **Step 5: App Privacy.** App Store Connect → App Privacy → add Identifiers → Device ID with the answers in RELEASING's table → **Publish**.
- [ ] **Step 6: Site.** Merging to `main` publishes `docs/site/` through Pages; open the two privacy URLs and confirm the new date.
- [ ] **Step 7: Submit.** `tools/appstore.sh --status`, read it, `tools/appstore.sh --submit`.

---

## Self-review notes

**Spec coverage.** §3.1 → Task 5; §3.2 → Tasks 1–2; §3.3 → Task 11; §4.1 → Task 6; §4.2, §5.1–5.3 → Task 7; §5.4 → Task 8; §6 → Task 9; §7.1–7.2 → Task 10; §7.3 → Task 3; §7.4–7.5 → Task 11; §8 → Task 12; §9 → the test steps of Tasks 1–9 and 11; §10 → Task 13; `PushRegistrar` (§7.1) → Task 4.

**Types across tasks.** `TimeOfDay(hour:minute:)`, `TimeOfDay(_:in:)`, `date(on:in:)` (Task 1) are what Task 11's control and Task 2's tests call. `registerDeviceToken(_:environment:)` / `forgetDeviceToken(_:)` (Task 3) are what Task 4's registrar and Task 10's `perform` call. The SQL row shape in Task 7's `returns table` is the `WorkRow` interface in Task 9 and the `to_jsonb(w)` in Task 8. `P0005` in Task 6 is what `SupabaseErrorMapping` already turns into `.notPermitted`, which Task 3's in-memory test asserts.

**Known judgement calls left to the executor.** The exact text form of a `(timestamptz, text)` row in pgTAP (Task 7, Step 4 note). Whether `pg_cron` accepts `with schema pg_catalog` on the local image (Task 8, Step 4 note). The Finnish strings are the spec's proposals.
