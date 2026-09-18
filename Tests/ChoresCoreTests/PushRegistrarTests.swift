import Testing
import Foundation
@testable import ChoresCore

@Suite struct PushRegistrarTests {

    func signedInParent() async throws -> (InMemoryChoresBackend, Profile) {
        let backend = InMemoryChoresBackend()
        try await backend.signInWithApple(idToken: "apple-1", nonce: "n")
        _ = try await backend.createFamily(familyName: "Koti", parentName: "Parent",
                                           timezone: "Europe/Helsinki")
        return (backend, try #require(try await backend.currentProfile()))
    }

    @Test func registersOnceBothTokenAndParentAreKnown_tokenFirst() async throws {
        let (backend, parent) = try await signedInParent()
        let registrar = PushRegistrar(backend: backend, environment: .development)

        await registrar.tokenDidArrive("tok")
        #expect(backend.deviceTokens().isEmpty, "a token alone is not enough")

        await registrar.parentDidAppear(parent)
        #expect(backend.deviceTokens()["tok"]?.profileID == parent.id)
        #expect(backend.deviceTokens()["tok"]?.environment == .development)
    }

    @Test func registersOnceBothTokenAndParentAreKnown_parentFirst() async throws {
        let (backend, parent) = try await signedInParent()
        let registrar = PushRegistrar(backend: backend, environment: .production)

        await registrar.parentDidAppear(parent)
        #expect(backend.deviceTokens().isEmpty, "a parent alone is not enough")

        await registrar.tokenDidArrive("tok")
        #expect(backend.deviceTokens()["tok"]?.profileID == parent.id)
    }

    @Test func doesNotRepeatAnIdenticalRegistration() async throws {
        let (backend, parent) = try await signedInParent()
        let counting = CountingBackend(inner: backend)
        let registrar = PushRegistrar(backend: counting, environment: .production)

        await registrar.tokenDidArrive("tok")
        await registrar.parentDidAppear(parent)
        await registrar.parentDidAppear(parent)
        await registrar.tokenDidArrive("tok")

        #expect(counting.registerCalls == 1)
    }

    @Test func aChangedTokenIsRegisteredAgain() async throws {
        let (backend, parent) = try await signedInParent()
        let registrar = PushRegistrar(backend: backend, environment: .production)

        await registrar.parentDidAppear(parent)
        await registrar.tokenDidArrive("old")
        await registrar.tokenDidArrive("new")

        #expect(backend.deviceTokens()["new"]?.profileID == parent.id)
    }

    @Test func endingTheSessionForgetsTheTokenWhileTheIdentityStillExists() async throws {
        let (backend, parent) = try await signedInParent()
        let registrar = PushRegistrar(backend: backend, environment: .production)
        await registrar.tokenDidArrive("tok")
        await registrar.parentDidAppear(parent)

        await registrar.sessionWillEnd()
        #expect(backend.deviceTokens().isEmpty)
    }

    @Test func aParentReappearingAfterAnEndedSessionRegistersAgain() async throws {
        let (backend, parent) = try await signedInParent()
        let registrar = PushRegistrar(backend: backend, environment: .production)
        await registrar.tokenDidArrive("tok")
        await registrar.parentDidAppear(parent)
        await registrar.sessionWillEnd()

        // The sign-out failed, say, and the same parent is still here.
        await registrar.parentDidAppear(parent)
        #expect(backend.deviceTokens()["tok"]?.profileID == parent.id)
    }

    @Test func aRefusedRegistrationIsSwallowed() async throws {
        let (_, parent) = try await signedInParent()
        let registrar = PushRegistrar(backend: UnavailableBackend(), environment: .production)
        await registrar.tokenDidArrive("tok")
        await registrar.parentDidAppear(parent)
        // Reaching here without a throw is the assertion.
    }
}

/// Counts registrations so a test can prove a repeat was skipped.
final class CountingBackend: ForwardingBackend, @unchecked Sendable {
    private(set) var registerCalls = 0

    override func registerDeviceToken(_ token: String, environment: PushEnvironment) async throws {
        registerCalls += 1
        try await super.registerDeviceToken(token, environment: environment)
    }
}
