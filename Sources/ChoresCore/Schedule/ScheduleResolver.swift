import Foundation

/// The single source of truth for "what is due, for whom, on which day".
///
/// Deliberately a pure function over already-fetched data: no network, no storage,
/// no SwiftUI. That is what makes it exhaustively testable, and it is where the
/// only real logic in the system lives.
///
/// When per-date overrides are added later they are applied here — the read path
/// changes from *template* to *template, then overrides* — and nothing else in the
/// app needs to know.
public enum ScheduleResolver {

    public static func chores(
        for profileID: UUID,
        on day: CalendarDay,
        template: [ScheduleEntry],
        chores: [Chore],
        completions: [Completion]
    ) -> [ChoreForDay] {
        var choresByID: [UUID: Chore] = [:]
        for chore in chores { choresByID[chore.id] = chore }

        // Keyed exactly as the database unique constraint is.
        var completionByKey: [CompletionKey: Completion] = [:]
        for completion in completions {
            completionByKey[CompletionKey(completion)] = completion
        }

        return template
            .filter { $0.profileID == profileID && $0.weekday == day.isoWeekday }
            .compactMap { entry -> ChoreForDay? in
                guard let chore = choresByID[entry.choreID], !chore.isArchived else { return nil }
                let key = CompletionKey(profileID: profileID, choreID: chore.id, dueOn: day)
                return ChoreForDay(chore: chore,
                                   profileID: profileID,
                                   dueOn: day,
                                   completedAt: completionByKey[key]?.completedAt)
            }
            .sorted { $0.chore.name.localizedStandardCompare($1.chore.name) == .orderedAscending }
    }

    public static func progress(
        for profileID: UUID,
        on day: CalendarDay,
        template: [ScheduleEntry],
        chores: [Chore],
        completions: [Completion]
    ) -> (done: Int, total: Int) {
        let resolved = self.chores(for: profileID, on: day, template: template,
                                   chores: chores, completions: completions)
        return (resolved.filter(\.isCompleted).count, resolved.count)
    }

    /// Children may tick off today and any earlier day in the current ISO week, but
    /// never a future day and never a previous week.
    public static func eligibility(for day: CalendarDay,
                                   today: CalendarDay) -> CompletionEligibility {
        if day > today { return .future }
        guard let monday = WeekCalendar.isoWeek(containing: today).first,
              day >= monday else { return .outsideCurrentWeek }
        return .allowed
    }

    private struct CompletionKey: Hashable {
        let profileID: UUID
        let choreID: UUID
        let dueOn: CalendarDay

        init(profileID: UUID, choreID: UUID, dueOn: CalendarDay) {
            self.profileID = profileID
            self.choreID = choreID
            self.dueOn = dueOn
        }

        init(_ completion: Completion) {
            self.init(profileID: completion.profileID,
                      choreID: completion.choreID,
                      dueOn: completion.dueOn)
        }
    }
}
