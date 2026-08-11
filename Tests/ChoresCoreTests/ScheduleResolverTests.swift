import Testing
import Foundation
@testable import ChoresCore

@Suite struct ScheduleResolverTests {

    // Fixed identifiers keep assertions readable.
    let family = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let kidA   = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let kidB   = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    let monday    = CalendarDay(year: 2026, month: 8, day: 10)
    let tuesday   = CalendarDay(year: 2026, month: 8, day: 11)
    let wednesday = CalendarDay(year: 2026, month: 8, day: 12)

    func chore(_ id: String, _ name: String, archived: Bool = false) -> Chore {
        Chore(id: UUID(uuidString: id)!, familyID: family, name: name, isArchived: archived)
    }

    func entry(_ profile: UUID, _ chore: Chore, _ weekday: Int) -> ScheduleEntry {
        ScheduleEntry(id: UUID(), familyID: family, profileID: profile,
                      choreID: chore.id, weekday: weekday)
    }

    var dishwasher: Chore { chore("44444444-0000-0000-0000-000000000001", "Dishwasher") }
    var vacuum:     Chore { chore("44444444-0000-0000-0000-000000000002", "Vacuum") }
    var bins:       Chore { chore("44444444-0000-0000-0000-000000000003", "Bins") }

    @Test func returnsOnlyChoresAssignedToThatChildOnThatWeekday() {
        let template = [
            entry(kidA, dishwasher, 1),   // Monday
            entry(kidA, vacuum, 1),       // Monday
            entry(kidB, bins, 1),         // Monday
            entry(kidA, bins, 2)          // Tuesday
        ]
        let result = ScheduleResolver.chores(
            for: kidA, on: monday, template: template,
            chores: [dishwasher, vacuum, bins], completions: [])

        #expect(result.map(\.chore.name).sorted() == ["Dishwasher", "Vacuum"])
        #expect(result.allSatisfy { $0.profileID == kidA })
        #expect(result.allSatisfy { $0.dueOn == monday })
    }

