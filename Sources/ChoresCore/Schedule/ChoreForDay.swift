import Foundation

/// A chore resolved against a specific child and date, carrying its completion state.
public struct ChoreForDay: Identifiable, Hashable, Sendable {
    public let chore: Chore
    public let profileID: UUID
    public let dueOn: CalendarDay
    public let completedAt: Date?

    public var isCompleted: Bool { completedAt != nil }

    /// Stable across refetches: the same (child, chore, date) always yields the same
    /// id, so SwiftUI lists diff correctly instead of animating every refresh.
    public var id: String {
        "\(profileID)|\(chore.id)|\(ChoresJSON.encodedDay(dueOn))"
    }

    public init(chore: Chore, profileID: UUID, dueOn: CalendarDay, completedAt: Date?) {
        self.chore = chore
        self.profileID = profileID
        self.dueOn = dueOn
        self.completedAt = completedAt
    }
}
