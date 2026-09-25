# Week Wrap-up Card Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A dismissable week wrap-up card on the kid screen and the parent Family screen, shown Sunday 18:00 through Monday, reporting the current week on Sunday and the previous week on Monday.

**Architecture:** The snapshot fetch widens to two ISO weeks so Monday has last week's data. A pure `WeekWrapUp` type in ChoresCore decides whether the card is due, which week it reports, its dismissal key and the copy thresholds. Two SwiftUI cards render from that plus the existing per-day progress in `FamilyStore`; dismissal is an `@AppStorage` string holding the reported week's key.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Test`, `#expect`), Supabase Swift client, Xcode string catalog.

**Spec:** `docs/superpowers/specs/2026-09-25-week-wrap-up-design.md`

## Global Constraints

- No database migration. The shipped build must keep working unchanged.
- Window is Sunday **18:00** local in the family's time zone through Monday **23:59:59**. Sunday reports the week containing today, Monday the previous week.
- One dismissal per reported week; the key is the ISO week of the reported Monday, e.g. `2026-W39`.
- Card hidden when the reported week has zero chores scheduled (kid: for that child; parent: for the whole family).
- Fetch window is exactly two ISO weeks: previous Monday through this Sunday.
- All user-facing text goes through the string catalog with English and Finnish. Never hardcode Finnish.
- Type: medium weight for headings, regular for body, never bold. Colours only from `Theme`.
- No timer. No week review screen. No link from the card.
- Commit messages are one imperative sentence, no prefix, matching `git log`. Use the `commit-commands:commit` skill for every commit. Never push.
- Shell commands in this plan use single quotes; never `cd` before a git command.
- Unit tests: `swift test` from the repo root. App build: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' build`.

## Review Focus

1. **The week spanning New Year.** Reported Monday 2026-12-28 must key as `2026-W53`, not `2027-W01` or `2026-W01`. Test in Task 1.
2. **The Sunday DST ends in Helsinki** (2026-10-25, clocks back at 04:00). 18:00 that day must still open the window: the hour comes from the calendar in the family's zone, not from arithmetic on UTC. Test in Task 1.
3. **Same instant, different zone.** 18:00 Helsinki on a Sunday is 15:00 UTC; a family in UTC gets no card yet. Test in Task 1.
4. **A snapshot cached by the shipped build has one week in it.** On Monday the template still resolves last week (entries are open since their `validFrom`) but completions are missing, so the parent card can say 0 % until the refresh lands. Accepted in the spec; the stale banner sits above the card. Manual check in Task 10.
5. **A completion from two weeks ago must not leak in.** The window is exactly two weeks. Test in Task 2.

---

### Task 1: `WeekWrapUp` in ChoresCore

**Files:**
- Create: `Sources/ChoresCore/Calendar/WeekWrapUp.swift`
- Create: `Tests/ChoresCoreTests/WeekWrapUpTests.swift`

**Interfaces:**
- Consumes: `CalendarDay`, `WeekCalendar.isoWeek(containing:)`.
- Produces: `WeekWrapUp` (`moment`, `week`, `key`), `WeekWrapUp.current(now:timeZone:)`, `WeekWrapUp.percent(done:total:)`, `WeekWrapUp.kidVerdict(done:total:)`, `WeekWrapUp.tone(done:total:)`. Tasks 8 and 9 call all of these.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter WeekWrapUpTests`
Expected: compile error, `cannot find 'WeekWrapUp' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Whether the week wrap-up card is due, and which week it reports on.
///
/// The card lives from Sunday 18:00 through the end of Monday, in the family's
/// time zone. Sunday reports the week that is ending; Monday reports the week
/// that has just ended — the same week, so the two moments share one `key` and
/// one dismissal.
///
/// A pure function over a clock, like `ScheduleResolver`: no store, no SwiftUI,
/// so every boundary is a unit test.
public struct WeekWrapUp: Equatable, Sendable {
    public enum Moment: Sendable {
        case sundayEvening
        case monday
    }

    public let moment: Moment
    /// The seven days reported on, Monday first.
    public let week: [CalendarDay]
    /// The reported ISO week, e.g. "2026-W39". What a dismissal remembers.
    public let key: String

    /// nil outside Sunday 18:00 … Monday 23:59:59 in `timeZone`.
    public static func current(now: Date, timeZone: TimeZone) -> WeekWrapUp? {
        let today = CalendarDay(now, in: timeZone)
        switch today.isoWeekday {
        case 7:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            // The hour as the family's clock shows it, so the Sunday the clocks
            // change is no different from any other.
            guard calendar.component(.hour, from: now) >= 18 else { return nil }
            return WeekWrapUp(moment: .sundayEvening, week: WeekCalendar.isoWeek(containing: today))
        case 1:
            return WeekWrapUp(moment: .monday, week: WeekCalendar.isoWeek(containing: today.adding(days: -7)))
        default:
            return nil
        }
    }

    private init(moment: Moment, week: [CalendarDay]) {
        self.moment = moment
        self.week = week
        self.key = Self.key(forWeekStarting: week[0])
    }

