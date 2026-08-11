import Foundation

/// One row of the weekly template: this child does this chore on this weekday,
/// every week.
public struct ScheduleEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let familyID: UUID
    public let profileID: UUID
    public let choreID: UUID
    /// ISO weekday: 1 = Monday … 7 = Sunday.
    public let weekday: Int

    public init(id: UUID, familyID: UUID, profileID: UUID, choreID: UUID, weekday: Int) {
        self.id = id
        self.familyID = familyID
        self.profileID = profileID
        self.choreID = choreID
        self.weekday = weekday
    }

    enum CodingKeys: String, CodingKey {
        case id, weekday
        case familyID = "family_id"
        case profileID = "profile_id"
        case choreID = "chore_id"
    }
}
