# Schedule History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A past day resolves against the schedule as it was *on that day*, so archiving or moving a chore no longer rewrites what a child did or missed earlier in the week.

**Architecture:** Every template row carries a validity range — `schedule_entries.valid_from`/`valid_until` (end exclusive, `null` = open) and `chores.archived_on` — and `ScheduleResolver` filters by the day it is asked about. Removing an entry closes its range instead of deleting it; the close/delete/reopen rules live in three Postgres RPCs under RLS, mirrored by the in-memory backend for the UI tests. The client sends the family's `today` with every schedule write, because Postgres's `current_date` is UTC.

**Tech Stack:** Swift 6 / SwiftUI (iOS 17+), Swift Testing, Supabase (Postgres 15, PostgREST, supabase-swift), pgTAP, XCUITest.

**Spec:** `docs/superpowers/specs/2026-09-21-schedule-history-design.md`.

## Global Constraints

- `valid_from` inclusive, `valid_until` exclusive, `null` = still current. `archived_on` = the first day the chore is *not* due.
- "Today" is always the family's day, `store.today` on the client, `p_today` in SQL. Never `Date()`, never `current_date`.
- The migration adds `archived_on` and recreates `family_undone_count` **before** it drops `is_archived`: a `language sql` function is parsed at creation and must not reference a dropped column.
- Backfill: `valid_from = (created_at at time zone families.timezone)::date`; archived chores get `archived_on` the same way from their own `created_at`.
- The in-memory backend mirrors every SQL rule; a divergence is a bug in the fake.
- Shell commands use single quotes and no `cd` before `git`.
- Unit tests: `swift test`. SQL tests: `supabase db reset && supabase test db` (needs Docker). Integration tests: `SUPABASE_INTEGRATION=1 SUPABASE_ANON_KEY=... swift test --filter SupabaseIntegrationTests` against the local stack. UI tests: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' test`.
- The user runs migrations against production; this plan never runs `supabase db push`. `supabase db reset` against the *local* stack is fine and expected.
- Commit after every task with the `commit-commands:commit` skill; never push.

## File structure

| File | Responsibility |
|---|---|
| `Sources/ChoresCore/Models/ScheduleEntry.swift` | `validFrom`, `validUntil`, `isCurrent`, `isValid(on:)` |
| `Sources/ChoresCore/Models/Chore.swift` | `archivedOn` replaces stored `isArchived`; `isArchived(on:)` |
| `Sources/ChoresCore/Schedule/ScheduleResolver.swift` | Filters template and chores by the day asked about |
| `Sources/ChoresCore/Repositories/Repositories.swift` | Schedule writes take `today` |
| `Sources/ChoresCore/Repositories/InMemory/InMemoryChoresBackend.swift` | Close/delete/reopen rules; overlap fetch |
| `Sources/ChoresCore/Repositories/InMemory/InMemoryChoresBackend+Seed.swift` | Seeded entries carry a `validFrom` |
| `Sources/ChoresCore/Repositories/Supabase/SupabaseChoresBackend.swift` | Overlap fetch; the three RPC calls; `archived_on` payload |
| `supabase/migrations/20260921100000_schedule_history.sql` *(new)* | Columns, backfill, partial index, RPCs, `family_undone_count` |
| `supabase/tests/03_schedule_history.sql` *(new)* | The RPC rules, the index, the undone count |
| `supabase/tests/01_rls_and_rpcs.sql`, `02_evening_reminder.sql` | Fixtures gain `valid_from`; `is_archived` → `archived_on` |
| `App/Chores/Parent/ScheduleEditorView.swift` | Shows only current entries; passes `store.today` |
| `App/Chores/Parent/ChoresView.swift` | Archive stamps `store.today` |
| `Tests/ChoresCoreTests/ModelDecodingTests.swift`, `ScheduleResolverTests.swift`, `InMemoryBackendTests.swift`, `SupabaseIntegrationTests.swift`, `ReminderScheduleTests.swift`, `TestDoubles.swift` | Updated and extended |

---

### Task 1: Models carry ranges

**Files:**
- Modify: `Sources/ChoresCore/Models/ScheduleEntry.swift` (whole file)
- Modify: `Sources/ChoresCore/Models/Chore.swift` (whole file)
- Modify: `Sources/ChoresCore/Repositories/InMemory/InMemoryChoresBackend.swift:294-332` (constructors only; rules come in Task 3)
- Modify: `Sources/ChoresCore/Repositories/InMemory/InMemoryChoresBackend+Seed.swift:37-39, 123-125`
- Modify: `Tests/ChoresCoreTests/ScheduleResolverTests.swift:16-23`, `Tests/ChoresCoreTests/ReminderScheduleTests.swift:82-84, 99-102`, `Tests/ChoresCoreTests/InMemoryBackendTests.swift:289-291`, `Tests/ChoresCoreTests/SupabaseIntegrationTests.swift:208-210`
- Test: `Tests/ChoresCoreTests/ModelDecodingTests.swift`

**Interfaces:**
- Produces:
  - `ScheduleEntry.init(id:familyID:profileID:choreID:weekday:validFrom: CalendarDay, validUntil: CalendarDay? = nil)`; `public var validUntil: CalendarDay?`; `public var isCurrent: Bool`; `public func isValid(on: CalendarDay) -> Bool`.
  - `Chore.init(id:familyID:name:icon:points:archivedOn: CalendarDay? = nil, createdAt:)`; `public var archivedOn: CalendarDay?`; `public var isArchived: Bool` (computed, get-only); `public func isArchived(on: CalendarDay) -> Bool`.
- Every later task constructs these types with exactly these initialisers.

- [ ] **Step 1: Write the failing decoding tests**

Append to `Tests/ChoresCoreTests/ModelDecodingTests.swift`, inside the suite:

```swift
    @Test func decodesScheduleEntryRange() throws {
        let json = """
        {"id":"22222222-2222-2222-2222-222222222222",
         "family_id":"11111111-1111-1111-1111-111111111111",
         "profile_id":"33333333-3333-3333-3333-333333333333",
         "chore_id":"44444444-4444-4444-4444-444444444444",
         "weekday":3,"created_at":"2026-08-10T09:00:00Z",
         "valid_from":"2026-08-10","valid_until":null}
        """
        let entry = try ChoresJSON.decoder.decode(ScheduleEntry.self, from: Data(json.utf8))
        #expect(entry.validFrom == CalendarDay(year: 2026, month: 8, day: 10))
        #expect(entry.validUntil == nil)
        #expect(entry.isCurrent)
    }

    @Test func scheduleEntryIsValidFromItsFirstDayUpToButNotIncludingItsLast() {
        let entry = ScheduleEntry(
            id: UUID(), familyID: UUID(), profileID: UUID(), choreID: UUID(), weekday: 1,
            validFrom: CalendarDay(year: 2026, month: 8, day: 10),
            validUntil: CalendarDay(year: 2026, month: 8, day: 17))
        #expect(!entry.isValid(on: CalendarDay(year: 2026, month: 8, day: 9)))
        #expect(entry.isValid(on: CalendarDay(year: 2026, month: 8, day: 10)))
        #expect(entry.isValid(on: CalendarDay(year: 2026, month: 8, day: 16)))
        #expect(!entry.isValid(on: CalendarDay(year: 2026, month: 8, day: 17)))
        #expect(!entry.isCurrent)
    }

    @Test func anOpenScheduleEntryIsValidForever() {
        let entry = ScheduleEntry(
            id: UUID(), familyID: UUID(), profileID: UUID(), choreID: UUID(), weekday: 1,
            validFrom: CalendarDay(year: 2026, month: 8, day: 10))
        #expect(entry.isValid(on: CalendarDay(year: 2099, month: 1, day: 1)))
    }

    @Test func decodesChoreArchivedOn() throws {
        let json = """
        {"id":"44444444-4444-4444-4444-444444444444",
         "family_id":"11111111-1111-1111-1111-111111111111",
         "name":"Bins","icon":null,"points":null,
         "created_at":"2026-08-10T09:00:00Z","archived_on":"2026-09-01"}
        """
        let chore = try ChoresJSON.decoder.decode(Chore.self, from: Data(json.utf8))
        #expect(chore.archivedOn == CalendarDay(year: 2026, month: 9, day: 1))
        #expect(chore.isArchived)
        #expect(!chore.isArchived(on: CalendarDay(year: 2026, month: 8, day: 31)))
        #expect(chore.isArchived(on: CalendarDay(year: 2026, month: 9, day: 1)))
    }

    @Test func aChoreWithNoArchivedOnIsNotArchivedOnAnyDay() throws {
        let json = """
        {"id":"44444444-4444-4444-4444-444444444444",
         "family_id":"11111111-1111-1111-1111-111111111111",
         "name":"Bins","icon":null,"points":null,
         "created_at":"2026-08-10T09:00:00Z","archived_on":null}
        """
        let chore = try ChoresJSON.decoder.decode(Chore.self, from: Data(json.utf8))
        #expect(!chore.isArchived)
        #expect(!chore.isArchived(on: CalendarDay(year: 2099, month: 1, day: 1)))
    }

    @Test func encodesChoreArchivedOnNotIsArchived() throws {
        let chore = Chore(id: UUID(), familyID: UUID(), name: "Bins",
                          archivedOn: CalendarDay(year: 2026, month: 9, day: 1))
        let json = String(decoding: try ChoresJSON.encoder.encode(chore), as: UTF8.self)
        #expect(json.contains("\"archived_on\":\"2026-09-01\""))
        #expect(!json.contains("is_archived"))
    }
```