    /// ISO week-numbering year and week of `monday`, so the week that spans New
    /// Year keys by the year that owns it (2026-12-28 → "2026-W53").
    static func key(forWeekStarting monday: CalendarDay) -> String {
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = utc
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear],
                                                 from: monday.date(in: utc))
        return String(format: "%04d-W%02d", components.yearForWeekOfYear!, components.weekOfYear!)
    }

    // MARK: Copy rules

    /// Rounded to the nearest whole percent; 0 when nothing was scheduled.
    public static func percent(done: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(done) / Double(total) * 100).rounded())
    }

    /// The kid card's Monday line.
    public enum KidVerdict: Sendable {
        case complete, great, good, freshStart
    }

    /// Complete at 100 %, great from 80 %, good from 50 %, otherwise a fresh start.
    public static func kidVerdict(done: Int, total: Int) -> KidVerdict {
        guard total > 0 else { return .freshStart }
        if done == total { return .complete }
        let fraction = Double(done) / Double(total)
        if fraction >= 0.8 { return .great }
        if fraction >= 0.5 { return .good }
        return .freshStart
    }

    /// The colour of a child's percentage on the parent card.
    public enum Tone: Sendable {
        case complete, warn, neutral
    }

    /// Complete at 100 %, warn under 60 %, neutral otherwise — and neutral for
    /// a child with nothing scheduled, who shows no percentage at all.
    public static func tone(done: Int, total: Int) -> Tone {
        guard total > 0 else { return .neutral }
        if done == total { return .complete }
        return Double(done) / Double(total) < 0.6 ? .warn : .neutral
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter WeekWrapUpTests`
Expected: 10 tests pass.

- [ ] **Step 5: Commit**

Use `commit-commands:commit` with files `Sources/ChoresCore/Calendar/WeekWrapUp.swift`, `Tests/ChoresCoreTests/WeekWrapUpTests.swift` and message: `Decide when the week wrap-up is due and which week it reports`

---

### Task 2: Fetch two ISO weeks

**Files:**
- Modify: `Sources/ChoresCore/Repositories/Supabase/SupabaseChoresBackend.swift:129-156`
- Modify: `Sources/ChoresCore/Repositories/InMemory/InMemoryChoresBackend.swift:150-175`
- Modify: `Sources/ChoresCore/Repositories/Repositories.swift:63-65` (doc comment)
- Modify: `Tests/ChoresCoreTests/InMemoryBackendTests.swift:319-331, 351-370`

**Interfaces:**
- Consumes: `ChoresBackend.fetchSnapshot(familyID:weekOf:)`, unchanged signature.
- Produces: a `FamilySnapshot` whose `completions` and `template` cover the previous Monday through this Sunday. Task 3 relies on it.

- [ ] **Step 1: Update the two tests whose expectations move, and add the leak test**

Replace `aSnapshotCarriesOnlyEntriesThatOverlapItsWeek` (line 319) with:

```swift
    @Test func aSnapshotCarriesOnlyEntriesThatOverlapItsTwoWeeks() async throws {
        let f = try await makeScheduleFixture()
        let entry = try await f.backend.addScheduleEntry(
            familyID: f.familyID, profileID: f.childID, choreID: f.bins.id, weekday: 1, from: day1)
        try await f.backend.removeScheduleEntry(id: entry.id, on: day5)   // valid 10–14 Aug

        // The week of 24 Aug fetches 17–30 Aug: the entry ended before it began.
        #expect(try await template(f, weekOf: day1.adding(days: 14)).isEmpty)
        // The week of 3 Aug fetches 27 Jul – 9 Aug: the entry begins after it ends.
        #expect(try await template(f, weekOf: day1.adding(days: -7)).isEmpty)
        // The week of 17 Aug fetches 10–23 Aug, which is the entry's own week too.
        #expect(try await template(f, weekOf: day1.adding(days: 7)).count == 1)
        // Its own week.
        #expect(try await template(f, weekOf: day1).count == 1)
    }
```

Replace `snapshotContainsOnlyTheRequestedWeeksCompletions` (line 351) with:

```swift
    @Test func snapshotCarriesThisWeekAndLastWeekButNotTwoWeeksAgo() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        let familyID = try await backend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await backend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let chore = try await backend.addChore(familyID: familyID, name: "Bins", icon: nil)

        let thisWeek = CalendarDay(year: 2026, month: 8, day: 12)      // Wed
        let lastWeek = CalendarDay(year: 2026, month: 8, day: 5)       // Wed before
        let twoWeeksAgo = CalendarDay(year: 2026, month: 8, day: 2)    // the Sunday before that
        for day in [thisWeek, lastWeek, twoWeeksAgo] {
            try await backend.complete(familyID: familyID, profileID: child.id,
                                       choreID: chore.id, dueOn: day, completedBy: child.id)
        }

        let snapshot = try await backend.fetchSnapshot(familyID: familyID, weekOf: thisWeek)
        #expect(Set(snapshot.completions.map(\.dueOn)) == [thisWeek, lastWeek])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter InMemoryBackendTests`
Expected: `aSnapshotCarriesOnlyEntriesThatOverlapItsTwoWeeks` fails on the week-of-17-Aug line (count is 0), `snapshotCarriesThisWeekAndLastWeekButNotTwoWeeksAgo` fails (only `thisWeek` present).

- [ ] **Step 3: Widen the in-memory window**

In `InMemoryChoresBackend.swift`, replace lines 152–154:

```swift
        // Two ISO weeks: the previous one and the one containing `day`, so
        // Monday's wrap-up can report the week that has just ended.
        let week = WeekCalendar.isoWeek(containing: day)
        let monday = week.first!.adding(days: -7), sunday = week.last!
```

and the completions filter (line 170–172) to a range check:

```swift
                completions: store.completions.filter {
                    $0.familyID == familyID && $0.dueOn >= monday && $0.dueOn <= sunday
                },
```

The template filter already uses `monday` and `sunday`; it needs no change. Delete the now-unused `weekDays` line.

- [ ] **Step 4: Widen the Supabase window**

In `SupabaseChoresBackend.swift`, replace lines 132–134:

```swift
            // Two ISO weeks: the previous one and the one containing `day`, so
            // Monday's wrap-up can report the week that has just ended.
            let week = WeekCalendar.isoWeek(containing: day)
            let firstDay = ChoresJSON.encodedDay(week.first!.adding(days: -7))
            let lastDay = ChoresJSON.encodedDay(week.last!)
```

The template and completions queries already use `firstDay` and `lastDay`; nothing else changes.

- [ ] **Step 5: Update the protocol's doc comment**

In `Repositories.swift`, above `fetchSnapshot` (line 65):

```swift
    /// The family graph plus two ISO weeks of schedule and completions: the
    /// week containing `day` and the one before it.
    func fetchSnapshot(familyID: UUID, weekOf day: CalendarDay) async throws -> FamilySnapshot
```

- [ ] **Step 6: Run the whole suite**

Run: `swift test`
Expected: all pass. (`FamilyStoreTests`, `SnapshotCacheTests` and `SupabaseIntegrationTests` do not assert the window's width; if any other test now sees an extra row, fix the test's expectation, not the window.)

- [ ] **Step 7: Commit**

Use `commit-commands:commit` with the four files and message: `Fetch the previous week alongside the current one`

---

### Task 3: `FamilyStore.now` and `weekProgress`

**Files:**
- Modify: `Sources/ChoresCore/ViewModels/FamilyStore.swift:49-52, 134-139`
- Modify: `Tests/ChoresCoreTests/FamilyStoreTests.swift` (append two tests after `progressReflectsCompletions`, line 98)

**Interfaces:**
- Produces: `public var now: Date` and `public func weekProgress(for profileID: UUID, in days: [CalendarDay]) -> (done: Int, total: Int)`. Tasks 8 and 9 call both.

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func nowIsTheInjectedClock() async throws {
        let fixture = try await makeFixture()
        #expect(fixture.store.now == FamilyStoreTests.mondayNoon)
    }

    /// The fixture assigns Bins every Monday from 10 Aug, so the week before has
    /// nothing scheduled. This proves the sum; the previous-week data path itself
    /// is proven by the backend (Task 2) and the seed (Task 4).
    @Test func weekProgressSumsTheDaysItIsGiven() async throws {
        let fixture = try await makeFixture()
        try await fixture.backend.complete(
            familyID: fixture.familyID, profileID: fixture.childID,
            choreID: fixture.choreID, dueOn: monday, completedBy: fixture.childID)
        await fixture.store.start()

        let thisWeek = WeekCalendar.isoWeek(containing: monday)
        let lastWeek = WeekCalendar.isoWeek(containing: monday.adding(days: -7))
        #expect(fixture.store.weekProgress(for: fixture.childID, in: thisWeek) == (done: 1, total: 1))
        #expect(fixture.store.weekProgress(for: fixture.childID, in: lastWeek) == (done: 0, total: 0))
        #expect(fixture.store.weekProgress(for: fixture.childID, in: lastWeek + thisWeek) == (done: 1, total: 1))
        #expect(fixture.store.weekProgress(for: fixture.childID, in: []) == (done: 0, total: 0))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter FamilyStoreTests`
Expected: compile error, `value of type 'FamilyStore' has no member 'now'`.

- [ ] **Step 3: Implement**

After `today` (line 52) add:

```swift
    /// The injected clock. Views read this rather than `Date()`, so a fixture
    /// launched with a frozen clock draws the same screen every time.
    public var now: Date { clock() }
```

After `progress(for:on:)` (line 139) add:

```swift
    /// `progress(for:on:)` summed over `days` — a week's worth for the wrap-up card.
    public func weekProgress(for profileID: UUID, in days: [CalendarDay]) -> (done: Int, total: Int) {
        days.reduce(into: (done: 0, total: 0)) { sum, day in
            let progress = progress(for: profileID, on: day)
            sum.done += progress.done
            sum.total += progress.total
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter FamilyStoreTests`
Expected: all pass.

- [ ] **Step 5: Commit**

Use `commit-commands:commit` with both files and message: `Let the store add a week up and tell the time`

---

### Task 4: The demo seed fills last week

**Files:**
- Modify: `Sources/ChoresCore/Repositories/InMemory/InMemoryChoresBackend+Seed.swift:59-67, 134-155`
- Modify: `Tests/ChoresCoreTests/InMemoryBackendTests.swift` (append one test at the end of the suite)

**Interfaces:**
- Consumes: `seedDemoFamily(...)`, unchanged signature.
- Produces: previous-week completions on the screenshot fixture. Task 10 photographs them.

- [ ] **Step 1: Write the failing test**

```swift
    @Test func theDemoSeedGivesEachChildADifferentLastWeek() async throws {
        let backend = InMemoryChoresBackend()
        // Wednesday 12 Aug 2026; last week is Mon 3 – Sun 9 Aug.
        let today = CalendarDay(year: 2026, month: 8, day: 12)
        let parent = backend.seedDemoFamily(
            familyName: "Home", parentName: "Mum",
            childNames: ["Ada", "Oscar", "Iris"], childColors: ["#9084da"],
            choreNames: ["Bins", "Dishes", "Vacuum", "Make bed", "Feed the cat", "Laundry"],
            today: today, claimingChildAt: nil)

        let snapshot = try await backend.fetchSnapshot(familyID: parent.familyID, weekOf: today)
        let lastWeek = Set(WeekCalendar.isoWeek(containing: today.adding(days: -7)))
        func lastWeekDone(_ child: Profile) -> Int {
            snapshot.completions.filter { $0.profileID == child.id && lastWeek.contains($0.dueOn) }.count
        }
        let children = snapshot.children   // sorted by sortOrder
        // Three chores a day, seven days: 21 scheduled per child.
        #expect(lastWeekDone(children[0]) == 21)
        #expect(lastWeekDone(children[1]) == 19)
        #expect(lastWeekDone(children[2]) == 11)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter theDemoSeedGivesEachChildADifferentLastWeek`
Expected: fails, every count is 0.

- [ ] **Step 3: Seed the previous week**

In the doc comment (lines 59–67) add a bullet:

```swift
    /// - Last week is complete for the first child, two short for the second and
    ///   about half done for the rest, so Monday's wrap-up card has a spread to show.
```

Inside `withStore`, after the existing `for dayOffset in 0..<today.isoWeekday { … }` loop (ends line 155) and still inside `for (childIndex, child) in children.enumerated()`, add:

```swift
                // Last week, Monday to Sunday.
                for dayOffset in 0..<7 {
                    let day = monday.adding(days: dayOffset - 7)
                    let doneCount: Int
                    switch childIndex {
                    case 0: doneCount = assigned.count
                    // Two days one short, so 19 of 21 — a "great week", not a legend.
                    case 1: doneCount = (dayOffset == 2 || dayOffset == 5) ? assigned.count - 1 : assigned.count
                    // Two and one on alternate days: 11 of 21.
                    default: doneCount = dayOffset.isMultiple(of: 2) ? 2 : 1
                    }
                    for chore in assigned.prefix(doneCount) {
                        store.completions.append(Completion(
                            id: UUID(), familyID: family.id, profileID: child.id,
                            choreID: chore.id, dueOn: day,
                            completedAt: day.date(in: family.timeZone),
                            completedBy: child.id))
                    }
                }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test`
Expected: all pass. If `theDemoSeedGivesEachChildADifferentLastWeek` fails on `children[2]`, check the `default` arm: with `assigned.count == 3`, `min(3, chores.count)` is 3, so `prefix(2)` and `prefix(1)` give 2+1+2+1+2+1+2 = 11.

- [ ] **Step 5: Commit**

Use `commit-commands:commit` with both files and message: `Give the demo family a last week worth wrapping up`

---

### Task 5: A frozen clock for fixtures

**Files:**
- Modify: `App/Chores/AppEnvironment.swift:6-19, 56-66, 111-168`
- Modify: `App/Chores/Kid/KidRootView.swift:16-20`
- Modify: `App/Chores/Parent/ParentRootView.swift:32-36`

**Interfaces:**
- Consumes: `FamilyStore.init(backend:cache:outbox:familyID:clock:)`.
- Produces: `AppEnvironment.clock: @Sendable () -> Date` and the launch argument `-frozenNow <ISO 8601>`. Task 10 launches with it.

- [ ] **Step 1: Add the clock to `AppEnvironment`**

Change the stored properties and initialiser (lines 7–19):

```swift
    let backend: any ChoresBackend
    let snapshotCache: SnapshotCache
    let outbox: Outbox
    let appleTokens: any AppleTokenProviding
    let pushRegistrar: PushRegistrar
    /// What every `FamilyStore` tells the time by. The real clock, except on a
    /// fixture launched with `-frozenNow`.
    let clock: @Sendable () -> Date

    init(backend: any ChoresBackend, directory: URL, appleTokens: any AppleTokenProviding,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.backend = backend
        self.snapshotCache = SnapshotCache(directory: directory)
        self.outbox = Outbox(directory: directory, backend: backend)
        self.appleTokens = appleTokens
        self.pushRegistrar = PushRegistrar(backend: backend, environment: Self.pushEnvironment)
        self.clock = clock
    }
```

- [ ] **Step 2: Parse the argument**

After `screenshotKidFlag` (line 57) add:

```swift
    /// Pins the fixture's clock: `-frozenNow 2026-09-27T18:30:00+03:00`. The
    /// simulator's own clock cannot be moved, and the week wrap-up card only
    /// exists on Sunday evening and Monday, so this is the only way to see it —
    /// or to photograph it. Read only on the in-memory fixture paths; the live
    /// app ignores it.
    static let frozenNowFlag = "-frozenNow"

    private static var frozenNow: Date? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: frozenNowFlag),
              index + 1 < arguments.count else { return nil }
        return ISO8601DateFormatter().date(from: arguments[index + 1])
    }
```

- [ ] **Step 3: Use it on the fixture paths**

In `live()`, replace the screenshot branch (lines 122–140):

```swift
        if arguments.contains(screenshotParentFlag) || arguments.contains(screenshotKidFlag) {
            let content = screenshotFamily
            let now = frozenNow ?? Date()
            let backend = InMemoryChoresBackend()
            backend.seedDemoFamily(
                familyName: content.family,
                parentName: content.parent,
                childNames: content.children,
                childColors: ProfilePalette.options,
                choreNames: content.chores,
                today: CalendarDay(now, in: .current),
                // The second child, whose day is halfway done — the most
                // informative of the three to photograph.
                claimingChildAt: arguments.contains(screenshotKidFlag) ? 1 : nil)
            return AppEnvironment(
                backend: backend,
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString),
                appleTokens: StubAppleTokenProvider(),
                clock: { now })
        }
```

And the `-ui-testing-kid` branch (lines 141–151), so a kid UI test can also freeze time:

```swift
        if arguments.contains(uiTestKidFlag) {
            let now = frozenNow ?? Date()
            let backend = InMemoryChoresBackend()
            backend.seedClaimedChild(childName: "Kid",
                                     choreNames: ["Bins", "Dishes"],
                                     onISOWeekdays: Array(1...7))
            return AppEnvironment(
                backend: backend,
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString),
                appleTokens: StubAppleTokenProvider(),
                clock: { now })
        }
```

Leave `.preview()`, the lost-session branch and the live branch on the default clock.

- [ ] **Step 4: Thread the clock into both stores**

`KidRootView.swift` lines 16–20:

```swift
        let store = FamilyStore(
            backend: environment.backend,
            cache: environment.snapshotCache,
            outbox: environment.outbox,
            familyID: profile.familyID,
            clock: environment.clock)
```

`ParentRootView.swift` lines 32–36: the same five arguments.

- [ ] **Step 5: Build the app**

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | grep -E 'error:|BUILD'`
Expected: `** BUILD SUCCEEDED **`, no `error:` lines.

- [ ] **Step 6: Commit**

Use `commit-commands:commit` with the three files and message: `Let a fixture launch with a frozen clock`

---

### Task 6: String catalog entries and the spec's copy amendment

**Files:**
- Modify: `App/Chores/Localizable.xcstrings`
- Modify: `docs/superpowers/specs/2026-09-25-week-wrap-up-design.md` (section 5 table)

**Interfaces:**
- Produces: the sixteen keys below, exactly as spelled. Tasks 8 and 9 use them verbatim as `Text(...)` keys.

**Why two keys changed from the spec.** SwiftUI builds a `LocalizedStringKey` with interpolations into a format string and runs it through `String(format:)`. A bare `%` followed by a space and a letter, as in `"\(pct)% of chores"`, is then read as a format directive. So the percentage is formatted as a *string* first (`40%` in English, `40 %` in Finnish, from `FormatStyle.percent`) and interpolated as `%@`. The spec's two `%lld%%` keys become `%@` keys; update the spec table to match.

- [ ] **Step 1: Write the insertion script to the scratchpad**

Save as `<scratchpad>/add_wrapup_strings.py`:

```python
import json, sys
from collections import OrderedDict

PATH = 'App/Chores/Localizable.xcstrings'
NEW = OrderedDict([
    ("Week complete!", "Viikko valmis!"),
    ("Nearly the end of the week", "Viikko on melkein paketissa"),
    ("Last week", "Viime viikko"),
    ("You ticked every single chore. Nice one.", "Teit ihan joka ikisen tehtävän. Hienoa!"),
    ("%lld left to tick — there's still time before bed.", "Vielä %lld tekemättä — ehdit hyvin ennen nukkumaanmenoa."),
    ("Every chore, every day. Legend.", "Joka tehtävä, joka päivä. Legenda."),
    ("Great week! Keep it rolling.", "Mahtava viikko! Samaan malliin."),
    ("Good going. New week, fresh start.", "Hyvin menee. Uusi viikko, uusi alku."),
    ("New week, fresh start!", "Uusi viikko, uusi alku!"),
    ("This week, wrapped up", "Viikko paketissa"),
    ("This week so far", "Viikko tähän mennessä"),
    ("Every chore for this week is ticked.", "Kaikki tämän viikon tehtävät on tehty."),
    ("%@ of this week's chores ticked so far.", "%@ tämän viikon tehtävistä on tehty."),
    ("%@ of chores were ticked, %@.", "%1$@ tehtävistä tehtiin, %2$@."),
    ("%lld of %lld", "%1$lld/%2$lld"),
    ("Dismiss", "Sulje"),
])

with open(PATH, encoding='utf-8') as f:
    doc = json.load(f, object_pairs_hook=OrderedDict)

strings = doc['strings']
for key in NEW:
    if key in strings:
        sys.exit(f'already present: {key}')

def entry(fi):
    return OrderedDict([("localizations", OrderedDict([
        ("fi", OrderedDict([("stringUnit", OrderedDict([("state", "translated"), ("value", fi)]))]))
    ]))])

# Slot each key in by casefold comparison against its neighbours, keeping
# every existing key exactly where Xcode left it.
items = list(strings.items())
for key, fi in NEW.items():
    index = next((i for i, (k, _) in enumerate(items) if k.casefold() > key.casefold()), len(items))
    items.insert(index, (key, entry(fi)))
doc['strings'] = OrderedDict(items)

with open(PATH, 'w', encoding='utf-8') as f:
    json.dump(doc, f, ensure_ascii=False, indent=2, separators=(',', ' : '))
```

- [ ] **Step 2: Run it and check the diff is insertions only**

Run: `python3 '<scratchpad>/add_wrapup_strings.py' && git diff --stat -- App/Chores/Localizable.xcstrings`
Expected: one file, roughly `160 +` and `0 -` (sixteen keys, ten lines each). If there are deletions, the separators or order drifted: `git checkout -- App/Chores/Localizable.xcstrings` and fix the script before rerunning.

- [ ] **Step 3: Amend the spec's copy table**

In section 5 of the spec, replace the two percent rows:

```markdown
| %@ of this week's chores ticked so far. | %@ tämän viikon tehtävistä on tehty. |
| %@ of chores were ticked, %@. | %1$@ tehtävistä tehtiin, %2$@. |
```

and the kid "left to tick" row's Finnish with `Vielä %lld tekemättä — ehdit hyvin ennen nukkumaanmenoa.`. Add one sentence above the table: "Percentages are formatted with `FormatStyle.percent` and interpolated as strings, so the keys carry `%@`, not `%lld%%`."

Also update section 4.3's copy table in the spec to `%@` in the same two lines.

- [ ] **Step 4: Commit**

Use `commit-commands:commit` with both files and message: `Say what the wrap-up card says, in English and Finnish`

---

### Task 7: Shared card pieces in the design system

**Files:**
- Create: `App/Chores/DesignSystem/WrapUpCard.swift`
- Modify: `App/Chores/DesignSystem/ScreenHeader.swift:32-52` (`ThinProgressBar`)

**Interfaces:**
- Produces: `View.wrapUpCard(bottomPadding:)`, `CardDismissButton(identifier:action:)`, and `ThinProgressBar(done:total:fill:)`. Tasks 8 and 9 use all three.

- [ ] **Step 1: Give `ThinProgressBar` a fill colour**

```swift
/// A 2pt capsule: track in neutral900, done-mint fill unless told otherwise.
struct ThinProgressBar: View {
    let done: Int
    let total: Int
    var fill: Color = Theme.done

    private var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.neutral900)
                Capsule().fill(fill)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 2)
        .animation(.snappy(duration: 0.35), value: fraction)
        // The headline above already says "2 of 4 done".
        .accessibilityHidden(true)
    }
}
```

- [ ] **Step 2: Create the container and dismiss button**

```swift
import SwiftUI

