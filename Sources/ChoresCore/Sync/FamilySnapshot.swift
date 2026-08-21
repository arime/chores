import Foundation

/// Everything the app needs to render any screen, fetched in one pass.
///
/// A whole family's data is on the order of a hundred rows, so paging would be
/// pure overhead. Fetching it as a unit is also what makes offline reads and
/// client-side resolution straightforward.
public struct FamilySnapshot: Codable, Equatable, Sendable {
    public var family: Family
    public var profiles: [Profile]
    public var chores: [Chore]
    public var template: [ScheduleEntry]
    /// Only the requested week's completions. History stays on the server.
    public var completions: [Completion]
    public var fetchedAt: Date

    public init(family: Family, profiles: [Profile], chores: [Chore],
                template: [ScheduleEntry], completions: [Completion], fetchedAt: Date) {
        self.family = family
        self.profiles = profiles
        self.chores = chores
        self.template = template
        self.completions = completions
        self.fetchedAt = fetchedAt
    }

    public var children: [Profile] {
        profiles.filter { $0.role == .child }
            .sorted { ($0.sortOrder, $0.displayName) < ($1.sortOrder, $1.displayName) }
    }

    /// A family may have more than one. Every policy asks `is_parent()` rather
    /// than naming a particular profile, so they are equals.
    public var parents: [Profile] {
        profiles.filter { $0.role == .parent }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public var activeChores: [Chore] {
        chores.filter { !$0.isArchived }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

extension FamilySnapshot {

    /// This snapshot with writes the server has not accepted yet laid back on top.
    ///
    /// What a fetch answers with is what the server knows, which is not the same
    /// as what the person is looking at. A tick still sitting in the outbox — in
    /// flight, or queued behind a failure — is real to whoever made it, and
    /// drawing the fetched snapshot as-is takes it off the screen. That reads as
    /// the app forgetting, which is the one thing an offline-first app may not do.
    ///
    /// Applied in queue order, so a row written more than once ends up the way it
    /// was last left. `now` stands in for the `completed_at` the server will
    /// assign: nothing reads the time itself, only whether there is one.
    func applying(_ operations: [OutboxOperation], at now: Date) -> FamilySnapshot {
        guard !operations.isEmpty else { return self }
        var merged = self
        for operation in operations {
            switch operation {
            case let .complete(familyID, profileID, choreID, dueOn, completedBy):
                merged.setCompletion(Completion(
                    id: UUID(), familyID: familyID, profileID: profileID, choreID: choreID,
                    dueOn: dueOn, completedAt: now, completedBy: completedBy))
            case let .uncomplete(profileID, choreID, dueOn):
                merged.clearCompletion(profileID: profileID, choreID: choreID, dueOn: dueOn)
            }
        }
        return merged
    }

    /// Replaces any row for the same (child, chore, date), which is what the
    /// database's own uniqueness constraint would do.
    mutating func setCompletion(_ completion: Completion) {
        clearCompletion(profileID: completion.profileID, choreID: completion.choreID,
                        dueOn: completion.dueOn)
        completions.append(completion)
    }

    mutating func clearCompletion(profileID: UUID, choreID: UUID, dueOn: CalendarDay) {
        completions.removeAll {
            $0.profileID == profileID && $0.choreID == choreID && $0.dueOn == dueOn
        }
    }
}
