# Child Reminders Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each child gets two local reminders — an afternoon heads-up and an evening nag — at times the parent sets per child, and each fires only when the child still has a chore unticked for the day.

**Architecture:** `ReminderSchedule` in `ChoresCore` becomes a pure function from a snapshot and a clock to dated plans over a fourteen-day horizon, reusing `ScheduleResolver` for what is still open; `ReminderScheduler` in the app renders those plans as one-shot `UNCalendarNotificationTrigger`s and re-renders on every snapshot change. The two times live on `profiles`, set from the child's edit sheet through the control the push plan built.

**Tech Stack:** Swift 6 / SwiftUI (iOS 17+), Swift Testing, `UNUserNotificationCenter`, XCUITest.

**Spec:** `docs/superpowers/specs/2026-09-17-child-reminders-design.md`. Depends on the shared foundation in `docs/superpowers/specs/2026-09-17-parent-evening-push-design.md` §3, built by Tasks 1, 2, 5 and 11 of `docs/superpowers/plans/2026-09-18-parent-evening-push.md`.

## Global Constraints

- **Prerequisite:** the push plan's Task 1 (`TimeOfDay`, `Profile` fields), Task 2 (`updateProfile` carries the times; in-memory defaults), Task 5 (the migration and trigger) and Task 11 (`ReminderTimeControl`) are merged. Nothing here creates those.
- Every user-facing string goes through `App/Chores/Localizable.xcstrings` with an `fi` value. Finnish values below are the spec's proposals, with "Tehtyjä?" already corrected to "Tehty?".
- Transport is local. No child device registers a push token.
- Times are in the family's timezone (`snapshot.family.timeZone`), never the device's.
- Shell commands use single quotes and no `cd` before `git`.
- Unit tests: `swift test`. UI tests: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' test`.
- Commit after every task with the `commit-commands:commit` skill; never push.

## File structure

| File | Responsibility |
|---|---|
| `Sources/ChoresCore/Notifications/ReminderSchedule.swift` | `ReminderPlan` (day, slot, time, remaining) and the pure `plans(for:snapshot:now:horizonDays:)` |
| `Tests/ChoresCoreTests/ReminderScheduleTests.swift` | Rewritten for dated, conditional plans |
| `App/Chores/Kid/ReminderScheduler.swift` | Renders plans as one-shot requests; no decisions |
| `App/Chores/Kid/KidRootView.swift` | Reschedules on any snapshot change |
| `Sources/ChoresCore/Repositories/InMemory/InMemoryChoresBackend+Seed.swift` | Seeded children carry the defaults |
| `App/Chores/Parent/EditChildSheet.swift` | Two `ReminderTimeControl` rows |
| `App/Chores/Localizable.xcstrings` | Evening title and body, sheet labels |
| `App/ChoresUITests/ChildRemindersUITests.swift` *(new)* | The edit-sheet round trip |

---

### Task 1: `ReminderSchedule` produces dated, conditional plans

**Files:**
- Modify: `Sources/ChoresCore/Notifications/ReminderSchedule.swift` (whole file)
- Test: `Tests/ChoresCoreTests/ReminderScheduleTests.swift` (whole file)

**Interfaces:**
- Consumes: `TimeOfDay(hour:minute:)`, `TimeOfDay(_:in:)`, `TimeOfDay.date(on:in:)`, `Profile.afternoonReminderAt`, `Profile.eveningReminderAt` (push plan Task 1); `ScheduleResolver.chores(for:on:template:chores:completions:)`, `CalendarDay(_:in:)`, `CalendarDay.adding(days:)`.
- Produces: `public struct ReminderPlan: Equatable, Sendable { enum Slot: String { afternoon, evening }; day: CalendarDay; slot: Slot; time: TimeOfDay; remaining: Int }` and `ReminderSchedule.plans(for profileID: UUID, snapshot: FamilySnapshot, now: Date, horizonDays: Int = 14) -> [ReminderPlan]`. The old `ReminderPlan(isoWeekday:choreCount:)` and `plans(for:snapshot:)` are removed.