extension View {
    /// The wrap-up card's box: surface fill, 8pt corners, a 1pt neutral800
    /// edge, 14pt padding. The parent card ends in a list of rows and wants
    /// less at the bottom.
    func wrapUpCard(bottomPadding: CGFloat = 14) -> some View {
        self
            .padding(.top, 14)
            .padding(.horizontal, 14)
            .padding(.bottom, bottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(Theme.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(Theme.neutral800, lineWidth: 1)
            }
    }
}

/// The × in a card's top-right corner: a 32pt target around a 14pt glyph, pulled
/// into the card's padding so the glyph sits where the eye expects it.
struct CardDismissButton: View {
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.neutral600)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, -6)
        .padding(.trailing, -8)
        .accessibilityLabel(Text("Dismiss"))
        .accessibilityIdentifier(identifier)
    }
}
```

- [ ] **Step 3: Build the app**

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | grep -E 'error:|BUILD'`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

Use `commit-commands:commit` with both files and message: `Draw the box a wrap-up card sits in`

---

### Task 8: The kid card

**Files:**
- Create: `App/Chores/Kid/KidWrapUpCard.swift`
- Modify: `App/Chores/Kid/KidDayView.swift:9-26, 41-45`

**Interfaces:**
- Consumes: `WeekWrapUp` (Task 1), `FamilyStore.now` / `weekProgress` (Task 3), `wrapUpCard()`, `CardDismissButton`, `ThinProgressBar(fill:)` (Task 7), `DayDot` (existing, `WeekStrip.swift:89`), `ChildHue`.
- Produces: `KidWrapUpCard(store:profile:hue:wrapUp:onDismiss:)`.