Also update the existing `encodesScheduleEntryWithSnakeCaseKeys` (line 62) so it constructs with a range and checks the new key:

```swift
    @Test func encodesScheduleEntryWithSnakeCaseKeys() throws {
        let entry = ScheduleEntry(
            id: UUID(), familyID: UUID(), profileID: UUID(), choreID: UUID(), weekday: 3,
            validFrom: CalendarDay(year: 2026, month: 8, day: 10))
        let json = String(decoding: try ChoresJSON.encoder.encode(entry), as: UTF8.self)
        #expect(json.contains("\"profile_id\""))
        #expect(json.contains("\"chore_id\""))
        #expect(json.contains("\"valid_from\":\"2026-08-10\""))
        #expect(!json.contains("\"profileID\""))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift build --build-tests 2>&1 | grep -E 'error:' | head`
Expected: errors such as `extra argument 'validFrom' in call`, `extra argument 'archivedOn' in call`, `value of type 'ScheduleEntry' has no member 'isValid'`.

- [ ] **Step 3: Rewrite `ScheduleEntry`**

`Sources/ChoresCore/Models/ScheduleEntry.swift` becomes:

```swift
import Foundation

/// One row of the weekly template: this child does this chore on this weekday,
/// every week between `validFrom` and `validUntil`.
///
/// Removing an entry closes its range rather than deleting the row, so a past
/// day can be resolved against the template as it stood on that day. Only an
/// entry added and removed on the same day is ever deleted — it lived zero days.
public struct ScheduleEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let familyID: UUID
    public let profileID: UUID
    public let choreID: UUID
    /// ISO weekday: 1 = Monday … 7 = Sunday.
    public let weekday: Int
    /// The first day this entry applies to.
    public let validFrom: CalendarDay
    /// The first day this entry no longer applies to; `nil` while it is still
    /// part of the current template.
    public var validUntil: CalendarDay?

    public init(id: UUID, familyID: UUID, profileID: UUID, choreID: UUID, weekday: Int,
                validFrom: CalendarDay, validUntil: CalendarDay? = nil) {
        self.id = id
        self.familyID = familyID
        self.profileID = profileID
        self.choreID = choreID
        self.weekday = weekday
        self.validFrom = validFrom
        self.validUntil = validUntil
    }

    /// Part of the template as it stands now — what the editor shows and what
    /// a copy-day copies.
    public var isCurrent: Bool { validUntil == nil }

    /// Whether this entry applied on `day`: from `validFrom` inclusive up to
    /// `validUntil` exclusive.
    public func isValid(on day: CalendarDay) -> Bool {
        day >= validFrom && (validUntil.map { day < $0 } ?? true)
    }

    enum CodingKeys: String, CodingKey {
        case id, weekday
        case familyID = "family_id"
        case profileID = "profile_id"
        case choreID = "chore_id"
        case validFrom = "valid_from"
        case validUntil = "valid_until"
    }
}
```

- [ ] **Step 4: Rewrite `Chore`**

`Sources/ChoresCore/Models/Chore.swift` becomes:

```swift
import Foundation

public struct Chore: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let familyID: UUID
    public var name: String
    /// SF Symbol name.
    public var icon: String?
    /// Reserved for a future rewards layer. Unused in v1.
    public var points: Int?
    /// The first day this chore is no longer due; `nil` while it is active.
    /// Archived chores keep their history and their schedule entries and drop
    /// out of `ScheduleResolver` output from this day on. Deleting would orphan
    /// completion history; a flag would erase the week's earlier ticks.
    public var archivedOn: CalendarDay?
    public let createdAt: Date

    public init(id: UUID, familyID: UUID, name: String, icon: String? = nil,
                points: Int? = nil, archivedOn: CalendarDay? = nil, createdAt: Date = .init()) {
        self.id = id
        self.familyID = familyID
        self.name = name
        self.icon = icon
        self.points = points
        self.archivedOn = archivedOn
        self.createdAt = createdAt
    }

    /// Archived as of now — what the Chores screen and the editor's picker ask.
    public var isArchived: Bool { archivedOn != nil }

    /// Archived as of `day` — what the resolver asks.
    public func isArchived(on day: CalendarDay) -> Bool {
        archivedOn.map { day >= $0 } ?? false
    }

    enum CodingKeys: String, CodingKey {
        case id, name, icon, points
        case familyID = "family_id"
        case archivedOn = "archived_on"
        case createdAt = "created_at"
    }
}
```

- [ ] **Step 5: Fix every constructor the compiler now rejects**

`Sources/ChoresCore/Repositories/InMemory/InMemoryChoresBackend.swift`, in `addScheduleEntry` (line 303) and `copyDay` (line 325): add `validFrom: CalendarDay(Date(), in: .current)` to both `ScheduleEntry(...)` calls. This is an interim value with the same meaning the row has today — it is replaced by the caller's `today` in Task 3.

`Sources/ChoresCore/Repositories/InMemory/InMemoryChoresBackend+Seed.swift`: add at the top of the extension

```swift
    /// Seeded entries have always existed. A day years before any seeded
    /// `today` keeps every fetched week inside their range.
    static let seedValidFrom = CalendarDay(year: 2020, month: 1, day: 1)
```

and add `validFrom: Self.seedValidFrom` to both `ScheduleEntry(...)` calls (lines 37 and 123).

`Tests/ChoresCoreTests/ScheduleResolverTests.swift:16-23`:

```swift
    func chore(_ id: String, _ name: String, archivedOn: CalendarDay? = nil) -> Chore {
        Chore(id: UUID(uuidString: id)!, familyID: family, name: name, archivedOn: archivedOn)
    }

    /// An entry that has always applied, so existing tests are about weekdays,
    /// not ranges.
    func entry(_ profile: UUID, _ chore: Chore, _ weekday: Int,
               validFrom: CalendarDay = CalendarDay(year: 2020, month: 1, day: 1),
               validUntil: CalendarDay? = nil) -> ScheduleEntry {
        ScheduleEntry(id: UUID(), familyID: family, profileID: profile,
                      choreID: chore.id, weekday: weekday,
                      validFrom: validFrom, validUntil: validUntil)
    }
```

In the same file, `excludesArchivedChores` (line 91) constructs an archived chore with `archived: true`; change that call to `archivedOn: CalendarDay(year: 2020, month: 1, day: 1)`.

`Tests/ChoresCoreTests/ReminderScheduleTests.swift:82-84`:

```swift
    func chore(_ name: String, archivedOn: CalendarDay? = nil) -> Chore {
        Chore(id: UUID(), familyID: familyID, name: name, archivedOn: archivedOn)
    }
```

and in `makeSnapshot` (line 99-102) add `validFrom: CalendarDay(year: 2020, month: 1, day: 1)` to the `ScheduleEntry(...)` call. Any test in that file passing `archived: true` passes `archivedOn: CalendarDay(year: 2020, month: 1, day: 1)` instead.

`Tests/ChoresCoreTests/InMemoryBackendTests.swift:290`: `archived.isArchived = true` becomes `archived.archivedOn = CalendarDay(year: 2026, month: 8, day: 10)`.

`Tests/ChoresCoreTests/SupabaseIntegrationTests.swift:209`: `archived.isArchived = true` becomes `archived.archivedOn = monday`.