- [ ] **Step 1: Replace the tests**

`Tests/ChoresCoreTests/ReminderScheduleTests.swift` becomes:

```swift
import Testing
import Foundation
@testable import ChoresCore

@Suite struct ReminderScheduleTests {

    let familyID = UUID()
    let childID = UUID()
    let otherChildID = UUID()
    let helsinki = TimeZone(identifier: "Europe/Helsinki")!

    /// Monday 21 September 2026. Helsinki is on summer time, UTC+3.
    let monday = CalendarDay(year: 2026, month: 9, day: 21)
    var tuesday: CalendarDay { monday.adding(days: 1) }
    var nextMonday: CalendarDay { monday.adding(days: 7) }

    let fifteen = TimeOfDay(hour: 15, minute: 0)
    let twenty = TimeOfDay(hour: 20, minute: 0)

    func at(_ hour: Int, _ minute: Int, on day: CalendarDay? = nil) -> Date {
        TimeOfDay(hour: hour, minute: minute).date(on: day ?? monday, in: helsinki)
    }

    func child(afternoon: TimeOfDay? = TimeOfDay(hour: 15, minute: 0),
               evening: TimeOfDay? = TimeOfDay(hour: 20, minute: 0)) -> Profile {
        Profile(id: childID, familyID: familyID, displayName: "Kid", role: .child,
                afternoonReminderAt: afternoon, eveningReminderAt: evening)
    }

    func chore(_ name: String, archived: Bool = false) -> Chore {
        Chore(id: UUID(), familyID: familyID, name: name, isArchived: archived)
    }

    func done(_ chore: Chore, on day: CalendarDay, by profile: UUID? = nil) -> Completion {
        Completion(id: UUID(), familyID: familyID, profileID: profile ?? childID,
                   choreID: chore.id, dueOn: day, completedBy: profile ?? childID)
    }

    func makeSnapshot(profile: Profile? = nil,
                      entries: [(profile: UUID, chore: Chore, weekday: Int)],
                      chores: [Chore],
                      completions: [Completion] = []) -> FamilySnapshot {
        FamilySnapshot(
            family: Family(id: familyID, name: "Koti", timezone: "Europe/Helsinki"),
            profiles: [profile ?? child()],
            chores: chores,
            template: entries.map {
                ScheduleEntry(id: UUID(), familyID: familyID, profileID: $0.profile,
                              choreID: $0.chore.id, weekday: $0.weekday)
            },
            completions: completions,
            fetchedAt: Date())
    }

    @Test func aDayWithChoresAheadOfBothTimesGetsBothReminders() {
        let bins = chore("Bins"), dishes = chore("Dishes")
        let snapshot = makeSnapshot(entries: [(childID, bins, 1), (childID, dishes, 1)],
                                    chores: [bins, dishes])

        let plans = ReminderSchedule.plans(for: childID, snapshot: snapshot, now: at(12, 0))

        #expect(plans.prefix(2).map { $0 } == [
            ReminderPlan(day: monday, slot: .afternoon, time: fifteen, remaining: 2),
            ReminderPlan(day: monday, slot: .evening, time: twenty, remaining: 2),
        ])
        // Two Mondays fall inside fourteen days.
        #expect(plans.count == 4)
        #expect(plans.map(\.day) == [monday, monday, nextMonday, nextMonday])
    }

    @Test func aSlotSetToNilProducesNoPlansForThatSlot() {
        let bins = chore("Bins")
        let snapshot = makeSnapshot(profile: child(evening: nil),
                                    entries: [(childID, bins, 1)], chores: [bins])

        let plans = ReminderSchedule.plans(for: childID, snapshot: snapshot, now: at(12, 0))

        #expect(plans.map(\.slot) == [.afternoon, .afternoon])
    }

    @Test func bothSlotsOffProducesNothing() {
        let bins = chore("Bins")
        let snapshot = makeSnapshot(profile: child(afternoon: nil, evening: nil),
                                    entries: [(childID, bins, 1)], chores: [bins])
        #expect(ReminderSchedule.plans(for: childID, snapshot: snapshot, now: at(12, 0)).isEmpty)
    }

    @Test func todaysSlotWhoseTimeHasPassedIsSkippedButTomorrowsIsNot() {
        let bins = chore("Bins")
        let snapshot = makeSnapshot(entries: [(childID, bins, 1), (childID, bins, 2)],
                                    chores: [bins])

        let plans = ReminderSchedule.plans(for: childID, snapshot: snapshot, now: at(16, 0))

        #expect(plans.first == ReminderPlan(day: monday, slot: .evening, time: twenty, remaining: 1))
        #expect(plans[1] == ReminderPlan(day: tuesday, slot: .afternoon, time: fifteen, remaining: 1))
    }

    @Test func aTimeEqualToNowCountsAsPassed() {
        let bins = chore("Bins")
        let snapshot = makeSnapshot(entries: [(childID, bins, 1)], chores: [bins])

        let plans = ReminderSchedule.plans(for: childID, snapshot: snapshot, now: at(15, 0))

        #expect(plans.first?.slot == .evening, "a reminder for this very minute would fire late or never")
    }

    @Test func aCompletedDayProducesNothingForThatDay() {
        let bins = chore("Bins"), dishes = chore("Dishes")
        let snapshot = makeSnapshot(entries: [(childID, bins, 1), (childID, dishes, 1)],
                                    chores: [bins, dishes],
                                    completions: [done(bins, on: monday), done(dishes, on: monday)])

        let plans = ReminderSchedule.plans(for: childID, snapshot: snapshot, now: at(12, 0))

        #expect(plans.map(\.day) == [nextMonday, nextMonday])
    }

    @Test func remainingCountsOnlyWhatIsStillOpen() {
        let bins = chore("Bins"), dishes = chore("Dishes")
        let snapshot = makeSnapshot(entries: [(childID, bins, 1), (childID, dishes, 1)],
                                    chores: [bins, dishes],
                                    completions: [done(bins, on: monday)])

        let plans = ReminderSchedule.plans(for: childID, snapshot: snapshot, now: at(12, 0))

        #expect(plans.first?.remaining == 1)
        #expect(plans[2].remaining == 2, "next Monday has no completions yet")
    }

    @Test func aParentTickingOnTheChildsBehalfCountsTheSame() {
        let bins = chore("Bins")
        let parentID = UUID()
        let snapshot = makeSnapshot(entries: [(childID, bins, 1)], chores: [bins],
                                    completions: [Completion(
                                        id: UUID(), familyID: familyID, profileID: childID,
                                        choreID: bins.id, dueOn: monday, completedBy: parentID)])

        let plans = ReminderSchedule.plans(for: childID, snapshot: snapshot, now: at(12, 0))

        #expect(plans.map(\.day) == [nextMonday, nextMonday])
    }

    @Test func archivedChoresDoNotCount() {
        let bins = chore("Bins"), old = chore("Old", archived: true)
        let snapshot = makeSnapshot(entries: [(childID, bins, 1), (childID, old, 1)],
                                    chores: [bins, old])

        #expect(ReminderSchedule.plans(for: childID, snapshot: snapshot, now: at(12, 0))
                    .first?.remaining == 1)
    }

    @Test func anotherChildsChoresDoNotCount() {
        let bins = chore("Bins")
        let snapshot = makeSnapshot(entries: [(otherChildID, bins, 1)], chores: [bins])
        #expect(ReminderSchedule.plans(for: childID, snapshot: snapshot, now: at(12, 0)).isEmpty)
    }

    @Test func aWeekdayWithNoEntriesProducesNothing() {
        let bins = chore("Bins")
        let snapshot = makeSnapshot(entries: [(childID, bins, 3)], chores: [bins])
        let wednesday = monday.adding(days: 2)

        let plans = ReminderSchedule.plans(for: childID, snapshot: snapshot, now: at(12, 0))

        #expect(plans.map(\.day) == [wednesday, wednesday,
                                     wednesday.adding(days: 7), wednesday.adding(days: 7)])
    }

    @Test func theHorizonIsExactlyTheGivenNumberOfDays() {
        let bins = chore("Bins")
        let snapshot = makeSnapshot(entries: (1...7).map { (childID, bins, $0) }, chores: [bins])

        let fortnight = ReminderSchedule.plans(for: childID, snapshot: snapshot, now: at(0, 30))
        let threeDays = ReminderSchedule.plans(for: childID, snapshot: snapshot, now: at(0, 30),
                                               horizonDays: 3)

        #expect(fortnight.count == 28)
        #expect(fortnight.last?.day == monday.adding(days: 13))
        #expect(threeDays.count == 6)
    }

    @Test func todayIsTheFamilysDayNotUTCs() {
        let bins = chore("Bins")
        let snapshot = makeSnapshot(entries: [(childID, bins, 1), (childID, bins, 2)],
                                    chores: [bins])

        // 00:01 Tuesday in Helsinki is 21:01 Monday in UTC.
        let justAfterMidnight = at(0, 1, on: tuesday)
        let plans = ReminderSchedule.plans(for: childID, snapshot: snapshot, now: justAfterMidnight)

        #expect(plans.first?.day == tuesday)
        #expect(!plans.contains { $0.day == monday }, "Monday is over in Helsinki, whatever UTC says")
    }

    @Test func justBeforeMidnightTodayIsStillToday() {
        let bins = chore("Bins")
        let snapshot = makeSnapshot(entries: [(childID, bins, 1), (childID, bins, 2)],
                                    chores: [bins])

        let plans = ReminderSchedule.plans(for: childID, snapshot: snapshot, now: at(23, 59))

        // Both of Monday's times have passed; Tuesday's have not.
        #expect(plans.first == ReminderPlan(day: tuesday, slot: .afternoon, time: fifteen, remaining: 1))
    }

    @Test func plansAreOrderedByDayThenSlot() {
        let bins = chore("Bins")
        let snapshot = makeSnapshot(entries: [(childID, bins, 1), (childID, bins, 2)],
                                    chores: [bins])

        let plans = ReminderSchedule.plans(for: childID, snapshot: snapshot, now: at(12, 0))

        #expect(plans.map { ($0.day, $0.slot) }.map { "\($0.0.day)-\($0.1)" }
                == ["21-afternoon", "21-evening", "22-afternoon", "22-evening",
                    "28-afternoon", "28-evening", "29-afternoon", "29-evening"])
    }

    @Test func anUnknownProfileProducesNothing() {
        let bins = chore("Bins")
        let snapshot = makeSnapshot(entries: [(childID, bins, 1)], chores: [bins])
        #expect(ReminderSchedule.plans(for: UUID(), snapshot: snapshot, now: at(12, 0)).isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ReminderScheduleTests`
