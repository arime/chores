import Foundation

public struct Profile: Identifiable, Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case parent, child }

    public let id: UUID
    public let familyID: UUID
    /// Nil until a device claims this profile with a code. Only `claim_profile()`
    /// may set it; a database trigger rejects any other write.
    public var authUserID: UUID?
    public var displayName: String
    public var role: Role
    /// Hex string, e.g. "#4C8BF5".
    public var color: String
    public var sortOrder: Int
    public let createdAt: Date

    public init(id: UUID, familyID: UUID, authUserID: UUID? = nil, displayName: String,
                role: Role, color: String = "#4C8BF5", sortOrder: Int = 0,
                createdAt: Date = .init()) {
        self.id = id
        self.familyID = familyID
        self.authUserID = authUserID
        self.displayName = displayName
        self.role = role
        self.color = color
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, role, color
        case familyID = "family_id"
        case authUserID = "auth_user_id"
        case displayName = "display_name"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
    }
}