`App/Chores/Parent/ChoresView.swift:192`: `updated.isArchived = isArchived` becomes `updated.archivedOn = isArchived ? store.today : nil`.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test 2>&1 | grep -E 'error:|✘|Test run with'`
Expected: `✔ Test run with N tests in 17 suites passed` and no `✘`. (The Supabase backend still compiles: it decodes `Chore` and `ScheduleEntry` from JSON and constructs neither; its `ChoreUpdate` payload still names `isArchived`, which now reads the computed property — that is corrected in Task 5.)

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | grep -E 'error:|BUILD'`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

Use the `commit-commands:commit` skill. Message: `Give schedule entries a validity range and chores an archived-on day`.

---

### Task 2: The resolver honours ranges

**Files:**
- Modify: `Sources/ChoresCore/Schedule/ScheduleResolver.swift:30-39`
- Test: `Tests/ChoresCoreTests/ScheduleResolverTests.swift`

**Interfaces:**
- Consumes: `ScheduleEntry.isValid(on:)`, `Chore.isArchived(on:)` (Task 1).
- Produces: no signature change. `ScheduleResolver.chores(for:on:template:chores:completions:)` now returns only entries valid on `day` whose chore is not archived on `day`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ChoresCoreTests/ScheduleResolverTests.swift`, after `excludesArchivedChores`:

```swift
    // MARK: - History

    @Test func anEntryAppliesFromItsFirstDay() {
        let template = [entry(kidA, bins, 1, validFrom: monday.adding(days: 7))]

        let thisMonday = ScheduleResolver.chores(
            for: kidA, on: monday, template: template, chores: [bins], completions: [])
        let nextMonday = ScheduleResolver.chores(
            for: kidA, on: monday.adding(days: 7), template: template, chores: [bins], completions: [])

        #expect(thisMonday.isEmpty)
        #expect(nextMonday.map(\.chore.name) == ["Bins"])
    }

    @Test func aClosedEntryStopsApplyingOnItsLastDay() {
        // Closed on the second Monday: valid_until is exclusive.
        let template = [entry(kidA, bins, 1, validUntil: monday.adding(days: 7))]

        let thisMonday = ScheduleResolver.chores(
            for: kidA, on: monday, template: template, chores: [bins], completions: [])
        let nextMonday = ScheduleResolver.chores(
            for: kidA, on: monday.adding(days: 7), template: template, chores: [bins], completions: [])

        #expect(thisMonday.map(\.chore.name) == ["Bins"])
        #expect(nextMonday.isEmpty)
    }

    @Test func aChoreArchivedMidWeekIsStillDueOnTheDaysBefore() {
        // Archived on Wednesday: Monday's tick still counts, Wednesday has nothing.
        let archived = chore("44444444-0000-0000-0000-000000000003", "Bins", archivedOn: wednesday)
        let template = [entry(kidA, archived, 1), entry(kidA, archived, 3)]
        let done = Completion(id: UUID(), familyID: family, profileID: kidA,
                              choreID: archived.id, dueOn: monday, completedBy: kidA)

        let mondayResult = ScheduleResolver.chores(
            for: kidA, on: monday, template: template, chores: [archived], completions: [done])
        let wednesdayResult = ScheduleResolver.chores(
            for: kidA, on: wednesday, template: template, chores: [archived], completions: [])

        #expect(mondayResult.map(\.isCompleted) == [true])
        #expect(wednesdayResult.isEmpty)
    }

    @Test func progressFollowsTheRangeToo() {
        let template = [entry(kidA, bins, 1, validUntil: tuesday)]

        let progress = ScheduleResolver.progress(
            for: kidA, on: tuesday.adding(days: 6), template: template, chores: [bins], completions: [])

        #expect(progress == (0, 0))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ScheduleResolverTests 2>&1 | grep -E '✘|Expectation failed' | head`
Expected: `anEntryAppliesFromItsFirstDay`, `aClosedEntryStopsApplyingOnItsLastDay`, `aChoreArchivedMidWeekIsStillDueOnTheDaysBefore` and `progressFollowsTheRangeToo` each record an issue — the resolver ignores ranges and the archived chore is dropped from Monday.

- [ ] **Step 3: Filter by the day**

In `Sources/ChoresCore/Schedule/ScheduleResolver.swift`, replace lines 30-33:

```swift
        return template
            .filter { $0.profileID == profileID && $0.weekday == day.isoWeekday && $0.isValid(on: day) }
            .compactMap { entry -> ChoreForDay? in
                guard let chore = choresByID[entry.choreID], !chore.isArchived(on: day) else { return nil }
```

And update the file's header comment (lines 9-11) to say what now happens:

```swift
/// The template carries a validity range per row and each chore an archived-on
/// day, and both are applied here by the day asked about — so a past day is
/// resolved against the template as it stood then, not as it stands now.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test 2>&1 | grep -E 'error:|✘|Test run with'`
Expected: all pass. `excludesArchivedChores` still passes because its chore is archived from 2020.

- [ ] **Step 5: Commit**

Use the `commit-commands:commit` skill. Message: `Resolve each day against the schedule as it stood that day`.

---

### Task 3: Schedule writes take the day; the in-memory backend keeps history

**Files:**
- Modify: `Sources/ChoresCore/Repositories/Repositories.swift:90-98`
- Modify: `Sources/ChoresCore/Repositories/InMemory/InMemoryChoresBackend.swift:150-167, 292-332`
- Modify: `Sources/ChoresCore/Repositories/Supabase/SupabaseChoresBackend.swift:260-315` (signatures only; bodies in Task 5)
- Modify: `Tests/ChoresCoreTests/TestDoubles.swift:70-80, 265-274`
- Modify: `App/Chores/Parent/ScheduleEditorView.swift:170-204`
- Test: `Tests/ChoresCoreTests/InMemoryBackendTests.swift`

**Interfaces:**
- Consumes: Task 1's models.
- Produces, on `ChoresBackend`:
  ```swift
  func addScheduleEntry(familyID: UUID, profileID: UUID, choreID: UUID,
                        weekday: Int, from today: CalendarDay) async throws -> ScheduleEntry
  func removeScheduleEntry(id: UUID, on today: CalendarDay) async throws
  func copyDay(familyID: UUID, from fromWeekday: Int, to toWeekdays: [Int],
               on today: CalendarDay) async throws
  ```
  `fetchSnapshot(familyID:weekOf:)` returns template rows whose range overlaps the requested week, closed ones included.

- [ ] **Step 1: Write the failing tests**

In `Tests/ChoresCoreTests/InMemoryBackendTests.swift`, first update the two existing schedule tests to the new signatures. In the test ending at line 179 (the one asserting `first.id == second.id`), both `addScheduleEntry` calls gain `from: CalendarDay(year: 2026, month: 8, day: 10)`. In `copyDayReplacesTargetDayAssignments` (line 181) both `addScheduleEntry` calls gain `from: monday` and `copyDay` gains `on: monday`, with `let monday = CalendarDay(year: 2026, month: 8, day: 10)` declared at the top of the test and used in `fetchSnapshot` too; the `tuesday`/`wednesday` filters gain `&& $0.isCurrent`.

Then add:

```swift
    // MARK: - Schedule history

    struct ScheduleFixture {
        let backend: InMemoryChoresBackend
        let familyID: UUID
        let childID: UUID
        let bins: Chore
        let dishes: Chore
    }

    func makeScheduleFixture() async throws -> ScheduleFixture {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        let familyID = try await backend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await backend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let bins = try await backend.addChore(familyID: familyID, name: "Bins", icon: nil)
        let dishes = try await backend.addChore(familyID: familyID, name: "Dishes", icon: nil)
        return ScheduleFixture(backend: backend, familyID: familyID, childID: child.id,
                               bins: bins, dishes: dishes)
    }

    let day1 = CalendarDay(year: 2026, month: 8, day: 10)   // Monday
    var day5: CalendarDay { day1.adding(days: 4) }
    var day9: CalendarDay { day1.adding(days: 8) }

    func template(_ f: ScheduleFixture, weekOf day: CalendarDay) async throws -> [ScheduleEntry] {
        try await f.backend.fetchSnapshot(familyID: f.familyID, weekOf: day).template
    }

    @Test func addingStampsTheDayItWasAddedOn() async throws {
        let f = try await makeScheduleFixture()

        let entry = try await f.backend.addScheduleEntry(
            familyID: f.familyID, profileID: f.childID, choreID: f.bins.id, weekday: 1, from: day1)

        #expect(entry.validFrom == day1)
        #expect(entry.isCurrent)
    }

    @Test func removingOnALaterDayClosesTheEntryAndKeepsIt() async throws {
        let f = try await makeScheduleFixture()
        let entry = try await f.backend.addScheduleEntry(
            familyID: f.familyID, profileID: f.childID, choreID: f.bins.id, weekday: 1, from: day1)

        try await f.backend.removeScheduleEntry(id: entry.id, on: day5)

        let rows = try await template(f, weekOf: day1)
        #expect(rows.count == 1)
        #expect(rows.first?.validUntil == day5)
        #expect(rows.first?.isValid(on: day1) == true)
        #expect(rows.first?.isValid(on: day5) == false)
    }

    @Test func removingOnTheDayItWasAddedDeletesIt() async throws {
        let f = try await makeScheduleFixture()
        let entry = try await f.backend.addScheduleEntry(
            familyID: f.familyID, profileID: f.childID, choreID: f.bins.id, weekday: 1, from: day1)

        try await f.backend.removeScheduleEntry(id: entry.id, on: day1)

        #expect(try await template(f, weekOf: day1).isEmpty)
    }

    @Test func removingAnAlreadyClosedEntryChangesNothing() async throws {
        let f = try await makeScheduleFixture()
        let entry = try await f.backend.addScheduleEntry(
            familyID: f.familyID, profileID: f.childID, choreID: f.bins.id, weekday: 1, from: day1)
        try await f.backend.removeScheduleEntry(id: entry.id, on: day5)

        try await f.backend.removeScheduleEntry(id: entry.id, on: day9)

        #expect(try await template(f, weekOf: day1).first?.validUntil == day5)
    }

    @Test func addingBackOnTheDayItWasClosedReopensTheSameRow() async throws {
        let f = try await makeScheduleFixture()
        let entry = try await f.backend.addScheduleEntry(
            familyID: f.familyID, profileID: f.childID, choreID: f.bins.id, weekday: 1, from: day1)
        try await f.backend.removeScheduleEntry(id: entry.id, on: day5)

        let again = try await f.backend.addScheduleEntry(
            familyID: f.familyID, profileID: f.childID, choreID: f.bins.id, weekday: 1, from: day5)

        #expect(again.id == entry.id)
        #expect(again.isCurrent)
        #expect(again.validFrom == day1)
        #expect(try await template(f, weekOf: day1).count == 1)
    }

    @Test func addingBackAfterAnOlderCloseStartsANewRow() async throws {
        let f = try await makeScheduleFixture()
        let entry = try await f.backend.addScheduleEntry(
            familyID: f.familyID, profileID: f.childID, choreID: f.bins.id, weekday: 1, from: day1)
        try await f.backend.removeScheduleEntry(id: entry.id, on: day5)

        let again = try await f.backend.addScheduleEntry(
            familyID: f.familyID, profileID: f.childID, choreID: f.bins.id, weekday: 1, from: day9)

        #expect(again.id != entry.id)
        #expect(again.validFrom == day9)
        let rows = try await template(f, weekOf: day9)
        #expect(rows.count == 2)
        #expect(rows.filter(\.isCurrent).count == 1)
    }

    @Test func aSnapshotCarriesOnlyEntriesThatOverlapItsWeek() async throws {
        let f = try await makeScheduleFixture()
        let entry = try await f.backend.addScheduleEntry(
            familyID: f.familyID, profileID: f.childID, choreID: f.bins.id, weekday: 1, from: day1)
        try await f.backend.removeScheduleEntry(id: entry.id, on: day5)   // valid 10–14 Aug

        // The week of 17 Aug: the entry ended before it began.
        #expect(try await template(f, weekOf: day1.adding(days: 7)).isEmpty)
        // The week of 3 Aug: the entry begins after it ends.
        #expect(try await template(f, weekOf: day1.adding(days: -7)).isEmpty)
        // Its own week.
        #expect(try await template(f, weekOf: day1).count == 1)
    }

    @Test func copyDayClosesWhatItReplacesAndKeepsWhatMatches() async throws {
        let f = try await makeScheduleFixture()
        // Monday: Dishes. Tuesday: Bins and Dishes.
        _ = try await f.backend.addScheduleEntry(
            familyID: f.familyID, profileID: f.childID, choreID: f.dishes.id, weekday: 1, from: day1)
        let tuesdayBins = try await f.backend.addScheduleEntry(
            familyID: f.familyID, profileID: f.childID, choreID: f.bins.id, weekday: 2, from: day1)
        let tuesdayDishes = try await f.backend.addScheduleEntry(
            familyID: f.familyID, profileID: f.childID, choreID: f.dishes.id, weekday: 2, from: day1)

        try await f.backend.copyDay(familyID: f.familyID, from: 1, to: [2], on: day5)

        let tuesday = try await template(f, weekOf: day1).filter { $0.weekday == 2 }
        #expect(tuesday.count == 2)
        #expect(tuesday.first { $0.id == tuesdayBins.id }?.validUntil == day5)
        #expect(tuesday.first { $0.id == tuesdayDishes.id }?.isCurrent == true)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift build --build-tests 2>&1 | grep -E 'error:' | head`
Expected: `extra argument 'from' in call`, `extra argument 'on' in call`.

- [ ] **Step 3: Change the protocol**

`Sources/ChoresCore/Repositories/Repositories.swift:90-98` becomes:

```swift
    // MARK: Schedule

    /// `today` is the family's day, and the day the change takes effect from.
    /// An entry that already applies is returned as is; one closed today is
    /// reopened, so removing and re-adding within a day leaves no gap.
    func addScheduleEntry(familyID: UUID, profileID: UUID, choreID: UUID,
                          weekday: Int, from today: CalendarDay) async throws -> ScheduleEntry
    /// Closes the entry from `today` on, so days before it still resolve
    /// against it. An entry added today is deleted instead: it never applied.
    func removeScheduleEntry(id: UUID, on today: CalendarDay) async throws
    /// Replaces the assignments on each day in `toWeekdays` with those from
    /// `fromWeekday`, by the same close-and-add rules as the two above.
    /// Replaces rather than merges — copying a day onto a populated one should
    /// leave it looking like the source.
    func copyDay(familyID: UUID, from fromWeekday: Int, to toWeekdays: [Int],
                 on today: CalendarDay) async throws
```

- [ ] **Step 4: Update the forwarding and unavailable doubles**

`Tests/ChoresCoreTests/TestDoubles.swift`, in `ForwardingBackend` (lines 70-80):

```swift
    func addScheduleEntry(familyID: UUID, profileID: UUID, choreID: UUID,
                          weekday: Int, from today: CalendarDay) async throws -> ScheduleEntry {
        try await inner.addScheduleEntry(familyID: familyID, profileID: profileID,
                                        choreID: choreID, weekday: weekday, from: today)
    }
    func removeScheduleEntry(id: UUID, on today: CalendarDay) async throws {
        try await inner.removeScheduleEntry(id: id, on: today)
    }
    func copyDay(familyID: UUID, from fromWeekday: Int, to toWeekdays: [Int],
                 on today: CalendarDay) async throws {
        try await inner.copyDay(familyID: familyID, from: fromWeekday, to: toWeekdays, on: today)
    }
```

and in `UnavailableBackend` (lines 265-274):

```swift
    func addScheduleEntry(familyID: UUID, profileID: UUID, choreID: UUID,
                          weekday: Int, from today: CalendarDay) async throws -> ScheduleEntry {
        throw error
    }
    func removeScheduleEntry(id: UUID, on today: CalendarDay) async throws {
        throw error
    }
    func copyDay(familyID: UUID, from fromWeekday: Int, to toWeekdays: [Int],
                 on today: CalendarDay) async throws {
        throw error
    }
```

- [ ] **Step 5: Change the Supabase signatures only**

`Sources/ChoresCore/Repositories/Supabase/SupabaseChoresBackend.swift`: change the three method signatures at lines 260, 280 and 287 to match the protocol exactly (add `from today: CalendarDay`, `on today: CalendarDay`, `on today: CalendarDay`). Leave the bodies as they are; Task 5 rewrites them. Add `_ = today` as the first line of each body so the parameter is used and the compiler is quiet.

- [ ] **Step 6: Implement the rules in the in-memory backend**

Replace `// MARK: Schedule` through the end of `copyDay` (lines 292-332) in `Sources/ChoresCore/Repositories/InMemory/InMemoryChoresBackend.swift`:

```swift
    // MARK: Schedule

    public func addScheduleEntry(familyID: UUID, profileID: UUID, choreID: UUID,
                                 weekday: Int, from today: CalendarDay) async throws -> ScheduleEntry {
        withStore { store in
            Self.add(into: store, familyID: familyID, profileID: profileID,
                     choreID: choreID, weekday: weekday, today: today)
        }
    }

    public func removeScheduleEntry(id: UUID, on today: CalendarDay) async throws {
        withStore { store in Self.remove(from: store, id: id, today: today) }
    }

    public func copyDay(familyID: UUID, from fromWeekday: Int, to toWeekdays: [Int],
                        on today: CalendarDay) async throws {
        withStore { store in
            for target in toWeekdays where target != fromWeekday {
                for existing in store.template.values
                where existing.familyID == familyID && existing.weekday == target && existing.isCurrent {
                    Self.remove(from: store, id: existing.id, today: today)
                }
                let source = store.template.values.filter {
                    $0.familyID == familyID && $0.weekday == fromWeekday && $0.isCurrent
                }
                for entry in source {
                    Self.add(into: store, familyID: familyID, profileID: entry.profileID,
                             choreID: entry.choreID, weekday: target, today: today)
                }
            }
        }
    }

    /// Mirrors `schedule_entry_add`: return the open row, else reopen a row
    /// closed today, else insert. The partial unique index on open rows is
    /// what the first branch stands in for.
    private static func add(into store: Store, familyID: UUID, profileID: UUID,
                            choreID: UUID, weekday: Int, today: CalendarDay) -> ScheduleEntry {
        let matching = store.template.values.filter {
            $0.profileID == profileID && $0.choreID == choreID && $0.weekday == weekday
        }
        if let open = matching.first(where: \.isCurrent) {
            return open
        }
        if var closedToday = matching.first(where: { $0.validUntil == today }) {
            closedToday.validUntil = nil
            store.template[closedToday.id] = closedToday
            return closedToday
        }
        let entry = ScheduleEntry(id: UUID(), familyID: familyID, profileID: profileID,
                                  choreID: choreID, weekday: weekday, validFrom: today)
        store.template[entry.id] = entry
        return entry
    }

    /// Mirrors `schedule_entry_remove`: delete a row added today, close an open
    /// one, leave a closed one alone.
    private static func remove(from store: Store, id: UUID, today: CalendarDay) {
        guard var entry = store.template[id], entry.isCurrent else { return }
        if entry.validFrom == today {
            store.template[id] = nil
            return
        }
        entry.validUntil = today
        store.template[id] = entry
    }
```

Then make `fetchSnapshot` (lines 150-167) return the overlapping rows:

```swift
    public func fetchSnapshot(familyID: UUID,
                             weekOf day: CalendarDay) async throws -> FamilySnapshot {
        let week = WeekCalendar.isoWeek(containing: day)
        let weekDays = Set(week)
        let monday = week.first!, sunday = week.last!
        return try withStore { store in
            guard let family = store.families[familyID] else {
                throw ChoresBackendError.underlying("no such family")
            }
            return FamilySnapshot(
                family: family,
                profiles: store.profiles.values.filter { $0.familyID == familyID },
                chores: store.chores.values.filter { $0.familyID == familyID },
                // Every row whose range touches the week, closed ones included,
                // so a past day in it resolves against the template of its day.
                template: store.template.values.filter {
                    $0.familyID == familyID
                        && $0.validFrom <= sunday
                        && ($0.validUntil.map { $0 > monday } ?? true)
                },
                completions: store.completions.filter {
                    $0.familyID == familyID && weekDays.contains($0.dueOn)
                },
                fetchedAt: Date())
        }
    }
```

- [ ] **Step 7: Pass the day from the editor**

`App/Chores/Parent/ScheduleEditorView.swift`: in `assign` (line 173) add `from: store.today` after `weekday: selectedWeekday`; in `remove` (line 185) the call becomes `backend.removeScheduleEntry(id: entry.id, on: store.today)`; in `copy` (line 196) add `on: store.today` after `to: Array(targets)`.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test 2>&1 | grep -E 'error:|✘|Test run with'`
Expected: all pass, including the eight new `InMemoryBackendTests` and the two updated ones. `FamilyStoreTests` and `SessionViewModelTests` still pass — they never call the schedule writes.

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | grep -E 'error:|BUILD'`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 9: Commit**

Use the `commit-commands:commit` skill. Message: `Close a removed schedule entry from today instead of deleting it`.

---

### Task 4: The migration, the RPCs, and their pgTAP proof

**Files:**
- Create: `supabase/migrations/20260921100000_schedule_history.sql`
- Create: `supabase/tests/03_schedule_history.sql`
- Modify: `supabase/tests/01_rls_and_rpcs.sql:117-120, 403-405`
- Modify: `supabase/tests/02_evening_reminder.sql:69-90` (and every later `insert into public.schedule_entries` in that file)

**Interfaces:**
- Produces (SQL, all `security invoker`, granted to `authenticated`):
  - `public.schedule_entry_add(p_family_id uuid, p_profile_id uuid, p_chore_id uuid, p_weekday int, p_today date) returns public.schedule_entries`
  - `public.schedule_entry_remove(p_id uuid, p_today date) returns void`
  - `public.schedule_copy_day(p_family_id uuid, p_from int, p_to int[], p_today date) returns void`
  - `public.schedule_entries.valid_from date not null`, `valid_until date null`; `public.chores.archived_on date null`; `is_archived` is gone.
  - `public.family_undone_count(uuid, date)` unchanged in signature, now range-aware.

- [ ] **Step 1: Write the failing pgTAP tests**

Create `supabase/tests/03_schedule_history.sql`:

```sql
-- Schedule history: validity ranges on the template, the three RPCs that
-- maintain them, and the undone count reading through them.
--
-- Every rule here is one the in-memory backend mirrors in Swift. If one of
-- these changes, InMemoryBackendTests changes with it. Run with:
--   supabase db reset && supabase test db

begin;
set local search_path to public, extensions;

select plan(27);

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
-- Fixtures. One family in Helsinki: a parent, a child, two chores.
-- 2026-08-10 is a Monday.
-- ---------------------------------------------------------------------------

insert into auth.users (id) values
  ('a0000000-0000-0000-0000-000000000001'),  -- P1, parent
  ('a0000000-0000-0000-0000-000000000003');  -- C1, child

insert into public.families (id, name, timezone) values
  ('11111111-1111-1111-1111-111111111111', 'Koti', 'Europe/Helsinki');

insert into public.profiles (id, family_id, auth_user_id, display_name, role) values
  ('aaaa0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'a0000000-0000-0000-0000-000000000001', 'P1', 'parent'),
  ('aaaa0000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   'a0000000-0000-0000-0000-000000000003', 'C1', 'child');

insert into public.chores (id, family_id, name, archived_on) values
  ('cccc0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Bins',   null),
  ('cccc0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Dishes', null);

-- ---------------------------------------------------------------------------
-- The columns and the index
-- ---------------------------------------------------------------------------

select has_column('public', 'schedule_entries', 'valid_from',  'schedule_entries.valid_from exists');
select has_column('public', 'schedule_entries', 'valid_until', 'schedule_entries.valid_until exists');
select has_column('public', 'chores', 'archived_on', 'chores.archived_on exists');
select hasnt_column('public', 'chores', 'is_archived', 'chores.is_archived is gone');

select throws_ok(
  $$insert into public.schedule_entries (family_id, profile_id, chore_id, weekday, valid_from)
    values ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
            'cccc0000-0000-0000-0000-000000000001', 1, null)$$,
  '23502', null, 'valid_from is required');

select throws_ok(
  $$insert into public.schedule_entries (family_id, profile_id, chore_id, weekday, valid_from, valid_until)
    values ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
            'cccc0000-0000-0000-0000-000000000001', 1, '2026-08-10', '2026-08-10')$$,
  '23514', null, 'a range must end after it begins');

-- A closed row and an open row may share a (profile, chore, weekday); two open rows may not.
insert into public.schedule_entries (id, family_id, profile_id, chore_id, weekday, valid_from, valid_until) values
  ('ee000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'aaaa0000-0000-0000-0000-000000000003', 'cccc0000-0000-0000-0000-000000000002', 1, '2026-07-01', '2026-07-15'),
  ('ee000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'aaaa0000-0000-0000-0000-000000000003', 'cccc0000-0000-0000-0000-000000000002', 1, '2026-08-01', null);
select pass('a closed and an open row for one triple coexist');
select throws_ok(
  $$insert into public.schedule_entries (family_id, profile_id, chore_id, weekday, valid_from)
    values ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
            'cccc0000-0000-0000-0000-000000000002', 1, '2026-08-05')$$,
  '23505', null, 'but not two open rows');
delete from public.schedule_entries where id in
  ('ee000000-0000-0000-0000-000000000001', 'ee000000-0000-0000-0000-000000000002');

-- ---------------------------------------------------------------------------
-- schedule_entry_add / schedule_entry_remove, as the parent
-- ---------------------------------------------------------------------------

select tests.auth_as('a0000000-0000-0000-0000-000000000001');

-- Day 1: add Bins on Monday.
create temp table t as
  select * from public.schedule_entry_add(
    '11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
    'cccc0000-0000-0000-0000-000000000001', 1, date '2026-08-10');
select is((select valid_from from t), date '2026-08-10', 'add stamps valid_from with p_today');
select is((select valid_until from t), null::date, 'and leaves valid_until open');

-- Adding again returns the same open row.
select is(
  (select id from public.schedule_entry_add(
    '11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
    'cccc0000-0000-0000-0000-000000000001', 1, date '2026-08-12')),
  (select id from t),
  'adding an entry that already applies returns it unchanged');
select is((select count(*)::int from public.schedule_entries
            where chore_id = 'cccc0000-0000-0000-0000-000000000001'), 1, 'and inserts nothing');

-- Day 5: remove it. Closed, not deleted.
select public.schedule_entry_remove((select id from t), date '2026-08-14');
select is((select valid_until from public.schedule_entries where id = (select id from t)),
          date '2026-08-14', 'removing on a later day closes the entry from that day');

-- Removing a closed entry again does nothing.
select public.schedule_entry_remove((select id from t), date '2026-08-20');
select is((select valid_until from public.schedule_entries where id = (select id from t)),
          date '2026-08-14', 'removing an already closed entry leaves its close day alone');

-- Day 5 still: add it back. The same row reopens.
select is(
  (select id from public.schedule_entry_add(
    '11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
    'cccc0000-0000-0000-0000-000000000001', 1, date '2026-08-14')),
  (select id from t),
  'adding back on the close day reopens the same row');
select is((select valid_until from public.schedule_entries where id = (select id from t)),
          null::date, 'and it is open again');
select is((select valid_from from public.schedule_entries where id = (select id from t)),
          date '2026-08-10', 'with its original first day');

-- Close it again on day 5, then add on day 9: a new row.
select public.schedule_entry_remove((select id from t), date '2026-08-14');
create temp table t2 as
  select * from public.schedule_entry_add(
    '11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
    'cccc0000-0000-0000-0000-000000000001', 1, date '2026-08-18');
select isnt((select id from t2), (select id from t), 'adding after an older close starts a new row');
select is((select valid_from from t2), date '2026-08-18', 'from p_today');
select is((select count(*)::int from public.schedule_entries
            where chore_id = 'cccc0000-0000-0000-0000-000000000001'), 2, 'both rows remain');

-- An entry added and removed on the same day never existed.
select public.schedule_entry_remove((select id from t2), date '2026-08-18');
select is((select count(*)::int from public.schedule_entries where id = (select id from t2)), 0,
          'removing on the day it was added deletes it');

-- ---------------------------------------------------------------------------
-- schedule_copy_day
-- ---------------------------------------------------------------------------

-- Monday: Dishes. Tuesday: Bins and Dishes. All from day 1.
select public.schedule_entry_add(
  '11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
  'cccc0000-0000-0000-0000-000000000002', 1, date '2026-08-10');
create temp table tue_bins as
  select * from public.schedule_entry_add(
    '11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
    'cccc0000-0000-0000-0000-000000000001', 2, date '2026-08-10');
create temp table tue_dishes as
  select * from public.schedule_entry_add(
    '11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
    'cccc0000-0000-0000-0000-000000000002', 2, date '2026-08-10');

select public.schedule_copy_day('11111111-1111-1111-1111-111111111111', 1, array[2], date '2026-08-14');

select is((select valid_until from public.schedule_entries where id = (select id from tue_bins)),
          date '2026-08-14', 'copy-day closes a target entry the source lacks');
select is((select valid_until from public.schedule_entries where id = (select id from tue_dishes)),
          null::date, 'and leaves a matching one open');
select is((select count(*)::int from public.schedule_entries where weekday = 2 and valid_until is null), 1,
          'so Tuesday now looks like Monday');

-- ---------------------------------------------------------------------------
-- A child may not
-- ---------------------------------------------------------------------------

select tests.auth_as('a0000000-0000-0000-0000-000000000003');
select throws_ok(
  $$select public.schedule_entry_add(
      '11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
      'cccc0000-0000-0000-0000-000000000002', 3, date '2026-08-10')$$,
  '42501', null, 'a child cannot add to the schedule through the RPC');

-- ---------------------------------------------------------------------------
-- family_undone_count reads through the ranges
-- ---------------------------------------------------------------------------

select tests.as_admin();
delete from public.schedule_entries;

-- Bins on Monday, valid 10–14 Aug (closed on the 14th). Dishes on Monday, open.
-- Dishes archived on Monday 17 Aug.
insert into public.schedule_entries (family_id, profile_id, chore_id, weekday, valid_from, valid_until) values
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
   'cccc0000-0000-0000-0000-000000000001', 1, '2026-08-10', '2026-08-14'),
  ('11111111-1111-1111-1111-111111111111', 'aaaa0000-0000-0000-0000-000000000003',
   'cccc0000-0000-0000-0000-000000000002', 1, '2026-08-01', null);
update public.chores set archived_on = '2026-08-17' where id = 'cccc0000-0000-0000-0000-000000000002';

select is(public.family_undone_count('11111111-1111-1111-1111-111111111111', date '2026-08-10'), 2,
          'on 10 Aug both Monday chores are due');
select is(public.family_undone_count('11111111-1111-1111-1111-111111111111', date '2026-08-17'), 0,
          'on 17 Aug Bins is closed and Dishes is archived from that day');
select is(public.family_undone_count('11111111-1111-1111-1111-111111111111', date '2026-08-03'), 1,
          'on 3 Aug only Dishes existed');

select * from finish();
rollback;
```

- [ ] **Step 2: Update the older fixtures**

`supabase/tests/01_rls_and_rpcs.sql` line 117-120: the column list becomes `(family_id, profile_id, chore_id, weekday, valid_from)` and the values gain `, date '2026-08-01'` after the weekday. Line 403-405 likewise.

`supabase/tests/02_evening_reminder.sql` lines 69-72:

```sql
insert into public.chores (id, family_id, name, archived_on) values
  ('cccc0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Bins',    null),
  ('cccc0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Old',     date '2026-09-01'),
  ('cccc0000-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222', 'B chore', null);
```

and every `insert into public.schedule_entries (family_id, profile_id, chore_id, weekday) values` in that file gains `valid_from` as a fifth column with `date '2026-08-01'` as a fifth value on every row. The test dates in that file are all in September 2026, so every fixture entry is valid throughout.

- [ ] **Step 3: Run the SQL tests to verify they fail**

Run: `supabase db reset 2>&1 | tail -3 && supabase test db 2>&1 | tail -20`
Expected: `03_schedule_history.sql` fails at `has_column ... valid_from` and the fixture insert into `chores (…, archived_on)` errors; `01` and `02` fail on `valid_from` not existing.

- [ ] **Step 4: Write the migration**

Create `supabase/migrations/20260921100000_schedule_history.sql`:

```sql
-- Schedule history.
--
-- The template had no memory: ScheduleResolver read it as it stands now, so
-- archiving a chore on Thursday erased its Monday tick and moving a chore
-- rewrote what last week was due. Every template row now carries a validity
-- range and every chore the day it was archived, and the resolver applies
-- both by the day it is asked about.
--
-- valid_from is inclusive and valid_until exclusive; null = still current.
-- Removing an entry closes it rather than deleting it, except one added the
-- same day, which is deleted — it lived zero days. Those rules live in the
-- three RPCs below and are mirrored by InMemoryChoresBackend; pgTAP proves
-- the SQL, Swift Testing proves the mirror.
--
-- "Today" is the family's day and comes from the client as p_today. Postgres's
-- current_date is UTC, and a Helsinki parent editing at 01:00 Tuesday must
-- produce Tuesday.
--
-- See docs/superpowers/specs/2026-09-21-schedule-history-design.md.

-- ---------------------------------------------------------------------------
-- schedule_entries: the range
-- ---------------------------------------------------------------------------

alter table public.schedule_entries
  add column valid_from  date,
  add column valid_until date;

-- Backfill: the day the row was created, in its family's timezone. Right for
-- rows never edited, a guess for the rest, and the best guess there is.
update public.schedule_entries se
   set valid_from = (se.created_at at time zone f.timezone)::date
  from public.families f
 where f.id = se.family_id;

alter table public.schedule_entries
  alter column valid_from set not null,
  add constraint schedule_entries_range check (valid_until is null or valid_until > valid_from);

-- One open row per (child, chore, weekday); any number of closed ones.
alter table public.schedule_entries
  drop constraint schedule_entries_profile_id_chore_id_weekday_key;
create unique index schedule_entries_open_key
  on public.schedule_entries (profile_id, chore_id, weekday)
  where valid_until is null;

-- ---------------------------------------------------------------------------
-- chores: the archived-on day. is_archived goes last, after every reader of
-- it has been rewritten — a `language sql` body is parsed at creation.
-- ---------------------------------------------------------------------------

alter table public.chores add column archived_on date;

-- Existing archived chores: archived for their whole life, which is exactly
-- how the app has drawn them until now.
update public.chores c
   set archived_on = (c.created_at at time zone f.timezone)::date
  from public.families f
 where f.id = c.family_id and c.is_archived;

-- How many of a family's scheduled chores for `p_date` no child has ticked
-- off — now against the template as it stood on p_date.
create or replace function public.family_undone_count(p_family_id uuid, p_date date)
returns int language sql stable security definer set search_path = public
as $$
  select count(*)::int
    from public.schedule_entries se
    join public.chores   c on c.id = se.chore_id
                          and (c.archived_on is null or c.archived_on > p_date)
    join public.profiles p on p.id = se.profile_id and p.role = 'child'
   where se.family_id = p_family_id
     and se.weekday = extract(isodow from p_date)
     and se.valid_from <= p_date
     and (se.valid_until is null or se.valid_until > p_date)
     and not exists (select 1 from public.completions co
                      where co.profile_id = se.profile_id
                        and co.chore_id   = se.chore_id
                        and co.due_on     = p_date);
$$;

alter table public.chores drop column is_archived;

-- ---------------------------------------------------------------------------
-- The three writes. All run as the caller: schedule_write RLS scopes them to
-- the caller's family and to parents, exactly as the direct writes they
-- replace were scoped.
-- ---------------------------------------------------------------------------

-- Return the open row; else reopen a row closed today; else insert from today.
-- Reopening means remove-then-add within a day leaves no one-day gap.
create or replace function public.schedule_entry_add(
  p_family_id uuid, p_profile_id uuid, p_chore_id uuid, p_weekday int, p_today date)
returns public.schedule_entries language plpgsql security invoker set search_path = public
as $$
declare v_row public.schedule_entries;
begin
  select * into v_row from public.schedule_entries
   where profile_id = p_profile_id and chore_id = p_chore_id and weekday = p_weekday
     and valid_until is null;
  if found then return v_row; end if;

  -- At most one row per triple can be closed on any given day: closing the
  -- open row is the only way to make one, and there is only ever one open row.
  update public.schedule_entries set valid_until = null
   where profile_id = p_profile_id and chore_id = p_chore_id and weekday = p_weekday
     and valid_until = p_today
  returning * into v_row;
  if found then return v_row; end if;

  insert into public.schedule_entries (family_id, profile_id, chore_id, weekday, valid_from)
  values (p_family_id, p_profile_id, p_chore_id, p_weekday, p_today)
  returning * into v_row;
  return v_row;
end $$;

-- Delete a row added today; close an open one from today; leave a closed one.
create or replace function public.schedule_entry_remove(p_id uuid, p_today date)
returns void language plpgsql security invoker set search_path = public
as $$
begin
  delete from public.schedule_entries where id = p_id and valid_from = p_today;
  if found then return; end if;

  update public.schedule_entries set valid_until = p_today
   where id = p_id and valid_until is null;
end $$;

-- Each target ends up looking like the source: its open entries are removed
-- and the source's open entries added, both by the rules above, so an entry
-- the two days share is closed and reopened in place.
create or replace function public.schedule_copy_day(
  p_family_id uuid, p_from int, p_to int[], p_today date)
returns void language plpgsql security invoker set search_path = public
as $$
declare
  v_target int;
  v_entry  record;
begin
  foreach v_target in array p_to loop
    continue when v_target = p_from;

    for v_entry in
      select id from public.schedule_entries
       where family_id = p_family_id and weekday = v_target and valid_until is null
    loop
      perform public.schedule_entry_remove(v_entry.id, p_today);
    end loop;

    for v_entry in
      select profile_id, chore_id from public.schedule_entries
       where family_id = p_family_id and weekday = p_from and valid_until is null
    loop
      perform public.schedule_entry_add(p_family_id, v_entry.profile_id, v_entry.chore_id,
                                        v_target, p_today);
    end loop;
  end loop;
end $$;

-- Signed-in phones only. RLS does the rest.
revoke execute on function public.schedule_entry_add(uuid, uuid, uuid, int, date) from public, anon;
revoke execute on function public.schedule_entry_remove(uuid, date)               from public, anon;
revoke execute on function public.schedule_copy_day(uuid, int, int[], date)      from public, anon;
grant  execute on function public.schedule_entry_add(uuid, uuid, uuid, int, date) to authenticated;
grant  execute on function public.schedule_entry_remove(uuid, date)               to authenticated;
grant  execute on function public.schedule_copy_day(uuid, int, int[], date)      to authenticated;
```

- [ ] **Step 5: Confirm the constraint name before trusting the drop**

Run: `supabase db reset 2>&1 | tail -3`
Expected: the reset applies every migration including this one without error. If it fails on `drop constraint schedule_entries_profile_id_chore_id_weekday_key`, find the real name with `psql "$(supabase status -o env | grep DB_URL | cut -d= -f2-)" -c '\d public.schedule_entries'` — run the inner command on its own first and paste its output — and correct the migration.

- [ ] **Step 6: Run the SQL tests to verify they pass**

Run: `supabase test db 2>&1 | tail -20`
Expected: three files, all `ok`, `03_schedule_history.sql` reporting 27 of 27. If the child-RPC test reports a different SQLSTATE than `42501`, read what it reports: the `insert` under `schedule_write` RLS must raise `42501`; anything else means the function ran as definer or a policy is missing.

- [ ] **Step 7: Commit**

Use the `commit-commands:commit` skill. Message: `Keep the schedule's history in the database`.

Tell the user in the task summary that this migration is ready to be pushed to production by them, and that it rewrites a unique constraint on a live table.

---

### Task 5: The Supabase backend speaks the new schema

**Files:**
- Modify: `Sources/ChoresCore/Repositories/Supabase/SupabaseChoresBackend.swift:144-145, 249-315, 427-449`
- Test: `Tests/ChoresCoreTests/SupabaseIntegrationTests.swift:170-228`

**Interfaces:**
- Consumes: Task 3's protocol; Task 4's RPCs and columns.
- Produces: `SupabaseChoresBackend` conforming fully; `ChoreUpdate` carries `archived_on`.

- [ ] **Step 1: Update the integration test**

In `Tests/ChoresCoreTests/SupabaseIntegrationTests.swift`, the big round-trip test (lines ~170-228): every `addScheduleEntry(...)` gains `from: monday`; `copyDay(... to: [3])` gains `on: monday`; the `wednesday` filter (line 225) gains `&& $0.isCurrent`. Line 213's `#expect(snapshot.template.count == 2)` stays as is. Then, directly after the archiving block (after line 213), add:

```swift
        // Archived from Monday: not due on Monday, still due the day before.
        #expect(snapshot.chores.first { $0.id == bins.id }?.isArchived(on: monday) == true)
        #expect(snapshot.chores.first { $0.id == bins.id }?.isArchived(on: monday.adding(days: -1)) == false)

        // Removing an entry on a later day closes it and keeps it; adding it
        // back that same day reopens the very same row.
        let binsEntry = try #require(snapshot.template.first { $0.choreID == bins.id && $0.weekday == 1 })
        let friday = monday.adding(days: 4)
        try await parent.removeScheduleEntry(id: binsEntry.id, on: friday)
        snapshot = try await parent.fetchSnapshot(familyID: familyID, weekOf: monday)
        #expect(snapshot.template.first { $0.id == binsEntry.id }?.validUntil == friday)

        let reopened = try await parent.addScheduleEntry(
            familyID: familyID, profileID: child.id, choreID: bins.id, weekday: 1, from: friday)
        #expect(reopened.id == binsEntry.id)
        #expect(reopened.isCurrent)
```

(Where the test already binds `bins`, `child`, `parent`, `familyID`, `monday` and `snapshot` — check the names at the top of that test and use them.)

- [ ] **Step 2: Run the integration test to verify it fails**

With the local stack up (`supabase start`), run: `SUPABASE_INTEGRATION=1 SUPABASE_ANON_KEY=<anon key from supabase status> swift test --filter SupabaseIntegrationTests 2>&1 | grep -E '✘|Expectation failed|error' | head`
Expected: the `updateChore` call fails — the payload still sends `is_archived`, a column that no longer exists — or, if it gets past that, the `removeScheduleEntry` assertion fails because the old body deletes the row.

- [ ] **Step 3: Fetch overlapping rows**

`Sources/ChoresCore/Repositories/Supabase/SupabaseChoresBackend.swift` lines 144-145 become:

```swift
            // Every template row whose range touches the week, closed ones
            // included, so a past day in it resolves against its own template.
            async let template: [ScheduleEntry] = client.from("schedule_entries")
                .select().eq("family_id", value: familyID)
                .lte("valid_from", value: lastDay)
                .or("valid_until.is.null,valid_until.gt.\(firstDay)")
                .execute().value
```

- [ ] **Step 4: Send `archived_on`**

Replace `ChoreUpdate` (lines 427-436):

```swift
/// `archivedOn` is sent as an explicit `null` when nil — that is what
/// un-archiving is — so it is encoded by hand rather than left to
/// `encodeIfPresent`.
private struct ChoreUpdate: Encodable {
    let name: String
    let icon: String?
    let archivedOn: CalendarDay?

    enum CodingKeys: String, CodingKey {
        case name, icon
        case archivedOn = "archived_on"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(icon, forKey: .icon)
        try container.encode(archivedOn, forKey: .archivedOn)
    }
}
```

and in `updateChore` (line 251) construct it with `archivedOn: chore.archivedOn` instead of `isArchived: chore.isArchived`.

- [ ] **Step 5: Call the RPCs**

Replace `// MARK: Schedule` through the end of `copyDay` (lines 258-315):

```swift
    // MARK: Schedule

    // The three schedule writes are RPCs: each is several statements that
    // must not interleave with another parent's, and the partial unique
    // index on open rows is one PostgREST's `on_conflict` cannot target.
    // The rules — return, reopen or insert; delete or close — live in
    // 20260921100000_schedule_history.sql.

    public func addScheduleEntry(familyID: UUID, profileID: UUID, choreID: UUID,
                                 weekday: Int, from today: CalendarDay) async throws -> ScheduleEntry {
        try await run {
            try await client
                .rpc("schedule_entry_add", params: ScheduleEntryAddParams(
                    familyID: familyID, profileID: profileID, choreID: choreID,
                    weekday: weekday, today: today))
                .single()
                .execute()
                .value
        }
    }

    public func removeScheduleEntry(id: UUID, on today: CalendarDay) async throws {
        try await run {
            _ = try await client
                .rpc("schedule_entry_remove", params: ScheduleEntryRemoveParams(id: id, today: today))
                .execute()
        }
    }

    public func copyDay(familyID: UUID, from fromWeekday: Int, to toWeekdays: [Int],
                        on today: CalendarDay) async throws {
        try await run {
            _ = try await client
                .rpc("schedule_copy_day", params: ScheduleCopyDayParams(
                    familyID: familyID, from: fromWeekday, to: toWeekdays, today: today))
                .execute()
        }
    }
```

Replace `NewScheduleEntry` (lines 438-449) with the three parameter payloads:

```swift
private struct ScheduleEntryAddParams: Encodable {
    let familyID: UUID
    let profileID: UUID
    let choreID: UUID
    let weekday: Int
    let today: CalendarDay

    enum CodingKeys: String, CodingKey {
        case familyID = "p_family_id"
        case profileID = "p_profile_id"
        case choreID = "p_chore_id"
        case weekday = "p_weekday"
        case today = "p_today"
    }
}

private struct ScheduleEntryRemoveParams: Encodable {
    let id: UUID
    let today: CalendarDay

    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case today = "p_today"
    }
}

private struct ScheduleCopyDayParams: Encodable {
    let familyID: UUID
    let from: Int
    let to: [Int]
    let today: CalendarDay

    enum CodingKeys: String, CodingKey {
        case familyID = "p_family_id"
        case from = "p_from"
        case to = "p_to"
        case today = "p_today"
    }
}
```

If `.single()` is not available on the RPC builder in the pinned supabase-swift, decode `[ScheduleEntry]` instead and return `rows.first`, throwing `ChoresBackendError.underlying("rpc returned no row")` when empty — the same shape `addChore` uses.

- [ ] **Step 6: Run the integration and unit tests to verify they pass**

Run: `SUPABASE_INTEGRATION=1 SUPABASE_ANON_KEY=<anon key> swift test --filter SupabaseIntegrationTests 2>&1 | grep -E '✘|✔ Test run|Expectation failed'`
Expected: all pass.

Run: `swift test 2>&1 | grep -E 'error:|✘|Test run with'`
Expected: all pass.

- [ ] **Step 7: Commit**

Use the `commit-commands:commit` skill. Message: `Write the schedule through the history-keeping RPCs`.

---

### Task 6: The editor shows the current template; the app builds and its UI tests pass

**Files:**
- Modify: `App/Chores/Parent/ScheduleEditorView.swift:21-33`
- Verify: `App/Chores/Parent/ChoresView.swift:190-200` (changed in Task 1)

**Interfaces:**
- Consumes: `ScheduleEntry.isCurrent` (Task 1).

- [ ] **Step 1: Filter the editor to current entries**

`App/Chores/Parent/ScheduleEditorView.swift` line 27 becomes:

```swift
            .filter { $0.profileID == child.id && $0.weekday == selectedWeekday && $0.isCurrent }
```

and the doc comment above `entries(for:)` gains one line:

```swift
    /// Only current entries: the snapshot also carries rows closed earlier in
    /// the week, which the resolver needs and the editor must not show.
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | grep -E 'error:|BUILD'`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Run the UI tests**

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | grep -E 'error:|Test Case.*failed|Executed|TEST (SUCCEEDED|FAILED)'`
Expected: `** TEST SUCCEEDED **`, 23 executed, 0 failures, 2 skipped (the screenshot captures). `ScheduleUITests` in particular still adds and removes an entry — it goes through the in-memory rules now, with the seeded `today`.

- [ ] **Step 4: Mark the spec implemented**

In `docs/superpowers/specs/2026-09-21-schedule-history-design.md`, change the `**Status:**` line to `Implemented 2026-MM-DD (fill in the date). Migration 20260921100000_schedule_history.sql awaits the user's push to production.`

- [ ] **Step 5: Commit**

Use the `commit-commands:commit` skill. Message: `Show only the current template in the schedule editor`.

---

## Self-review

**Spec coverage.** §2 ranges → Tasks 1, 4. Close/delete/reopen → Tasks 3 (Swift mirror), 4 (SQL). `is_archived` replaced, un-archive forgets → Tasks 1, 4, 5. Family's today from the client → Tasks 3, 5 (`store.today` at every call site). RPCs under RLS → Task 4, proved by the child test. Partial unique index → Task 4, proved. Backfill → Task 4. Overlap fetch → Tasks 3 (in-memory), 5 (Supabase). §3.3 `family_undone_count` → Task 4. §4 models and resolver → Tasks 1, 2. §4.1 `ChoresBackend` → Task 3; `updateChore` payload → Task 5; `ChoresView.setArchived` → Task 1 step 5. §6 testing table: resolver → Task 2; in-memory → Task 3; decoding → Task 1; pgTAP → Task 4; integration → Task 5; UI → Task 6. Seeds → Task 1 (`seedValidFrom`; the spec said "a year before the seeded today" — a fixed early day does the same job for the seed that has no `today`, and the spec is updated to say so).

**Placeholders.** None: every step carries its code or its exact command. The one conditional (`.single()` availability, Task 5 step 5) names both branches.

**Type consistency.** `from today:` / `on today:` labels match across protocol, in-memory, Supabase, doubles, editor and tests. `validFrom`/`validUntil`/`isCurrent`/`isValid(on:)` and `archivedOn`/`isArchived`/`isArchived(on:)` are spelled the same everywhere. RPC parameter names `p_family_id`, `p_profile_id`, `p_chore_id`, `p_weekday`, `p_today`, `p_id`, `p_from`, `p_to` match between the migration, the pgTAP calls (positional) and the Swift payloads.