Expected: compile errors — `ReminderPlan` has no `day:` initialiser, `plans(for:snapshot:now:)` does not exist.

- [ ] **Step 3: Rewrite `ReminderSchedule`**

`Sources/ChoresCore/Notifications/ReminderSchedule.swift` becomes:

```swift
import Foundation

/// One notification to schedule: which slot, on which day, at what time, and
/// how many of the child's chores are still open.
public struct ReminderPlan: Equatable, Sendable {
    public enum Slot: String, Sendable {
        /// "You have 2 chores today." — the heads-up.
        case afternoon
        /// "2 chores still unticked. Done them? Tick them off." — the nag.
        case evening
    }

    public let day: CalendarDay
    public let slot: Slot
    public let time: TimeOfDay
    public let remaining: Int

    public init(day: CalendarDay, slot: Slot, time: TimeOfDay, remaining: Int) {
        self.day = day
        self.slot = slot
        self.time = time
        self.remaining = remaining
    }
}

/// Works out which reminders a child's phone should have queued, kept here
/// rather than in the app target so the rules are testable without a simulator.
///
/// Pure: a snapshot and a clock in, dated plans out. The phone that runs this
/// is the one the child ticks on, so what it knows about completions is the
/// truth for its own child — except for a parent ticking on the child's behalf
/// before the phone next refreshes, which is the one gap the design accepts.
public enum ReminderSchedule {

    /// Two weeks: 28 notifications at most, under iOS's cap of 64, and long
    /// enough that a phone opened even weekly never runs dry.
    public static let horizonDays = 14

    /// Plans for the next `horizonDays` days starting today, in the family's
    /// timezone. A day contributes a plan per enabled slot when the child still
    /// has something open that day; today's slots whose time has passed are
    /// left out. Ordered by day, then afternoon before evening.
    public static func plans(for profileID: UUID,
                             snapshot: FamilySnapshot,
                             now: Date,
                             horizonDays: Int = horizonDays) -> [ReminderPlan] {
        guard let profile = snapshot.profiles.first(where: { $0.id == profileID }) else {
            return []
        }
        let timeZone = snapshot.family.timeZone
        let today = CalendarDay(now, in: timeZone)
        let wallClock = TimeOfDay(now, in: timeZone)
        let slots: [(ReminderPlan.Slot, TimeOfDay?)] = [
            (.afternoon, profile.afternoonReminderAt),
            (.evening, profile.eveningReminderAt),
        ]

        var plans: [ReminderPlan] = []
        for offset in 0..<horizonDays {
            let day = today.adding(days: offset)
            let remaining = ScheduleResolver.chores(
                for: profileID, on: day, template: snapshot.template,
                chores: snapshot.chores, completions: snapshot.completions)
                .filter { !$0.isCompleted }.count
            guard remaining > 0 else { continue }

            for (slot, time) in slots {
                guard let time else { continue }
                // A reminder for this very minute would fire late or never;
                // one for a minute that has gone is noise.
                if offset == 0 && !(wallClock < time) { continue }
                plans.append(ReminderPlan(day: day, slot: slot, time: time, remaining: remaining))
            }
        }
        return plans
    }
}
```

