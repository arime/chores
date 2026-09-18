import Foundation

/// Which of Apple's two push gateways a device token belongs to. A token is
/// valid on exactly one: debug builds get sandbox tokens, anything archived —
/// TestFlight or the store — gets production ones.
public enum PushEnvironment: String, Codable, Sendable {
    case development
    case production
}