- [ ] **Step 1: Create the card**

```swift
import SwiftUI
import ChoresCore

/// Sunday evening's and Monday's card on the kid screen: how the week went,
/// in the child's own colour — mint once every chore is ticked.
struct KidWrapUpCard: View {
    let store: FamilyStore
    let profile: Profile
    let hue: ChildHue
    let wrapUp: WeekWrapUp
    let onDismiss: () -> Void

    private var progress: (done: Int, total: Int) {
        store.weekProgress(for: profile.id, in: wrapUp.week)
    }
    private var isComplete: Bool { progress.total > 0 && progress.done == progress.total }
    private var accent: Color { isComplete ? Theme.done : hue.base }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    title
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.text)
                    line
                        .font(.system(size: 13))
                        .lineSpacing(13 * 0.45)
                        .foregroundStyle(Theme.neutral300)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                CardDismissButton(identifier: "kidDay.wrapUp.dismiss", action: onDismiss)
            }

            HStack(spacing: 12) {
                Text("\(progress.done) of \(progress.total)")
                    .font(.system(size: 28, weight: .medium))
                    .tracking(-28 * 0.02)
                    .monospacedDigit()
                    .foregroundStyle(accent)
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    ForEach(wrapUp.week, id: \.self) { day in
                        DayDot(progress: store.progress(for: profile.id, on: day),
                               isFuture: store.eligibility(for: day) == .future,
                               isToday: day == store.today,
                               color: hue.base,
                               size: 9)
                    }
                }
                .accessibilityHidden(true)
            }

            ThinProgressBar(done: progress.done, total: progress.total, fill: accent)
        }
        .wrapUpCard()
        .accessibilityIdentifier("kidDay.wrapUp")
    }

    private var title: Text {
        switch wrapUp.moment {
        case .sundayEvening:
            return isComplete ? Text("Week complete!") : Text("Nearly the end of the week")
        case .monday:
            return Text("Last week")
        }
    }

    private var line: Text {
        switch wrapUp.moment {
        case .sundayEvening:
            if isComplete { return Text("You ticked every single chore. Nice one.") }
            return Text("\(progress.total - progress.done) left to tick — there's still time before bed.")
        case .monday:
            switch WeekWrapUp.kidVerdict(done: progress.done, total: progress.total) {
            case .complete:   return Text("Every chore, every day. Legend.")
            case .great:      return Text("Great week! Keep it rolling.")
            case .good:       return Text("Good going. New week, fresh start.")
            case .freshStart: return Text("New week, fresh start!")
            }
        }
    }
}
```