The snapshot carries only the current week's completions; that is enough, because a future day cannot have any — `CompletionEligibility.future` forbids ticking early — so for days beyond this week `remaining` is the entry count, which is right.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test`
Expected: all pass. (`ReminderScheduler` in the app target no longer compiles against this; Task 2 fixes it. `swift test` builds only the package.)

- [ ] **Step 5: Commit**

`commit-commands:commit` with the two files. Suggested subject: `Plan a child's reminders by the day, and only when something is open`.

---

### Task 2: `ReminderScheduler` renders one-shots, and reruns on every snapshot change

**Files:**
- Modify: `App/Chores/Kid/ReminderScheduler.swift` (whole file)
- Modify: `App/Chores/Kid/KidRootView.swift:38-45`
- Modify: `Sources/ChoresCore/Repositories/InMemory/InMemoryChoresBackend+Seed.swift:22-23` and wherever `seedDemoFamily` builds a child `Profile`
- Modify: `App/Chores/Localizable.xcstrings`

**Interfaces:**
- Consumes: `ReminderPlan`, `ReminderSchedule.plans(for:snapshot:now:)` (Task 1); `ChoresJSON.encodedDay(_:)`; `Notifications.requestAuthorization()` (push plan Task 10).
- Produces: `ReminderScheduler.reschedule(plans:timeZone:)` unchanged in name; pending identifiers `chores.reminder.<afternoon|evening>.<yyyy-mm-dd>`.

