import Foundation

/// Decides when this device's APNs token is written to the server.
///
/// Two things have to be known first and they arrive in either order: the
/// token, which UIKit hands to the application delegate whenever it likes, and
/// the parent profile, which the session resolves. This holds whichever came
/// first and acts when the second arrives. It is an actor because those two
/// arrivals come from different tasks.
///
/// Kept in ChoresCore so the ordering rules are tested against the in-memory
/// backend; the UIKit glue that feeds it stays in the app target.
public actor PushRegistrar {
    private let backend: any ChoresBackend
    private let environment: PushEnvironment

    private var token: String?
    private var parent: Profile?
    /// What was last sent, so a repeat arrival does not hit the server again.
    private var registered: (token: String, profileID: UUID)?

    public init(backend: any ChoresBackend, environment: PushEnvironment) {
        self.backend = backend
        self.environment = environment
    }

    public func tokenDidArrive(_ token: String) async {
        self.token = token
        await registerIfReady()
    }

    /// Parent mode is on screen for this profile. Called on every launch into
    /// it, which is what makes a token that changed between launches reach the
    /// server.
    public func parentDidAppear(_ profile: Profile) async {
        parent = profile
        await registerIfReady()
    }

    /// The session is about to end — sign-out, leaving, or deleting the account.
    /// Must run *before* it does: afterwards there is no identity to delete
    /// with, and the phone would keep receiving a family it no longer shows.
    /// The token itself is kept; it belongs to the phone, not the session.
    public func sessionWillEnd() async {
        parent = nil
        registered = nil
        guard let token else { return }
        try? await backend.forgetDeviceToken(token)
    }

    private func registerIfReady() async {
        guard let token, let parent else { return }
        if let registered, registered.token == token, registered.profileID == parent.id {
            return
        }
        do {
            try await backend.registerDeviceToken(token, environment: environment)
            registered = (token, parent.id)
        } catch {
            // Offline, or refused. The next launch into parent mode tries again;
            // nothing else in the app depends on this having worked.
        }
    }
}