- [ ] **Step 2: Wire it into `KidDayView`**

Replace the property block and add an initialiser (lines 9–13 become):

```swift
struct KidDayView: View {
    let store: FamilyStore
    let profile: Profile
    @Binding var selectedDay: CalendarDay
    /// The reported week the child last dismissed, e.g. "2026-W39". Keyed by
    /// profile, so a device that changes hands does not carry a dismissal over.
    @AppStorage private var dismissedWrapUpKey: String

    init(store: FamilyStore, profile: Profile, selectedDay: Binding<CalendarDay>) {
        self.store = store
        self.profile = profile
        _selectedDay = selectedDay
        _dismissedWrapUpKey = AppStorage(wrappedValue: "", "wrapUpDismissedWeek.\(profile.id.uuidString)")
    }
```

Add a computed property next to `progress` (after line 26):

```swift
    /// The card that is due, unless it was dismissed or the week had nothing in it.
    private var wrapUp: WeekWrapUp? {
        guard let wrapUp = WeekWrapUp.current(now: store.now, timeZone: store.timeZone),
              wrapUp.key != dismissedWrapUpKey,
              store.weekProgress(for: profile.id, in: wrapUp.week).total > 0
        else { return nil }
        return wrapUp
    }
```

In `body`, between the stale card (`if store.isStale { … }`, ends line 44) and `WeekStrip`, insert:

```swift
                    if let wrapUp {
                        KidWrapUpCard(store: store, profile: profile, hue: hue, wrapUp: wrapUp) {
                            withAnimation(.snappy) { dismissedWrapUpKey = wrapUp.key }
                        }
                    }
```

- [ ] **Step 3: Build the app**

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | grep -E 'error:|BUILD'`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: See it on Sunday evening**

Run the kid screenshot fixture with a frozen clock on Sunday 27 Sep 2026 at 18:30 Helsinki. In Xcode, edit the Chores scheme's Run arguments to `-screenshots-kid -frozenNow 2026-09-27T18:30:00+03:00`, run on the iPhone 17 simulator. Expected: the card sits between the headline and the strip, titled "Nearly the end of the week", count in the child's colour (Teal, the second child), seven dots, a bar. Tap the ×: the card collapses. Stop and relaunch: it stays gone. Then change the argument to `2026-09-28T08:00:00+03:00`: "Last week", "Great week! Keep it rolling." (19 of 21 for the second child). Remove the arguments afterwards.

- [ ] **Step 5: Commit**

Use `commit-commands:commit` with both files and message: `Show the child how their week went`

---

### Task 9: The parent card

**Files:**
- Create: `App/Chores/Parent/FamilyWrapUpCard.swift`
- Modify: `App/Chores/Parent/FamilyView.swift:7-32, 46-49`

**Interfaces:**
- Consumes: `WeekWrapUp` (Task 1), `FamilyStore.now` / `weekProgress` (Task 3), `wrapUpCard(bottomPadding:)`, `CardDismissButton` (Task 7), `FadingRule(ramp:)` (existing, `Theme.swift:76`), `ChildHue`, `CalendarDay.formattedShort(in:)`.
- Produces: `FamilyWrapUpCard(store:children:wrapUp:onDismiss:)`.

- [ ] **Step 1: Create the card**

```swift
import SwiftUI
import ChoresCore