- [ ] **Step 1: Rewrite the scheduler**

`App/Chores/Kid/ReminderScheduler.swift` becomes:

```swift
import Foundation
import UserNotifications
import ChoresCore

/// The child's reminders, entirely on-device: no APNs, no certificates, no push
/// tokens on this side of the app. The parent's evening reminder is the push,
/// and lives on the server.
///
/// Renders plans; decides nothing. What to schedule is `ReminderSchedule`'s
/// call, in ChoresCore, where it is tested.
@MainActor
enum ReminderScheduler {

    /// Every request this app owns starts with this, so a reschedule can clear
    /// exactly its own and nothing else.
    private static let identifierPrefix = "chores."

    /// Replaces all previously scheduled reminders with the given plans. The
    /// "replace everything" shape is what makes this idempotent: ticking the
    /// last chore removes today's two, unticking puts back whichever is still
    /// ahead, and neither path has to know what was there before.
    static func reschedule(plans: [ReminderPlan], timeZone: TimeZone) async {
        let center = UNUserNotificationCenter.current()

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized ||
              settings.authorizationStatus == .provisional else { return }

        let existing = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: existing.map(\.identifier)
                .filter { $0.hasPrefix(identifierPrefix) })

        for plan in plans {
            let content = UNMutableNotificationContent()
            // One key with plural variations in the catalog, rather than a
            // ternary here: Finnish takes the partitive singular after a number
            // greater than one, which is a rule the catalog already knows.
            switch plan.slot {
            case .afternoon:
                content.title = String(localized: "Chores today")
                content.body = String(localized: "You have \(plan.remaining) chores today.")
            case .evening:
                content.title = String(localized: "Chores tonight")
                content.body = String(localized: "\(plan.remaining) chores still unticked. Done them? Tick them off.")
            }
            content.sound = .default

            var components = DateComponents()
            components.year = plan.day.year
            components.month = plan.day.month
            components.day = plan.day.day
            components.hour = plan.time.hour
            components.minute = plan.time.minute
            components.timeZone = timeZone

            let request = UNNotificationRequest(
                identifier: "\(identifierPrefix)reminder.\(plan.slot.rawValue).\(ChoresJSON.encodedDay(plan.day))",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))

            try? await center.add(request)
        }
    }
}
```

