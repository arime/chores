import Testing
import Foundation
@testable import ChoresCore

@MainActor
@Suite struct SessionViewModelTests {

    /// Launch must not mint an identity for someone who has not said who they are.
    /// A parent device that did so would leave an orphaned anonymous user behind on
    /// every first run.
    @Test func startWithNoIdentityYieldsSignedOutWithoutSigningAnyoneIn() async throws {
        let backend = InMemoryChoresBackend()
        let model = SessionViewModel(backend: backend)

        await model.start()

        #expect(model.state == .signedOut)
        #expect(try await backend.currentIdentity() == .none)
    }

    @Test func anAppleIdentityWithNoProfileWantsToStartOrJoinAFamily() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInWithApple(idToken: "ari", nonce: "n")

        let model = SessionViewModel(backend: backend)
        await model.start()

        #expect(model.state == .parentWithoutFamily)
    }

    @Test func anAnonymousIdentityWithNoProfileIsAwaitingACode() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()

        let model = SessionViewModel(backend: backend)
        await model.start()

        #expect(model.state == .unclaimed)
    }

    @Test func startAfterCreatingAFamilyYieldsParent() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        _ = try await backend.createFamily(familyName: "Koti", parentName: "Parent",
                                           timezone: "Europe/Helsinki")

        let model = SessionViewModel(backend: backend)
        await model.start()

        guard case let .parent(profile) = model.state else {
            Issue.record("expected .parent, got \(model.state)")
            return
        }
        #expect(profile.displayName == "Parent")
    }

    @Test func startAfterClaimingYieldsChild() async throws {
        let parentBackend = InMemoryChoresBackend()
        try await parentBackend.signInAnonymously()
        let familyID = try await parentBackend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await parentBackend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let code = try await parentBackend.generateClaimCode(profileID: child.id)

        let kidBackend = parentBackend.newDevice()
        try await kidBackend.signInAnonymously()
        _ = try await kidBackend.claimProfile(code: code)

        let model = SessionViewModel(backend: kidBackend)
        await model.start()

        guard case let .child(profile) = model.state else {
            Issue.record("expected .child, got \(model.state)")
            return
        }
        #expect(profile.displayName == "Kid")
    }

    /// A paused project must not be mistaken for a fresh install, or the user gets
    /// sent to re-enter a claim code they do not need and cannot obtain.
    @Test func backendFailureYieldsUnreachableRatherThanUnclaimed() async {
        let model = SessionViewModel(backend: UnavailableBackend())
        await model.start()
        #expect(model.state == .unreachable)
    }

    /// A server that answers and refuses is not a connectivity problem, and
    /// saying so cost real debugging time once: a missing GRANT surfaced as
    /// "can't reach the server" while the stack was up and answering.
    @Test func aRefusalKeepsItsMessageInsteadOfLookingLikeAnOutage() async {
        let model = SessionViewModel(
            backend: UnavailableBackend(
                error: .underlying("permission denied for table profiles")))

        await model.start()

        #expect(model.state == .failed("permission denied for table profiles"))
    }

    /// Errors the mapping has no case for must still keep a lead, rather than
    /// collapsing into the outage screen.
    @Test func anUnrecognisedErrorIsReportedRatherThanBlamedOnTheNetwork() async {
        let model = SessionViewModel(backend: UnavailableBackend(error: .notAuthenticated))
        await model.start()
        #expect(model.state == .failed("notAuthenticated"))
    }

    @Test func refreshPicksUpAProfileClaimedAfterStart() async throws {
        // This is the onboarding hand-off: the view claims, then asks the session
        // to re-read itself rather than reaching into it.
        let parentBackend = InMemoryChoresBackend()
        try await parentBackend.signInAnonymously()
        let familyID = try await parentBackend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await parentBackend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let code = try await parentBackend.generateClaimCode(profileID: child.id)

        let kidBackend = parentBackend.newDevice()
        try await kidBackend.signInAnonymously()
        let model = SessionViewModel(backend: kidBackend)
        await model.start()
        #expect(model.state == .unclaimed)

        _ = try await kidBackend.claimProfile(code: code)
        await model.refresh()

        guard case .child = model.state else {
            Issue.record("expected .child after refresh, got \(model.state)")
            return
        }
    }

    @Test func stateIsLoadingBeforeStart() {
        let model = SessionViewModel(backend: InMemoryChoresBackend())
        #expect(model.state == .loading)
    }
}
