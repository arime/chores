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

    func currentIdentity() async throws -> DeviceIdentity {
        try await inner.currentIdentity()
    }
    func signInAnonymously() async throws {
        try await inner.signInAnonymously()
    }
    func signInWithApple(idToken: String, nonce: String) async throws {
        try await inner.signInWithApple(idToken: idToken, nonce: nonce)
    }
    func signOut() async throws {
        try await inner.signOut()
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
    func leaveFamily() async throws {
        try await inner.leaveFamily()
    }
    func deleteAccount() async throws {
        try await inner.deleteAccount()
    }
    func deleteChild(profileID: UUID) async throws {
        try await inner.deleteChild(profileID: profileID)
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

/// A backend whose snapshot fetch parks until released, so a test can inspect
/// what a screen would be drawing while the first refresh is still in flight.
final class GatedBackend: ForwardingBackend, @unchecked Sendable {
    private(set) var isFetching = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    override func fetchSnapshot(familyID: UUID, weekOf day: CalendarDay) async throws -> FamilySnapshot {
        isFetching = true
        await withCheckedContinuation { waiting.append($0) }
        return try await super.fetchSnapshot(familyID: familyID, weekOf: day)
    }

    func release() {
        let pending = waiting
        waiting = []
        pending.forEach { $0.resume() }
    }
}

/// Records how many completion writes are inside the backend at the same moment.
actor ConcurrencyTally {
    private(set) var peak = 0
    private(set) var calls = 0
    private var current = 0

    func enter() {
        current += 1
        calls += 1
        peak = max(peak, current)
    }

    func leave() { current -= 1 }
}

/// A backend whose completion writes stay suspended long enough for a second
/// flush to reach them, so a test can see whether two flushes overlapped rather
/// than having to guess from timing.
final class OverlappingWriteBackend: ForwardingBackend, @unchecked Sendable {
    let tally = ConcurrencyTally()

    override func complete(familyID: UUID, profileID: UUID, choreID: UUID,
                           dueOn: CalendarDay, completedBy: UUID) async throws {
        await tally.enter()
        for _ in 0..<8 { await Task.yield() }
        await tally.leave()
        try await super.complete(familyID: familyID, profileID: profileID,
                                 choreID: choreID, dueOn: dueOn, completedBy: completedBy)
    }
}

/// Holds completion writes suspended until a test releases them, so a test can
/// act on the outbox at the exact moment a flush is mid-send.
actor CompletionGate {
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func park() async {
        await withCheckedContinuation { continuation in
            parked.append(continuation)
            arrivals += 1
            let ready = waiters.filter { $0.target <= arrivals }
            waiters.removeAll { $0.target <= arrivals }
            ready.forEach { $0.continuation.resume() }
        }
    }

    /// Suspends until `count` writes have parked, so a test never has to sleep.
    func waitForArrivals(_ count: Int) async {
        guard arrivals < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func releaseAll() {
        let waiting = parked
        parked = []
        waiting.forEach { $0.resume() }
    }
}

/// A backend whose completion writes park in the gate. Deletes go straight
/// through: it is the send in flight that a test needs to hold still.
final class ParkedWriteBackend: ForwardingBackend, @unchecked Sendable {
    let gate = CompletionGate()
    private(set) var uncompleteCallCount = 0

    override func complete(familyID: UUID, profileID: UUID, choreID: UUID,
                           dueOn: CalendarDay, completedBy: UUID) async throws {
        await gate.park()
        try await super.complete(familyID: familyID, profileID: profileID,
                                 choreID: choreID, dueOn: dueOn, completedBy: completedBy)
    }

    override func uncomplete(profileID: UUID, choreID: UUID, dueOn: CalendarDay) async throws {
        uncompleteCallCount += 1
        try await super.uncomplete(profileID: profileID, choreID: choreID, dueOn: dueOn)
    }
}

/// Fails every call with the same error. The default, `.projectUnavailable`,
/// stands in for a paused project or a device with no connectivity; pass another
/// to exercise a backend that answers and refuses.
final class UnavailableBackend: ChoresBackend, @unchecked Sendable {
    let error: ChoresBackendError

    init(error: ChoresBackendError = .projectUnavailable) {
        self.error = error
    }

    func currentIdentity() async throws -> DeviceIdentity { throw error }
    func signInAnonymously() async throws { throw error }
    func signInWithApple(idToken: String, nonce: String) async throws { throw error }
    func signOut() async throws { throw error }
    func currentProfile() async throws -> Profile? { throw error }
    func createFamily(familyName: String, parentName: String,
                      timezone: String) async throws -> UUID {
        throw error
    }
    func claimProfile(code: String) async throws -> UUID {
        throw error
    }
    func fetchSnapshot(familyID: UUID, weekOf day: CalendarDay) async throws -> FamilySnapshot {
        throw error
    }
    func addChild(familyID: UUID, name: String, color: String,
                  sortOrder: Int) async throws -> Profile {
        throw error
    }
    func addParent(familyID: UUID, name: String) async throws -> Profile {
        throw error
    }
    func updateProfile(_ profile: Profile) async throws {
        throw error
    }
    func generateClaimCode(profileID: UUID) async throws -> String {
        throw error
    }
    func leaveFamily() async throws { throw error }
    func deleteAccount() async throws { throw error }
    func deleteChild(profileID: UUID) async throws { throw error }
    func addChore(familyID: UUID, name: String, icon: String?) async throws -> Chore {
        throw error
    }
    func updateChore(_ chore: Chore) async throws {
        throw error
    }
    func addScheduleEntry(familyID: UUID, profileID: UUID, choreID: UUID,
                          weekday: Int) async throws -> ScheduleEntry {
        throw error
    }
    func removeScheduleEntry(id: UUID) async throws {
        throw error
    }
    func copyDay(familyID: UUID, from fromWeekday: Int, to toWeekdays: [Int]) async throws {
        throw error
    }
    func complete(familyID: UUID, profileID: UUID, choreID: UUID,
                  dueOn: CalendarDay, completedBy: UUID) async throws {
        throw error
    }
    func uncomplete(profileID: UUID, choreID: UUID, dueOn: CalendarDay) async throws {
        throw error
    }
}

/// Creates a fresh temporary directory for cache and outbox files.
func makeTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
