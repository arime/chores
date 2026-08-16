import Testing
import Foundation
@testable import ChoresCore

@MainActor
@Suite struct SessionViewModelTests {

    @Test func startWithNoProfileYieldsUnclaimed() async {
        let model = SessionViewModel(backend: InMemoryChoresBackend())
        await model.start()
        #expect(model.state == .unclaimed)
    }

    @Test func startAfterCreatingAFamilyYieldsParent() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymouslyIfNeeded()
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
        try await parentBackend.signInAnonymouslyIfNeeded()
        let familyID = try await parentBackend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await parentBackend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let code = try await parentBackend.generateClaimCode(profileID: child.id)

        let kidBackend = parentBackend.newDevice()
        try await kidBackend.signInAnonymouslyIfNeeded()
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
        try await parentBackend.signInAnonymouslyIfNeeded()
        let familyID = try await parentBackend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await parentBackend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let code = try await parentBackend.generateClaimCode(profileID: child.id)

        let kidBackend = parentBackend.newDevice()
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
