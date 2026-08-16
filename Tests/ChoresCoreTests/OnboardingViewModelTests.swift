import Testing
import Foundation
@testable import ChoresCore

@MainActor
@Suite struct OnboardingViewModelTests {

    /// A parent backend with one unclaimed child, plus that child's code.
    func makeFamilyWithChild() async throws -> (backend: InMemoryChoresBackend,
                                                childID: UUID,
                                                code: String) {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        let familyID = try await backend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await backend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let code = try await backend.generateClaimCode(profileID: child.id)
        return (backend, child.id, code)
    }

    @Test func createFamilySucceedsAndLeavesNoError() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        let model = OnboardingViewModel(backend: backend)
        model.familyName = "Koti"
        model.parentName = "Parent"

        let succeeded = await model.createFamily()

        #expect(succeeded)
        #expect(model.errorMessage == nil)
        #expect(try await backend.currentProfile()?.role == .parent)
    }

    @Test func createFamilyTrimsWhitespaceFromNames() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        let model = OnboardingViewModel(backend: backend)
        model.familyName = "  Koti  "
        model.parentName = "  Parent  "

        #expect(await model.createFamily())
        #expect(try await backend.currentProfile()?.displayName == "Parent")
    }

    @Test func createFamilyRejectsBlankNamesWithoutCallingTheBackend() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        let model = OnboardingViewModel(backend: backend)
        model.familyName = "   "
        model.parentName = "Parent"

        let succeeded = await model.createFamily()

        #expect(!succeeded)
        #expect(model.errorMessage != nil)
        #expect(try await backend.currentProfile() == nil)
    }

    @Test func claimWithAValidCodeSucceeds() async throws {
        let fixture = try await makeFamilyWithChild()
        let kidBackend = fixture.backend.newDevice()
        try await kidBackend.signInAnonymously()

        let model = OnboardingViewModel(backend: kidBackend)
        model.code = fixture.code

        #expect(await model.claim())
        #expect(try await kidBackend.currentProfile()?.id == fixture.childID)
    }

    @Test func claimAcceptsLowercaseAndSurroundingWhitespace() async throws {
        // Children will type this on a phone keyboard; be forgiving.
        let fixture = try await makeFamilyWithChild()
        let kidBackend = fixture.backend.newDevice()
        try await kidBackend.signInAnonymously()

        let model = OnboardingViewModel(backend: kidBackend)
        model.code = "  \(fixture.code.lowercased()) "

        #expect(await model.claim())
        #expect(try await kidBackend.currentProfile()?.id == fixture.childID)
    }

    @Test func claimRejectsAnEmptyCodeWithoutCallingTheBackend() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        let model = OnboardingViewModel(backend: backend)
        model.code = "   "

        #expect(!(await model.claim()))
        #expect(model.errorMessage != nil)
    }

    /// Each failure has a different remedy, so each needs its own wording. This is
    /// the whole reason claim_profile() raises distinct SQLSTATEs.
    @Test func unknownCodeGetsItsOwnMessage() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        let model = OnboardingViewModel(backend: backend)
        model.code = "ZZZZZZ"

        #expect(!(await model.claim()))
        #expect(model.errorMessage?.contains("don't recognise") == true)
    }

    @Test func usedCodeTellsTheChildToAskForANewOne() async throws {
        let fixture = try await makeFamilyWithChild()

        let firstDevice = fixture.backend.newDevice()
        try await firstDevice.signInAnonymously()
        _ = try await firstDevice.claimProfile(code: fixture.code)

        let secondDevice = fixture.backend.newDevice()
        try await secondDevice.signInAnonymously()
        let model = OnboardingViewModel(backend: secondDevice)
        model.code = fixture.code

        #expect(!(await model.claim()))
        #expect(model.errorMessage?.contains("already been used") == true)
        #expect(model.errorMessage?.contains("new one") == true)
    }

    @Test func unreachableBackendReportsAConnectionProblem() async {
        let model = OnboardingViewModel(backend: UnavailableBackend())
        model.code = "ABC123"

        #expect(!(await model.claim()))
        #expect(model.errorMessage?.contains("reach the server") == true)
    }

    @Test func isBusyIsClearedAfterAFailedCall() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        let model = OnboardingViewModel(backend: backend)
        model.code = "ZZZZZZ"

        _ = await model.claim()

        #expect(!model.isBusy)
    }

    @Test func aRetryClearsThePreviousErrorOnSuccess() async throws {
        let fixture = try await makeFamilyWithChild()
        let kidBackend = fixture.backend.newDevice()
        try await kidBackend.signInAnonymously()
        let model = OnboardingViewModel(backend: kidBackend)

        model.code = "ZZZZZZ"
        _ = await model.claim()
        #expect(model.errorMessage != nil)

        model.code = fixture.code
        #expect(await model.claim())
        #expect(model.errorMessage == nil)
    }
}
