import Testing
import Foundation
@testable import ChoresCore

@Suite struct InMemoryBackendTests {

    @Test func createFamilyProducesAParentProfile() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        _ = try await backend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")

        let profile = try await backend.currentProfile()
        #expect(profile?.role == .parent)
        #expect(profile?.displayName == "Parent")
    }

    @Test func createFamilyRejectsACallerWhoAlreadyHasAProfile() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        _ = try await backend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")

        await #expect(throws: ChoresBackendError.alreadyClaimed) {
            _ = try await backend.createFamily(
                familyName: "Second", parentName: "Parent", timezone: "Europe/Helsinki")
        }
    }

    @Test func claimingAValidCodeBindsTheProfile() async throws {
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

        let claimed = try await kidBackend.currentProfile()
        #expect(claimed?.id == child.id)
        #expect(claimed?.role == .child)
    }

    @Test func aSecondParentClaimsIntoParentMode() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        let familyID = try await backend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let other = try await backend.addParent(familyID: familyID, name: "Other parent")
        let code = try await backend.generateClaimCode(profileID: other.id)

        let device = backend.newDevice()
        try await device.signInAnonymously()
        _ = try await device.claimProfile(code: code)

        let claimed = try await device.currentProfile()
        #expect(claimed?.id == other.id)
        // Role is what routes the app to parent mode, and what every RLS policy
        // asks about — so this is the whole of "they have parent powers".
        #expect(claimed?.role == .parent)
    }

    @Test func bothParentsAppearInTheSnapshot() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        let familyID = try await backend.createFamily(
            familyName: "Koti", parentName: "Ari", timezone: "Europe/Helsinki")
        _ = try await backend.addParent(familyID: familyID, name: "Bo")
        _ = try await backend.addChild(familyID: familyID, name: "Kid",
                                       color: "#FF8800", sortOrder: 0)

        let snapshot = try await backend.fetchSnapshot(
            familyID: familyID, weekOf: CalendarDay(year: 2026, month: 8, day: 13))

        #expect(snapshot.parents.map(\.displayName) == ["Ari", "Bo"])
        #expect(snapshot.children.map(\.displayName) == ["Kid"])
    }

    @Test func claimCodeEntryIsCaseAndWhitespaceInsensitive() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        let familyID = try await backend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await backend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let code = try await backend.generateClaimCode(profileID: child.id)

        let device = backend.newDevice()
        try await device.signInAnonymously()
        _ = try await device.claimProfile(code: "  \(code.lowercased())  ")

        #expect(try await device.currentProfile()?.id == child.id)
    }

    @Test func reusingAClaimCodeFails() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        let familyID = try await backend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await backend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let code = try await backend.generateClaimCode(profileID: child.id)

        let first = backend.newDevice()
        try await first.signInAnonymously()
        _ = try await first.claimProfile(code: code)

        let second = backend.newDevice()
        try await second.signInAnonymously()
        await #expect(throws: ChoresBackendError.claimCodeAlreadyUsed) {
            _ = try await second.claimProfile(code: code)
        }
    }

    @Test func unknownClaimCodeFails() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        await #expect(throws: ChoresBackendError.unknownClaimCode) {
            _ = try await backend.claimProfile(code: "ZZZZZZ")
        }
    }

    @Test func generatingANewCodeInvalidatesTheOutstandingOne() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        let familyID = try await backend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await backend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)

        let firstCode = try await backend.generateClaimCode(profileID: child.id)
        _ = try await backend.generateClaimCode(profileID: child.id)

        let device = backend.newDevice()
        try await device.signInAnonymously()
        await #expect(throws: ChoresBackendError.unknownClaimCode) {
            _ = try await device.claimProfile(code: firstCode)
        }
    }

    @Test func completingTwiceIsIdempotent() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        let familyID = try await backend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await backend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let chore = try await backend.addChore(familyID: familyID, name: "Bins", icon: nil)
        let day = CalendarDay(year: 2026, month: 8, day: 10)

        try await backend.complete(familyID: familyID, profileID: child.id,
                                   choreID: chore.id, dueOn: day, completedBy: child.id)
        try await backend.complete(familyID: familyID, profileID: child.id,
                                   choreID: chore.id, dueOn: day, completedBy: child.id)

        let snapshot = try await backend.fetchSnapshot(familyID: familyID, weekOf: day)
        #expect(snapshot.completions.count == 1)
    }

    @Test func addingTheSameScheduleEntryTwiceIsIdempotent() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        let familyID = try await backend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await backend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let chore = try await backend.addChore(familyID: familyID, name: "Bins", icon: nil)

        let first = try await backend.addScheduleEntry(
            familyID: familyID, profileID: child.id, choreID: chore.id, weekday: 1)
        let second = try await backend.addScheduleEntry(
            familyID: familyID, profileID: child.id, choreID: chore.id, weekday: 1)

        #expect(first.id == second.id)
    }

    @Test func copyDayReplacesTargetDayAssignments() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        let familyID = try await backend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await backend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let dishes = try await backend.addChore(familyID: familyID, name: "Dishes", icon: nil)
        let bins = try await backend.addChore(familyID: familyID, name: "Bins", icon: nil)

        _ = try await backend.addScheduleEntry(familyID: familyID, profileID: child.id,
                                               choreID: dishes.id, weekday: 1)
        _ = try await backend.addScheduleEntry(familyID: familyID, profileID: child.id,
                                               choreID: bins.id, weekday: 2)

        try await backend.copyDay(familyID: familyID, from: 1, to: [2, 3])

        let snapshot = try await backend.fetchSnapshot(
            familyID: familyID, weekOf: CalendarDay(year: 2026, month: 8, day: 10))
        let tuesday = snapshot.template.filter { $0.weekday == 2 }
        let wednesday = snapshot.template.filter { $0.weekday == 3 }

        #expect(tuesday.count == 1)
        #expect(tuesday.first?.choreID == dishes.id)   // Bins was replaced, not merged
        #expect(wednesday.count == 1)
    }

    @Test func snapshotContainsOnlyTheRequestedWeeksCompletions() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        let familyID = try await backend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await backend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let chore = try await backend.addChore(familyID: familyID, name: "Bins", icon: nil)

        let thisWeek = CalendarDay(year: 2026, month: 8, day: 12)
        let lastWeek = CalendarDay(year: 2026, month: 8, day: 5)
        try await backend.complete(familyID: familyID, profileID: child.id,
                                   choreID: chore.id, dueOn: thisWeek, completedBy: child.id)
        try await backend.complete(familyID: familyID, profileID: child.id,
                                   choreID: chore.id, dueOn: lastWeek, completedBy: child.id)

        let snapshot = try await backend.fetchSnapshot(familyID: familyID, weekOf: thisWeek)
        #expect(snapshot.completions.count == 1)
        #expect(snapshot.completions.first?.dueOn == thisWeek)
    }

    @Test func uncompleteRemovesOnlyTheMatchingCompletion() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        let familyID = try await backend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await backend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let bins = try await backend.addChore(familyID: familyID, name: "Bins", icon: nil)
        let dishes = try await backend.addChore(familyID: familyID, name: "Dishes", icon: nil)
        let day = CalendarDay(year: 2026, month: 8, day: 10)

        try await backend.complete(familyID: familyID, profileID: child.id,
                                   choreID: bins.id, dueOn: day, completedBy: child.id)
        try await backend.complete(familyID: familyID, profileID: child.id,
                                   choreID: dishes.id, dueOn: day, completedBy: child.id)
        try await backend.uncomplete(profileID: child.id, choreID: bins.id, dueOn: day)

        let snapshot = try await backend.fetchSnapshot(familyID: familyID, weekOf: day)
        #expect(snapshot.completions.count == 1)
        #expect(snapshot.completions.first?.choreID == dishes.id)
    }

    @Test func identityStartsAtNoneAndFollowsHowYouSignedIn() async throws {
        let backend = InMemoryChoresBackend()
        #expect(try await backend.currentIdentity() == .none)

        try await backend.signInAnonymously()
        #expect(try await backend.currentIdentity() == .anonymous)

        try await backend.signOut()
        #expect(try await backend.currentIdentity() == .none)

        try await backend.signInWithApple(idToken: "token", nonce: "nonce")
        #expect(try await backend.currentIdentity() == .signedIn)
    }

    /// The same Apple identity must resolve to the same user, or a reinstall would
    /// look like a new person and the whole feature would be pointless.
    @Test func signingInWithTheSameAppleTokenTwiceIsTheSamePerson() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInWithApple(idToken: "ari", nonce: "n1")
        _ = try await backend.createFamily(familyName: "Koti", parentName: "Parent",
                                           timezone: "Europe/Helsinki")

        try await backend.signOut()
        try await backend.signInWithApple(idToken: "ari", nonce: "n2")

        let profile = try #require(try await backend.currentProfile())
        #expect(profile.displayName == "Parent")
    }

    @Test func snapshotHelpersSortAndFilter() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        let familyID = try await backend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        _ = try await backend.addChild(familyID: familyID, name: "Second",
                                       color: "#FF8800", sortOrder: 1)
        _ = try await backend.addChild(familyID: familyID, name: "First",
                                       color: "#00897B", sortOrder: 0)
        var archived = try await backend.addChore(familyID: familyID, name: "Old", icon: nil)
        archived.isArchived = true
        try await backend.updateChore(archived)
        _ = try await backend.addChore(familyID: familyID, name: "Bins", icon: nil)

        let snapshot = try await backend.fetchSnapshot(
            familyID: familyID, weekOf: CalendarDay(year: 2026, month: 8, day: 10))

        // children excludes the parent and honours sortOrder
        #expect(snapshot.children.map(\.displayName) == ["First", "Second"])
        // activeChores excludes archived
        #expect(snapshot.activeChores.map(\.name) == ["Bins"])
    }

    @Test func leavingRemovesYouAndFreesYouToStartAgain() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInWithApple(idToken: "ari", nonce: "n")
        _ = try await backend.createFamily(familyName: "Koti", parentName: "Parent",
                                           timezone: "Europe/Helsinki")

        try await backend.leaveFamily()

        #expect(try await backend.currentProfile() == nil)
        // The point of leaving: create_family refuses a caller who already has a
        // profile, so leaving must actually clear it.
        _ = try await backend.createFamily(familyName: "Uusi", parentName: "Parent",
                                           timezone: "Europe/Helsinki")
        #expect(try await backend.currentProfile() != nil)
    }

    @Test func deletingAChildTakesTheirCompletionsAndLeavesSiblingsAlone() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInWithApple(idToken: "ari", nonce: "n")
        let familyID = try await backend.createFamily(familyName: "Koti", parentName: "Parent",
                                                      timezone: "Europe/Helsinki")
        let doomed = try await backend.addChild(familyID: familyID, name: "A",
                                                color: "#FF8800", sortOrder: 0)
        let sibling = try await backend.addChild(familyID: familyID, name: "B",
                                                 color: "#1DB954", sortOrder: 1)
        let chore = try await backend.addChore(familyID: familyID, name: "Bins", icon: nil)
        let monday = CalendarDay(year: 2026, month: 8, day: 10)
        try await backend.complete(familyID: familyID, profileID: doomed.id, choreID: chore.id,
                                   dueOn: monday, completedBy: doomed.id)
        try await backend.complete(familyID: familyID, profileID: sibling.id, choreID: chore.id,
                                   dueOn: monday, completedBy: sibling.id)

        try await backend.deleteChild(profileID: doomed.id)

        let snapshot = try await backend.fetchSnapshot(familyID: familyID, weekOf: monday)
        #expect(!snapshot.profiles.contains { $0.id == doomed.id })
        #expect(snapshot.completions.count == 1)
        #expect(snapshot.completions.first?.profileID == sibling.id)
    }

    @Test func leavingWithAnotherParentPresentRemovesOnlyYou() async throws {
        let backend = InMemoryChoresBackend()
        try await backend.signInWithApple(idToken: "ari", nonce: "n")
        let familyID = try await backend.createFamily(familyName: "Koti", parentName: "Ari",
                                                       timezone: "Europe/Helsinki")
        let otherParent = try await backend.addParent(familyID: familyID, name: "Bo")
        let code = try await backend.generateClaimCode(profileID: otherParent.id)
        let child = try await backend.addChild(familyID: familyID, name: "Kid",
                                               color: "#FF8800", sortOrder: 0)

        let otherDevice = backend.newDevice()
        try await otherDevice.signInWithApple(idToken: "bo", nonce: "n")
        _ = try await otherDevice.claimProfile(code: code)

        let departing = try #require(try await backend.currentProfile())
        try await backend.leaveFamily()

        // The family survives, and only the departing parent is gone — a cascade
        // that took too much with it would show up as a missing survivor here.
        let snapshot = try await otherDevice.fetchSnapshot(
            familyID: familyID, weekOf: CalendarDay(year: 2026, month: 8, day: 10))
        #expect(!snapshot.profiles.contains { $0.id == departing.id })
        #expect(snapshot.profiles.contains { $0.id == otherParent.id })
        #expect(snapshot.profiles.contains { $0.id == child.id })
    }
}
