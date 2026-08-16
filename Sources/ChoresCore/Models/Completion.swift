import Foundation

/// A chore ticked off by a child on a particular date.
///
/// Identified by `(profileID, choreID, dueOn)` — never by a schedule row — which
/// is what lets the weekly template be rewritten without corrupting history, and
/// what makes writes idempotent so the outbox can replay blindly.
public struct Completion: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let familyID: UUID
    public let profileID: UUID
    public let choreID: UUID
    /// The date the chore was due, in the family's timezone.
    public let dueOn: CalendarDay
    public let completedAt: Date
    /// Who ticked it off — the child themselves, or a parent doing it for them.
    ///
    /// Null once that person has left the family. Optional only here: every write
    /// path knows the actor by definition, so `ChoresBackend.complete` and
    /// `OutboxOperation.complete` keep the non-optional type.
    public let completedBy: UUID?

    public init(id: UUID, familyID: UUID, profileID: UUID, choreID: UUID,
                dueOn: CalendarDay, completedAt: Date = .init(), completedBy: UUID?) {
        self.id = id
        self.familyID = familyID
        self.profileID = profileID
        self.choreID = choreID
        self.dueOn = dueOn
        self.completedAt = completedAt
        self.completedBy = completedBy
    }

    enum CodingKeys: String, CodingKey {
        case id
        case familyID = "family_id"
        case profileID = "profile_id"
        case choreID = "chore_id"
        case dueOn = "due_on"
        case completedAt = "completed_at"
        case completedBy = "completed_by"
    }
}
