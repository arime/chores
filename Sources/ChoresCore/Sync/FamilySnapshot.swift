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

    public var activeChores: [Chore] {
        chores.filter { !$0.isArchived }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
