import Foundation

public struct Chore: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let familyID: UUID
    public var name: String
    /// SF Symbol name.
    public var icon: String?
    /// Reserved for a future rewards layer. Unused in v1.
    public var points: Int?
    /// Archived chores keep their history and their schedule entries but drop out
    /// of `ScheduleResolver` output. Deleting would orphan completion history.
    public var isArchived: Bool
    public let createdAt: Date

    public init(id: UUID, familyID: UUID, name: String, icon: String? = nil,
                points: Int? = nil, isArchived: Bool = false, createdAt: Date = .init()) {
        self.id = id
        self.familyID = familyID
        self.name = name
        self.icon = icon
        self.points = points
        self.isArchived = isArchived
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, icon, points
        case familyID = "family_id"
        case isArchived = "is_archived"
        case createdAt = "created_at"
    }
}
