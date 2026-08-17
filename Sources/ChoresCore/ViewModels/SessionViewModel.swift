import Foundation
import Observation

public enum SessionState: Equatable, Sendable {
    case loading
    /// No identity at all. The device has not said whether it belongs to a
    /// parent or a child, and nothing has been signed in on its behalf.
    case signedOut
    /// Signed in with Apple, but bound to no profile — either a genuinely new
    /// parent, or one who has just left a family.
    case parentWithoutFamily
    /// An anonymous device that has not yet claimed a code.
    case unclaimed
    case parent(Profile)
    case child(Profile)
    /// The backend could not be reached. Deliberately distinct from `.unclaimed`:
    /// showing onboarding here would ask the user to re-enter a claim code they
    /// neither need nor can obtain.
    case unreachable
    /// The backend was reached and refused. Split from `.unreachable` because the
    /// remedies share nothing: one is "check the Wi-Fi", the other is "this is a
    /// bug". Carrying the message matters — a missing GRANT reads as `42501
    /// permission denied`, which is the whole diagnosis, and showing "can't reach
    /// the server" instead sends the maintainer to debug the network.
    case failed(String)
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
        await refresh()
    }

    /// Re-reads identity and profile without resetting to `.loading`. Called
    /// after onboarding completes and after any action that changes membership.
    public func refresh() async {
        do {
            try await load()
        } catch {
            state = Self.failure(for: error)
        }
    }

    private func load() async throws {
        let identity = try await backend.currentIdentity()
        guard identity != .none else {
            state = .signedOut
            return
        }
        guard let profile = try await backend.currentProfile() else {
            state = identity == .signedIn ? .parentWithoutFamily : .unclaimed
            return
        }
        state = profile.role == .parent ? .parent(profile) : .child(profile)
    }

    /// Mirrors `FamilyStore.message(for:)` — only connectivity earns the "check
    /// your connection" screen; everything else keeps its detail.
    private static func failure(for error: Error) -> SessionState {
        switch error as? ChoresBackendError {
        case .projectUnavailable:
            return .unreachable
        case .underlying(let detail):
            return .failed(detail)
        case .some(let known):
            return .failed(String(describing: known))
        case nil:
            return .failed(error.localizedDescription)
        }
    }
}
