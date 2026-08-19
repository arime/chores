import Foundation
import Observation

/// Why an onboarding step failed. A case rather than a sentence: the wording
/// belongs to whatever is showing it, and this package has no bundle to
/// translate one from.
public enum OnboardingFailure: Equatable, Sendable {
    case bothNamesRequired
    case codeRequired
    case unknownClaimCode
    case claimCodeAlreadyUsed
    case claimCodeExpired
    case alreadyClaimed
    case projectUnavailable
    case sessionUnavailable
    case mustSignIn
    case notPermitted
    /// A detail string from the server, or an `Error` this enum does not
    /// recognise. Untranslatable by nature — it is shown as it arrives.
    case other(String)
}

/// Drives both onboarding paths: a parent creating the family, and a child
/// claiming a profile with a code.
@MainActor
@Observable
public final class OnboardingViewModel {

    private let backend: ChoresBackend

    public var familyName: String = ""
    public var parentName: String = ""
    public var code: String = ""
    public private(set) var failure: OnboardingFailure?
    public private(set) var isBusy: Bool = false

    public init(backend: ChoresBackend) {
        self.backend = backend
    }

    /// Returns true on success, so the view can tell the session to re-read itself.
    public func createFamily() async -> Bool {
        let family = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = parentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !family.isEmpty, !parent.isEmpty else {
            failure = .bothNamesRequired
            return false
        }

        isBusy = true
        defer { isBusy = false }
        failure = nil

        do {
            _ = try await backend.createFamily(familyName: family, parentName: parent,
                                               timezone: TimeZone.current.identifier)
            return true
        } catch {
            failure = Self.failure(for: error)
            return false
        }
    }

    public func claim() async -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else {
            failure = .codeRequired
            return false
        }

        isBusy = true
        defer { isBusy = false }
        failure = nil

        do {
            // A child arrives with no identity, and so does a second parent who
            // has no Apple ID — both need one minting. A parent who signed in
            // first arrives holding one already, and minting another would
            // discard what makes them durable.
            if try await backend.currentIdentity() == .none {
                try await backend.signInAnonymously()
            }
            _ = try await backend.claimProfile(code: trimmed)
            return true
        } catch {
            failure = Self.failure(for: error)
            return false
        }
    }

    /// Each failure keeps its own case so each can keep its own wording. This is
    /// the whole reason claim_profile() raises distinct SQLSTATEs — the wording
    /// itself lives in the app target, which has a bundle to translate it from.
    private static func failure(for error: Error) -> OnboardingFailure {
        switch error as? ChoresBackendError {
        case .unknownClaimCode:       .unknownClaimCode
        case .claimCodeAlreadyUsed:   .claimCodeAlreadyUsed
        case .claimCodeExpired:       .claimCodeExpired
        case .alreadyClaimed:         .alreadyClaimed
        case .projectUnavailable:     .projectUnavailable
        case .notAuthenticated:       .sessionUnavailable
        // Only `create_family` still raises this. Joining with a code no longer
        // needs Apple, so the message behind this case must not say it does.
        case .mustSignIn:             .mustSignIn
        case .notPermitted:           .notPermitted
        case .underlying(let detail): .other(detail)
        case nil:                     .other(error.localizedDescription)
        }
    }
}
