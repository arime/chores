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

    func chore(_ name: String, archivedOn: CalendarDay? = nil) -> Chore {
        Chore(id: UUID(), familyID: familyID, name: name, archivedOn: archivedOn)
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
                              choreID: $0.chore.id, weekday: $0.weekday,
                              validFrom: CalendarDay(year: 2020, month: 1, day: 1))
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
        let bins = chore("Bins"), old = chore("Old", archivedOn: CalendarDay(year: 2020, month: 1, day: 1))
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
