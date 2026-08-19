import Foundation
import Observation

/// Drives both onboarding paths: a parent creating the family, and a child
/// claiming a profile with a code.
@MainActor
@Observable
public final class OnboardingViewModel {

    private let backend: ChoresBackend

    public var familyName: String = ""
    public var parentName: String = ""
    public var code: String = ""
    public private(set) var errorMessage: String?
    public private(set) var isBusy: Bool = false

    public init(backend: ChoresBackend) {
        self.backend = backend
    }

    /// Returns true on success, so the view can tell the session to re-read itself.
    public func createFamily() async -> Bool {
        let family = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = parentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !family.isEmpty, !parent.isEmpty else {
            errorMessage = "Please fill in both names."
            return false
        }

        isBusy = true
        defer { isBusy = false }
        errorMessage = nil

        do {
            _ = try await backend.createFamily(familyName: family, parentName: parent,
                                               timezone: TimeZone.current.identifier)
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    public func claim() async -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else {
            errorMessage = "Enter the code from your parent."
            return false
        }

        isBusy = true
        defer { isBusy = false }
        errorMessage = nil

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
            errorMessage = Self.message(for: error)
            return false
        }
    }

    /// Every message names what to do next. "An error occurred" would leave an
    /// eleven-year-old stuck.
    private static func message(for error: Error) -> String {
        switch error as? ChoresBackendError {
        case .unknownClaimCode:
            return "We don't recognise that code. Check for typos and try again."
        case .claimCodeAlreadyUsed:
            return "That code has already been used. Ask your parent for a new one."
        case .claimCodeExpired:
            return "That code has expired. Ask your parent for a new one."
        case .alreadyClaimed:
            return "This device is already set up."
        case .projectUnavailable:
            return "Can't reach the server. Check your connection and try again."
        case .notAuthenticated:
            return "Couldn't start a session. Try restarting the app."
        case .mustSignIn:
            // Only `create_family` still raises this. Joining with a code no
            // longer needs Apple, so the message must not say it does.
            return "Only a parent who has signed in with Apple can start a family. Sign in with Apple, then try again."
        case .notPermitted:
            return "You're not able to do that."
        case .underlying(let detail):
            return detail
        case nil:
            return error.localizedDescription
        }
    }
}