    @Test func swapsAssignmentsBetweenChildrenOnDifferentDays() {
        // The exact scenario from the spec: Monday A does X+Y and B does Z;
        // Tuesday A does Z and B does X+Y.
        let template = [
            entry(kidA, dishwasher, 1), entry(kidA, vacuum, 1), entry(kidB, bins, 1),
            entry(kidA, bins, 2), entry(kidB, dishwasher, 2), entry(kidB, vacuum, 2)
        ]
        let all = [dishwasher, vacuum, bins]

        #expect(ScheduleResolver.chores(for: kidA, on: tuesday, template: template,
                                        chores: all, completions: []).map(\.chore.name) == ["Bins"])
        #expect(ScheduleResolver.chores(for: kidB, on: tuesday, template: template,
                                        chores: all, completions: [])
                .map(\.chore.name).sorted() == ["Dishwasher", "Vacuum"])
    }

    @Test func marksChoresCompletedOnlyForTheMatchingDate() {
        let template = [entry(kidA, dishwasher, 1), entry(kidA, dishwasher, 3)]
        let completedMonday = Completion(
            id: UUID(), familyID: family, profileID: kidA, choreID: dishwasher.id,
            dueOn: monday, completedBy: kidA)

        let mondayResult = ScheduleResolver.chores(
            for: kidA, on: monday, template: template,
            chores: [dishwasher], completions: [completedMonday])
        let wednesdayResult = ScheduleResolver.chores(
            for: kidA, on: wednesday, template: template,
            chores: [dishwasher], completions: [completedMonday])

        #expect(mondayResult.first?.isCompleted == true)
        #expect(wednesdayResult.first?.isCompleted == false)
    }

    @Test func doesNotCreditACompletionBelongingToAnotherChild() {
        let template = [entry(kidA, dishwasher, 1), entry(kidB, dishwasher, 1)]
        let kidBCompletion = Completion(
            id: UUID(), familyID: family, profileID: kidB, choreID: dishwasher.id,
            dueOn: monday, completedBy: kidB)

        let result = ScheduleResolver.chores(
            for: kidA, on: monday, template: template,
            chores: [dishwasher], completions: [kidBCompletion])

        #expect(result.first?.isCompleted == false)
    }

    @Test func excludesArchivedChores() {
        let archived = chore("44444444-0000-0000-0000-000000000009", "Old job", archived: true)
        let template = [entry(kidA, dishwasher, 1), entry(kidA, archived, 1)]

        let result = ScheduleResolver.chores(
            for: kidA, on: monday, template: template,
            chores: [dishwasher, archived], completions: [])

        #expect(result.map(\.chore.name) == ["Dishwasher"])
    }

    @Test func ignoresTemplateEntriesReferencingAnUnknownChore() {
        let orphan = ScheduleEntry(id: UUID(), familyID: family, profileID: kidA,
                                   choreID: UUID(), weekday: 1)
        let result = ScheduleResolver.chores(
            for: kidA, on: monday, template: [orphan, entry(kidA, dishwasher, 1)],
            chores: [dishwasher], completions: [])

        #expect(result.count == 1)
    }

    @Test func sortsChoresByNameForStableDisplay() {
        let template = [entry(kidA, vacuum, 1), entry(kidA, bins, 1), entry(kidA, dishwasher, 1)]
        let result = ScheduleResolver.chores(
            for: kidA, on: monday, template: template,
            chores: [vacuum, bins, dishwasher], completions: [])

        #expect(result.map(\.chore.name) == ["Bins", "Dishwasher", "Vacuum"])
    }

    @Test func identityIsStableAcrossRefetches() {
        // ChoreForDay.id must not change between fetches, or SwiftUI lists animate wrongly.
        let template = [entry(kidA, dishwasher, 1)]
        let first = ScheduleResolver.chores(for: kidA, on: monday, template: template,
                                           chores: [dishwasher], completions: [])
        let second = ScheduleResolver.chores(for: kidA, on: monday, template: template,
                                            chores: [dishwasher], completions: [])
        #expect(first.first?.id == second.first?.id)
    }

    @Test func progressCountsDoneAgainstTotal() {
        let template = [entry(kidA, dishwasher, 1), entry(kidA, vacuum, 1), entry(kidA, bins, 1)]
        let done = Completion(id: UUID(), familyID: family, profileID: kidA,
                              choreID: vacuum.id, dueOn: monday, completedBy: kidA)

        let progress = ScheduleResolver.progress(
            for: kidA, on: monday, template: template,
            chores: [dishwasher, vacuum, bins], completions: [done])

        #expect(progress.done == 1)
        #expect(progress.total == 3)
    }

    @Test func progressIsZeroWhenNothingIsScheduled() {
        let progress = ScheduleResolver.progress(
            for: kidA, on: monday, template: [], chores: [], completions: [])
        #expect(progress == (done: 0, total: 0))
    }

    // MARK: - Eligibility

    @Test func todayIsAlwaysCompletable() {
        #expect(ScheduleResolver.eligibility(for: wednesday, today: wednesday) == .allowed)
    }

    @Test func earlierDaysInTheCurrentWeekAreCompletable() {
        #expect(ScheduleResolver.eligibility(for: monday, today: wednesday) == .allowed)
        #expect(ScheduleResolver.eligibility(for: tuesday, today: wednesday) == .allowed)
    }

    @Test func futureDaysAreNeverCompletable() {
        #expect(ScheduleResolver.eligibility(for: wednesday, today: monday) == .future)
        // Even a future day inside the same week.
        #expect(ScheduleResolver.eligibility(
            for: CalendarDay(year: 2026, month: 8, day: 16), today: monday) == .future)
    }

    @Test func daysInAPreviousWeekAreNotCompletable() {
        // Sunday 2026-08-09 belongs to the previous ISO week.
        #expect(ScheduleResolver.eligibility(
            for: CalendarDay(year: 2026, month: 8, day: 9), today: wednesday) == .outsideCurrentWeek)
    }

    @Test func mondayIsCompletableWhenTodayIsThatMonday() {
        // Boundary: the week's first day must not fall outside its own week.
        #expect(ScheduleResolver.eligibility(for: monday, today: monday) == .allowed)
    }
}
