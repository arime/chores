import Testing
import Foundation
@testable import ChoresCore

@Suite struct ReminderScheduleTests {

    let familyID = UUID()
    let childID = UUID()
    let otherChildID = UUID()

    func makeSnapshot(entries: [(profile: UUID, chore: Chore, weekday: Int)],
                      chores: [Chore]) -> FamilySnapshot {
        FamilySnapshot(
            family: Family(id: familyID, name: "Koti"),
            profiles: [],
            chores: chores,
            template: entries.map {
                ScheduleEntry(id: UUID(), familyID: familyID, profileID: $0.profile,
                              choreID: $0.chore.id, weekday: $0.weekday)
            },
            completions: [],
            fetchedAt: Date())
    }

    func chore(_ name: String, archived: Bool = false) -> Chore {
        Chore(id: UUID(), familyID: familyID, name: name, isArchived: archived)
    }

    @Test func producesOnePlanPerWeekdayWithChores() {
        let bins = chore("Bins")
        let dishes = chore("Dishes")
        let snapshot = makeSnapshot(entries: [
            (childID, bins, 1), (childID, dishes, 1), (childID, bins, 4)
        ], chores: [bins, dishes])

        let plans = ReminderSchedule.plans(for: childID, snapshot: snapshot)

        #expect(plans == [ReminderPlan(isoWeekday: 1, choreCount: 2),
                          ReminderPlan(isoWeekday: 4, choreCount: 1)])
    }

    @Test func skipsWeekdaysWithNoChores() {
        let bins = chore("Bins")
        let snapshot = makeSnapshot(entries: [(childID, bins, 3)], chores: [bins])
        #expect(ReminderSchedule.plans(for: childID, snapshot: snapshot).map(\.isoWeekday) == [3])
    }

    @Test func ignoresOtherChildrensChores() {
        let bins = chore("Bins")
        let snapshot = makeSnapshot(entries: [(otherChildID, bins, 2)], chores: [bins])
        #expect(ReminderSchedule.plans(for: childID, snapshot: snapshot).isEmpty)
    }

    @Test func ignoresArchivedChores() {
        let archived = chore("Old", archived: true)
        let snapshot = makeSnapshot(entries: [(childID, archived, 5)], chores: [archived])
        #expect(ReminderSchedule.plans(for: childID, snapshot: snapshot).isEmpty)
    }

    @Test func doesNotCountAnArchivedChoreTowardsADaysTotal() {
        let bins = chore("Bins")
        let archived = chore("Old", archived: true)
        let snapshot = makeSnapshot(entries: [(childID, bins, 2), (childID, archived, 2)],
                                    chores: [bins, archived])

        #expect(ReminderSchedule.plans(for: childID, snapshot: snapshot)
                == [ReminderPlan(isoWeekday: 2, choreCount: 1)])
    }

    @Test func ignoresTemplateRowsForAChoreThatNoLongerExists() {
        let orphan = ScheduleEntry(id: UUID(), familyID: familyID, profileID: childID,
                                   choreID: UUID(), weekday: 6)
        let snapshot = FamilySnapshot(
            family: Family(id: familyID, name: "Koti"), profiles: [], chores: [],
            template: [orphan], completions: [], fetchedAt: Date())

        #expect(ReminderSchedule.plans(for: childID, snapshot: snapshot).isEmpty)
    }

    @Test func plansAreOrderedByWeekday() {
        let bins = chore("Bins")
        let snapshot = makeSnapshot(entries: [
            (childID, bins, 7), (childID, bins, 2), (childID, bins, 5)
        ], chores: [bins])

        #expect(ReminderSchedule.plans(for: childID, snapshot: snapshot).map(\.isoWeekday)
                == [2, 5, 7])
    }

    @Test func anEmptyTemplateProducesNoReminders() {
        let snapshot = makeSnapshot(entries: [], chores: [])
        #expect(ReminderSchedule.plans(for: childID, snapshot: snapshot).isEmpty)
    }
}