- [ ] **Step 2: Reschedule on any snapshot change**

In `App/Chores/Kid/KidRootView.swift`, replace the `.onChange(of: store.snapshot?.template)` modifier (lines 38–45) with:

```swift
            // Rescheduled on every change, not only the template's: a tick,
            // an untick, a schedule edit, or a changed reminder time all move
            // what should be queued. The recompute is a few dozen rows.
            .onChange(of: store.snapshot) { _, snapshot in
                guard let snapshot else { return }
                let plans = ReminderSchedule.plans(for: profile.id, snapshot: snapshot, now: Date())
                Task { await ReminderScheduler.reschedule(plans: plans,
                                                          timeZone: snapshot.family.timeZone) }
            }
```

- [ ] **Step 3: Seeded children carry the defaults**

In `InMemoryChoresBackend+Seed.swift`, `seedClaimedChild` builds the child as:

```swift
        let child = Profile(id: UUID(), familyID: family.id, authUserID: userID,
                            displayName: childName, role: .child,
                            afternoonReminderAt: TimeOfDay(hour: 15, minute: 0),
                            eveningReminderAt: TimeOfDay(hour: 20, minute: 0))
```

In `seedDemoFamily`, add the same two arguments to every `Profile(... role: .child ...)` it constructs. The parent it builds gets `eveningReminderAt: TimeOfDay(hour: 21, minute: 0)`. This is what the database trigger would have done; the seeds mirror it, as `addChild` already does.

- [ ] **Step 4: Strings**

Add to `App/Chores/Localizable.xcstrings`:

```json
    "Chores tonight" : {
      "localizations" : {
        "fi" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Illan tehtävät"
          }
        }
      }
    },
    "%lld chores still unticked. Done them? Tick them off." : {
      "localizations" : {
        "en" : {
          "variations" : {
            "plural" : {
              "one" : {
                "stringUnit" : {
                  "state" : "translated",
                  "value" : "1 chore still unticked. Done it? Tick it off."
                }
              },
              "other" : {
                "stringUnit" : {
                  "state" : "translated",
                  "value" : "%lld chores still unticked. Done them? Tick them off."
                }
              }
            }
          }
        },
        "fi" : {
          "variations" : {
            "plural" : {
              "one" : {
                "stringUnit" : {
                  "state" : "translated",
                  "value" : "1 tehtävä on vielä kuittaamatta. Tehty? Kuittaa se."
                }
              },
              "other" : {
                "stringUnit" : {
                  "state" : "translated",
                  "value" : "%lld tehtävää on vielä kuittaamatta. Tehty? Kuittaa ne."
                }
              }
            }
          }
        }
      }
    },
```

