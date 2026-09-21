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
