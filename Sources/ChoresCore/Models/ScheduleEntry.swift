import Foundation

/// One row of the weekly template: this child does this chore on this weekday,
/// every week between `validFrom` and `validUntil`.
///
/// Removing an entry closes its range rather than deleting the row, so a past
/// day can be resolved against the template as it stood on that day. Only an
/// entry added and removed on the same day is ever deleted — it lived zero days.
public struct ScheduleEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let familyID: UUID
    public let profileID: UUID
    public let choreID: UUID
    /// ISO weekday: 1 = Monday … 7 = Sunday.
    public let weekday: Int
    /// The first day this entry applies to.
    public let validFrom: CalendarDay
    /// The first day this entry no longer applies to; `nil` while it is still
    /// part of the current template.
    public var validUntil: CalendarDay?

    public init(id: UUID, familyID: UUID, profileID: UUID, choreID: UUID, weekday: Int,
                validFrom: CalendarDay, validUntil: CalendarDay? = nil) {
        self.id = id
        self.familyID = familyID
        self.profileID = profileID
        self.choreID = choreID
        self.weekday = weekday
        self.validFrom = validFrom
        self.validUntil = validUntil
    }

    /// Part of the template as it stands now — what the editor shows and what
    /// a copy-day copies.
    public var isCurrent: Bool { validUntil == nil }

    /// Whether this entry applied on `day`: from `validFrom` inclusive up to
    /// `validUntil` exclusive.
    public func isValid(on day: CalendarDay) -> Bool {
        day >= validFrom && (validUntil.map { day < $0 } ?? true)
    }

    enum CodingKeys: String, CodingKey {
        case id, weekday
        case familyID = "family_id"
        case profileID = "profile_id"
        case choreID = "chore_id"
        case validFrom = "valid_from"
        case validUntil = "valid_until"
    }
}