/// Sunday evening's and Monday's card on Family: the week's share ticked,
/// then one row per child. The line is honest — "every chore is ticked" only
/// when it is.
struct FamilyWrapUpCard: View {
    let store: FamilyStore
    let children: [Profile]
    let wrapUp: WeekWrapUp
    let onDismiss: () -> Void

    private struct Row: Identifiable {
        let child: Profile
        let progress: (done: Int, total: Int)
        var id: UUID { child.id }
    }

    private var rows: [Row] {
        children.map { Row(child: $0, progress: store.weekProgress(for: $0.id, in: wrapUp.week)) }
    }

    private var totals: (done: Int, total: Int) {
        rows.reduce(into: (done: 0, total: 0)) { sum, row in
            sum.done += row.progress.done
            sum.total += row.progress.total
        }
    }
    private var isComplete: Bool { totals.total > 0 && totals.done == totals.total }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    title
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.text)
                    line
                        .font(.system(size: 12))
                        .lineSpacing(12 * 0.45)
                        .foregroundStyle(Theme.neutral500)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                CardDismissButton(identifier: "family.wrapUp.dismiss", action: onDismiss)
            }

            VStack(spacing: 0) {
                ForEach(rows) { row in
                    childRow(row)
                }
            }
        }
        .wrapUpCard(bottomPadding: 8)
        .accessibilityIdentifier("family.wrapUp")
    }

    private func childRow(_ row: Row) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(ChildHue(hex: row.child.color).base)
                .frame(width: 8, height: 8)
            Text(row.child.displayName)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
            if row.progress.total == 0 {
                Text("Nothing scheduled")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.neutral300)
            } else {
                Text("\(row.progress.done) of \(row.progress.total)")
                    .font(.system(size: 14))
                    .monospacedDigit()
                    .foregroundStyle(Theme.neutral300)
                Text(percentText(WeekWrapUp.percent(done: row.progress.done, total: row.progress.total)))
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(toneColor(WeekWrapUp.tone(done: row.progress.done, total: row.progress.total)))
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .frame(minHeight: 36)
        .overlay(alignment: .top) { FadingRule(ramp: 24) }
    }

    private var title: Text {
        switch wrapUp.moment {
        case .sundayEvening: return isComplete ? Text("This week, wrapped up") : Text("This week so far")
        case .monday:        return Text("Last week")
        }
    }

    private var line: Text {
        let percent = percentText(WeekWrapUp.percent(done: totals.done, total: totals.total))
        switch wrapUp.moment {
        case .sundayEvening:
            if isComplete { return Text("Every chore for this week is ticked.") }
            return Text("\(percent) of this week's chores ticked so far.")
        case .monday:
            return Text("\(percent) of chores were ticked, \(weekRange).")
        }
    }

    /// "21 Sep – 27 Sep", the same shape as the Family header's kicker.
    private var weekRange: String {
        let timeZone = store.timeZone
        guard let monday = wrapUp.week.first, let sunday = wrapUp.week.last else { return "" }
        return "\(monday.formattedShort(in: timeZone)) – \(sunday.formattedShort(in: timeZone))"
    }

    /// "40%" in English, "40 %" in Finnish — the locale decides.
    private func percentText(_ percent: Int) -> String {
        (Double(percent) / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    private func toneColor(_ tone: WeekWrapUp.Tone) -> Color {
        switch tone {
        case .complete: return Theme.done
        case .warn:     return Theme.warn
        case .neutral:  return Theme.neutral300
        }
    }
}
```

- [ ] **Step 2: Wire it into `FamilyView`**

After `@Binding var selectedDay` (line 12) add:

```swift
    /// The reported week this parent last dismissed, e.g. "2026-W39".
    @AppStorage("wrapUpDismissedWeek") private var dismissedWrapUpKey = ""
```

After `totals(on:)` (line 32) add:

```swift
    /// The card that is due, unless it was dismissed or nobody had anything that week.
    private var wrapUp: WeekWrapUp? {
        guard let wrapUp = WeekWrapUp.current(now: store.now, timeZone: store.timeZone),
              wrapUp.key != dismissedWrapUpKey,
              children.contains(where: { store.weekProgress(for: $0.id, in: wrapUp.week).total > 0 })
        else { return nil }
        return wrapUp
    }
```

In `body`, between the stale card (ends line 48) and `WeekStrip`, insert:

```swift
                    if let wrapUp {
                        FamilyWrapUpCard(store: store, children: children, wrapUp: wrapUp) {
                            withAnimation(.snappy) { dismissedWrapUpKey = wrapUp.key }
                        }
                    }
```

- [ ] **Step 3: Build the app**

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | grep -E 'error:|BUILD'`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: See it on Monday**

Scheme Run arguments `-screenshots-parent -frozenNow 2026-09-28T08:00:00+03:00`. Expected: above the strip, "Last week", "81% of chores were ticked, 21 Sep – 27 Sep.", three rows: first child 21 of 21 in mint, second 19 of 21 neutral, third 11 of 21 in amber. Then `2026-09-27T18:30:00+03:00`: "This week so far" with the current week's share. Dismiss, relaunch, confirm it stays gone. Remove the arguments afterwards.

- [ ] **Step 5: Commit**

Use `commit-commands:commit` with both files and message: `Show the parent how the family's week went`

---

### Task 10: Whole-feature check

**Files:**
- Modify: `README.md:34` (unit test count)

- [ ] **Step 1: Run every unit test and record the count**

Run: `swift test 2>&1 | tail -3`
Expected: all pass. Note the total and update the `# 141 unit tests` comment in `README.md` to the new number.

- [ ] **Step 2: Run the UI tests**

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | grep -E 'Test Suite|error:|passed|failed' | tail -8`
Expected: every suite passes; the two screenshot captures report as skipped. The card never shows in these runs, since none launches with `-frozenNow`, so the existing assertions are unaffected.

- [ ] **Step 3: Finnish pass**

Scheme Run arguments `-screenshots-parent -frozenNow 2026-09-28T08:00:00+03:00 -AppleLanguages (fi) -AppleLocale fi_FI`. Expected: "Viime viikko", then "81 % tehtävistä tehtiin, " followed by the week range in the Finnish short date form, and rows with "21/21". Then the kid fixture on Sunday: "Viikko on melkein paketissa", "Vielä N tekemättä — …". Read the lines as a Finn would and note anything to change; the user reviews the copy in the plan's hand-off, so record the exact rendered text rather than editing the catalog here.

- [ ] **Step 4: The stale case from Review Focus 4**

Launch the parent fixture with `-frozenNow 2026-09-28T08:00:00+03:00`, then switch the argument to `2026-09-28T08:05:00+03:00` and relaunch: the fixture rebuilds from scratch each time, so this is only a sanity check that the card rebuilds too. There is no way to fake a one-week cached snapshot without a live backend; note in the hand-off that the behaviour is by design.

- [ ] **Step 5: Commit**

Use `commit-commands:commit` with `README.md` and message: `Count the wrap-up tests`
