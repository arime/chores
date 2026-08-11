import Foundation

public struct Family: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    /// IANA identifier, e.g. "Europe/Helsinki". Stored as text so the database
    /// stays portable; read through `timeZone`.
    public var timezone: String
    public let createdAt: Date

    /// Falls back to GMT rather than trapping: an unrecognised identifier must
    /// never take the app down.
    public var timeZone: TimeZone { TimeZone(identifier: timezone) ?? .gmt }

    public init(id: UUID, name: String, timezone: String = "Europe/Helsinki",
                createdAt: Date = .init()) {
        self.id = id
        self.name = name
        self.timezone = timezone
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, timezone
        case createdAt = "created_at"
    }
}