Keys in the catalog are sorted; place each where it belongs alphabetically.

- [ ] **Step 5: Build, run the unit and UI suites**

Run: `swift test` — expected: all pass.
Run: the UI suite (Global Constraints) — expected: all pass; `KidUITests` in particular, since the kid screen now reschedules on every tick (under `-ui-testing-kid` authorization is never requested, so `reschedule` returns at the guard).

- [ ] **Step 6: Try it on the simulator**

Launch the app in kid mode from Xcode with the `-ui-testing-kid` argument removed and a real local family, accept the permission, tick nothing, then in the debugger or with `print` confirm `UNUserNotificationCenter.current().pendingNotificationRequests()` holds `chores.reminder.afternoon.<today>` and `chores.reminder.evening.<today>` when both times are ahead; tick every chore and confirm both are gone. (Xcode's simulator delivers local notifications on time; setting a child's time two minutes ahead from a parent device is the quickest end-to-end check.)

- [ ] **Step 7: Commit**

`commit-commands:commit` with the four files. Suggested subject: `Queue a child's two reminders by the day, and drop them when the day is done`.

---

### Task 3: The two rows on the child's edit sheet

**Files:**
- Modify: `App/Chores/Parent/EditChildSheet.swift`
- Modify: `App/Chores/Localizable.xcstrings`
- Create: `App/ChoresUITests/ChildRemindersUITests.swift`

**Interfaces:**
- Consumes: `ReminderTimeControl(label:time:defaultTime:identifier:)` (push plan Task 11), `Profile.afternoonReminderAt`/`eveningReminderAt`, `backend.updateProfile` sending explicit nulls (push plan Task 2).

- [ ] **Step 1: Write the failing UI test**

Create `App/ChoresUITests/ChildRemindersUITests.swift`:

```swift
import XCTest

/// A child's two reminder times are the parent's to set, from the child's own
/// edit sheet. On by default; off sticks.
final class ChildRemindersUITests: ParentUITestCase {

    func testSwitchingAChildsEveningReminderOffSticks() {
        let app = launchIntoParentMode()
        addChild(app, named: "Kid")
        app.manageTab.tap()
        app.buttons["manage.people"].tap()

        app.buttons["people.child.Kid"].tap()
        let evening = app.switches["editChild.evening.toggle"]
        XCTAssertTrue(evening.waitForExistence(timeout: 5))
        XCTAssertEqual(evening.value as? String, "1", "a new child starts with both reminders on")
        XCTAssertEqual(app.switches["editChild.afternoon.toggle"].value as? String, "1")

        evening.tap()
        XCTAssertEqual(evening.value as? String, "0")
        app.buttons["Save"].tap()

        app.buttons["people.child.Kid"].tap()
        XCTAssertTrue(evening.waitForExistence(timeout: 5))
        XCTAssertEqual(evening.value as? String, "0", "off must survive a save and a reopen")
        XCTAssertEqual(app.switches["editChild.afternoon.toggle"].value as? String, "1",
                       "the other slot is untouched")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild -project App/Chores.xcodeproj -scheme Chores -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ChoresUITests/ChildRemindersUITests`
Expected: fails — no `editChild.evening.toggle`.

- [ ] **Step 3: Add the rows**

In `App/Chores/Parent/EditChildSheet.swift`:

Two more pieces of state, after `@State private var color: String`:

```swift
    @State private var afternoon: TimeOfDay?
    @State private var evening: TimeOfDay?
```

Initialised in `init`:

```swift
        _afternoon = State(initialValue: child.afternoonReminderAt)
        _evening = State(initialValue: child.eveningReminderAt)
```

In `body`, wrap the existing `VStack` in a `ScrollView` — two more rows and a footnote no longer fit a medium detent — and insert this block between the colour swatches and the setup-code button:

```swift
            VStack(alignment: .leading, spacing: 8) {
                Kicker(text: Text("Reminders"))
                ReminderTimeControl(label: Text("Afternoon reminder"),
                                    time: $afternoon,
                                    defaultTime: TimeOfDay(hour: 15, minute: 0),
                                    identifier: "editChild.afternoon")
                ReminderTimeControl(label: Text("Evening reminder"),
                                    time: $evening,
                                    defaultTime: TimeOfDay(hour: 20, minute: 0),
                                    identifier: "editChild.evening")
                Footnote(text: Text("Each fires only when this child still has chores unticked. Off means never."))
            }
```

So the body's shape becomes:

```swift
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.blockGap) {
                SheetHeader(...)          // unchanged
                NocturneField(...)        // unchanged
                VStack { Kicker("Colour") ... }   // unchanged
                VStack { Kicker("Reminders") ... } // new, above
                VStack { Button("Show setup code") ... }  // unchanged
                if let errorMessage { ... }        // unchanged
            }
        }
        .nocturneSheet()
        .sheet(isPresented: $showingCode) { ... }
    }
```

`save()` carries the two values:

```swift
    private func save() async {
        var updated = child
        updated.displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.color = color
        updated.afternoonReminderAt = afternoon
        updated.eveningReminderAt = evening
        do {
            try await backend.updateProfile(updated)
            await store.reloadAfterEdit()
            dismiss()
        } catch {
            errorMessage = String(localized: "Couldn't save. Check your connection and try again.")
        }
    }
```

- [ ] **Step 4: Strings**

Add to `App/Chores/Localizable.xcstrings` (plain `fi` `stringUnit` entries; `Evening reminder` and the footnote already exist from the push plan's Task 11 — do not duplicate them):

| Key | fi |
|---|---|
| `Reminders` | Muistutukset |
| `Afternoon reminder` | Iltapäivän muistutus |
| `Each fires only when this child still has chores unticked. Off means never.` | Kumpikin tulee vain, jos lapsella on vielä kuittaamattomia tehtäviä. Pois tarkoittaa ei koskaan. |

If the push plan's `Evening reminder` was translated as `Iltamuistutus`, keep that — one key, one value.

- [ ] **Step 5: Run the UI test to verify it passes**

Run: the `-only-testing:ChoresUITests/ChildRemindersUITests` command from Step 2.
Expected: passes. If the evening switch is below the fold at the medium detent, add `app.swipeUp()` after the sheet appears in the test, once per open. Then the whole UI suite; expected: all pass.

- [ ] **Step 6: Commit**

`commit-commands:commit` with the three files. Suggested subject: `Let a parent set each child's two reminder times`.

---

## Self-review notes

**Spec coverage.** §3 → prerequisite (push plan); §4 semantics → Task 1's tests (`aCompletedDayProducesNothingForThatDay`, `remainingCountsOnlyWhatIsStillOpen`, `todaysSlotWhoseTimeHasPassed…`) and Task 2's two bodies; §5.1 → Task 1; §5.2 → Task 2 Step 1; §5.3 → Task 2 Step 2; §5.4 → Task 2 Step 1 (the weekly trigger and `hour` are gone; `requestAuthorization` already moved in the push plan); §6 → Task 3; §7 → Task 2 Step 4 and Task 3 Step 4; §8 XCTest → Task 1, pgTAP → push plan Task 5 (`a child cannot change their own reminder times`), manual → Task 2 Step 6; §9, §10 → nothing to build.

**Types across tasks.** `ReminderPlan(day:slot:time:remaining:)` and `Slot.rawValue` (Task 1) are what Task 2's scheduler reads. `ReminderTimeControl`'s `identifier` yields `<identifier>.toggle` (push plan Task 11), which Task 3's UI test addresses as `editChild.evening.toggle`.

**Judgement calls left to the executor.** Whether the sheet needs a `swipeUp()` in the UI test at the medium detent (Task 3 Step 5). `seedDemoFamily`'s exact `Profile(...)` call sites (Task 2 Step 3) — the arguments to add are named; the lines are not, because that file was not read line by line while planning.
