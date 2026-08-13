import Foundation
@testable import ChoresCore

/// Forwards every `ChoresBackend` call to a real in-memory backend.
///
/// Exists so a test double that only cares about one or two methods can override
/// just those, instead of restating all fifteen. Subclasses below do exactly that.
class ForwardingBackend: ChoresBackend, @unchecked Sendable {
    let inner: InMemoryChoresBackend

    init(inner: InMemoryChoresBackend = InMemoryChoresBackend()) {
        self.inner = inner
    }

    func signInAnonymouslyIfNeeded() async throws {
        try await inner.signInAnonymouslyIfNeeded()
    }
    func currentProfile() async throws -> Profile? {
        try await inner.currentProfile()
    }
    func createFamily(familyName: String, parentName: String,
                      timezone: String) async throws -> UUID {
        try await inner.createFamily(familyName: familyName, parentName: parentName,
                                     timezone: timezone)
    }
    func claimProfile(code: String) async throws -> UUID {
        try await inner.claimProfile(code: code)
    }
    func fetchSnapshot(familyID: UUID, weekOf day: CalendarDay) async throws -> FamilySnapshot {
        try await inner.fetchSnapshot(familyID: familyID, weekOf: day)
    }
    func addChild(familyID: UUID, name: String, color: String,
                  sortOrder: Int) async throws -> Profile {
        try await inner.addChild(familyID: familyID, name: name, color: color,
                                 sortOrder: sortOrder)
    }
    func addParent(familyID: UUID, name: String) async throws -> Profile {
        try await inner.addParent(familyID: familyID, name: name)
    }
    func updateProfile(_ profile: Profile) async throws {
        try await inner.updateProfile(profile)
    }
    func generateClaimCode(profileID: UUID) async throws -> String {
        try await inner.generateClaimCode(profileID: profileID)
    }
    func addChore(familyID: UUID, name: String, icon: String?) async throws -> Chore {
        try await inner.addChore(familyID: familyID, name: name, icon: icon)
    }
    func updateChore(_ chore: Chore) async throws {
        try await inner.updateChore(chore)
    }
    func addScheduleEntry(familyID: UUID, profileID: UUID, choreID: UUID,
                          weekday: Int) async throws -> ScheduleEntry {
        try await inner.addScheduleEntry(familyID: familyID, profileID: profileID,
                                        choreID: choreID, weekday: weekday)
    }
    func removeScheduleEntry(id: UUID) async throws {
        try await inner.removeScheduleEntry(id: id)
    }
    func copyDay(familyID: UUID, from fromWeekday: Int, to toWeekdays: [Int]) async throws {
        try await inner.copyDay(familyID: familyID, from: fromWeekday, to: toWeekdays)
    }
    func complete(familyID: UUID, profileID: UUID, choreID: UUID,
                  dueOn: CalendarDay, completedBy: UUID) async throws {
        try await inner.complete(familyID: familyID, profileID: profileID,
                                 choreID: choreID, dueOn: dueOn, completedBy: completedBy)
    }
    func uncomplete(profileID: UUID, choreID: UUID, dueOn: CalendarDay) async throws {
        try await inner.uncomplete(profileID: profileID, choreID: choreID, dueOn: dueOn)
    }
}

/// A backend whose completion writes fail on demand, so flush behaviour can be
/// driven deterministically. Also counts calls, to prove replay actually happened.
final class FlakyBackend: ForwardingBackend, @unchecked Sendable {
    var shouldFail = false
    private(set) var completeCallCount = 0
    private(set) var uncompleteCallCount = 0

    override func complete(familyID: UUID, profileID: UUID, choreID: UUID,
                           dueOn: CalendarDay, completedBy: UUID) async throws {
        if shouldFail { throw ChoresBackendError.projectUnavailable }
        completeCallCount += 1
        try await super.complete(familyID: familyID, profileID: profileID,
                                 choreID: choreID, dueOn: dueOn, completedBy: completedBy)
    }

    override func uncomplete(profileID: UUID, choreID: UUID, dueOn: CalendarDay) async throws {
        if shouldFail { throw ChoresBackendError.projectUnavailable }
        uncompleteCallCount += 1
        try await super.uncomplete(profileID: profileID, choreID: choreID, dueOn: dueOn)
    }
}

/// Fails every call with `.projectUnavailable`, standing in for a paused project
/// or a device with no connectivity.
final class UnavailableBackend: ChoresBackend, @unchecked Sendable {
    func signInAnonymouslyIfNeeded() async throws { throw ChoresBackendError.projectUnavailable }
    func currentProfile() async throws -> Profile? { throw ChoresBackendError.projectUnavailable }
    func createFamily(familyName: String, parentName: String,
                      timezone: String) async throws -> UUID {
        throw ChoresBackendError.projectUnavailable
    }
    func claimProfile(code: String) async throws -> UUID {
        throw ChoresBackendError.projectUnavailable
    }
    func fetchSnapshot(familyID: UUID, weekOf day: CalendarDay) async throws -> FamilySnapshot {
        throw ChoresBackendError.projectUnavailable
    }
    func addChild(familyID: UUID, name: String, color: String,
                  sortOrder: Int) async throws -> Profile {
        throw ChoresBackendError.projectUnavailable
    }
    func addParent(familyID: UUID, name: String) async throws -> Profile {
        throw ChoresBackendError.projectUnavailable
    }
    func updateProfile(_ profile: Profile) async throws {
        throw ChoresBackendError.projectUnavailable
    }
    func generateClaimCode(profileID: UUID) async throws -> String {
        throw ChoresBackendError.projectUnavailable
    }
    func addChore(familyID: UUID, name: String, icon: String?) async throws -> Chore {
        throw ChoresBackendError.projectUnavailable
    }
    func updateChore(_ chore: Chore) async throws {
        throw ChoresBackendError.projectUnavailable
    }
    func addScheduleEntry(familyID: UUID, profileID: UUID, choreID: UUID,
                          weekday: Int) async throws -> ScheduleEntry {
        throw ChoresBackendError.projectUnavailable
    }
    func removeScheduleEntry(id: UUID) async throws {
        throw ChoresBackendError.projectUnavailable
    }
    func copyDay(familyID: UUID, from fromWeekday: Int, to toWeekdays: [Int]) async throws {
        throw ChoresBackendError.projectUnavailable
    }
    func complete(familyID: UUID, profileID: UUID, choreID: UUID,
                  dueOn: CalendarDay, completedBy: UUID) async throws {
        throw ChoresBackendError.projectUnavailable
    }
    func uncomplete(profileID: UUID, choreID: UUID, dueOn: CalendarDay) async throws {
        throw ChoresBackendError.projectUnavailable
    }
}

/// Creates a fresh temporary directory for cache and outbox files.
func makeTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
