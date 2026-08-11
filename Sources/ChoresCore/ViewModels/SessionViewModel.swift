import Foundation
import Observation

public enum SessionState: Equatable, Sendable {
    case loading
    /// Signed in, but this device is not bound to any profile yet.
    case unclaimed
    case parent(Profile)
    case child(Profile)
    /// The backend could not be reached. Deliberately distinct from `.unclaimed`:
    /// showing onboarding here would ask the user to re-enter a claim code they
    /// neither need nor can obtain.
    case unavailable
}

/// Decides which of the two modes the app shows, once, at launch.
@MainActor
@Observable
public final class SessionViewModel {

    private let backend: ChoresBackend
    public private(set) var state: SessionState = .loading

    public init(backend: ChoresBackend) {
        self.backend = backend
    }

    public func start() async {
        state = .loading
        do {
            try await backend.signInAnonymouslyIfNeeded()
            try await load()
        } catch {
            state = .unavailable
        }
    }

    /// Re-reads the profile without resetting to `.loading`. Called after
    /// onboarding completes.
    public func refresh() async {
        do {
            try await load()
        } catch {
            state = .unavailable
        }
    }

    private func load() async throws {
        guard let profile = try await backend.currentProfile() else {
            state = .unclaimed
            return
        }
        state = profile.role == .parent ? .parent(profile) : .child(profile)
    }
}
