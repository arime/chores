import Foundation

/// A complete in-process implementation of `ChoresBackend`, used by view-model
/// tests and SwiftUI previews.
///
/// It mirrors the database's constraints deliberately — the completion and
/// schedule-entry uniqueness in particular — so that a test passing here means
/// something about the real backend.
///
/// Shared state lives in a reference box so `newDevice()` can simulate a second
/// device talking to the same "server".
public final class InMemoryChoresBackend: ChoresBackend, @unchecked Sendable {

    final class Store {
        var families: [UUID: Family] = [:]
        var profiles: [UUID: Profile] = [:]
        var claimCodes: [String: ClaimCodeRecord] = [:]
        var chores: [UUID: Chore] = [:]
        var template: [UUID: ScheduleEntry] = [:]
        var completions: [Completion] = []
        var nextCodeSuffix = 0
        let lock = NSLock()
    }

    struct ClaimCodeRecord {
        let profileID: UUID
        let familyID: UUID
        var claimed: Bool
        var expiresAt: Date
    }

    let store: Store
    var sessionUserID: UUID?

    public init() { self.store = Store() }
    private init(sharing store: Store) { self.store = store }

    /// A second client against the same shared state.
    public func newDevice() -> InMemoryChoresBackend { InMemoryChoresBackend(sharing: store) }

    func withStore<T>(_ body: (Store) throws -> T) rethrows -> T {
        store.lock.lock()
        defer { store.lock.unlock() }
        return try body(store)
    }

    // MARK: Session

    public func signInAnonymouslyIfNeeded() async throws {
        if sessionUserID == nil { sessionUserID = UUID() }
    }

    public func currentProfile() async throws -> Profile? {
        guard let userID = sessionUserID else { return nil }
        return withStore { store in
            store.profiles.values.first { $0.authUserID == userID }
        }
    }

    // MARK: Bootstrap

    public func createFamily(familyName: String, parentName: String,
                             timezone: String) async throws -> UUID {
        guard let userID = sessionUserID else { throw ChoresBackendError.notAuthenticated }
        if try await currentProfile() != nil { throw ChoresBackendError.alreadyClaimed }

        let family = Family(id: UUID(), name: familyName, timezone: timezone)
        let parent = Profile(id: UUID(), familyID: family.id, authUserID: userID,
                             displayName: parentName, role: .parent)
        withStore { store in
            store.families[family.id] = family
            store.profiles[parent.id] = parent
        }
        return family.id
    }

    public func claimProfile(code: String) async throws -> UUID {
        guard let userID = sessionUserID else { throw ChoresBackendError.notAuthenticated }
        if try await currentProfile() != nil { throw ChoresBackendError.alreadyClaimed }
        let normalised = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        return try withStore { store in
            guard let record = store.claimCodes[normalised] else {
                throw ChoresBackendError.unknownClaimCode
            }
            if record.claimed { throw ChoresBackendError.claimCodeAlreadyUsed }
            if record.expiresAt < Date() { throw ChoresBackendError.claimCodeExpired }

            store.profiles[record.profileID]?.authUserID = userID
            store.claimCodes[normalised]?.claimed = true
            return record.profileID
        }
    }

    // MARK: Reads

    public func fetchSnapshot(familyID: UUID,
                             weekOf day: CalendarDay) async throws -> FamilySnapshot {
        let week = Set(WeekCalendar.isoWeek(containing: day))
        return try withStore { store in
            guard let family = store.families[familyID] else {
                throw ChoresBackendError.underlying("no such family")
            }
            return FamilySnapshot(
                family: family,
                profiles: store.profiles.values.filter { $0.familyID == familyID },
                chores: store.chores.values.filter { $0.familyID == familyID },
                template: store.template.values.filter { $0.familyID == familyID },
                completions: store.completions.filter {
                    $0.familyID == familyID && week.contains($0.dueOn)
                },
                fetchedAt: Date())
        }
    }

    // MARK: Children

    public func addChild(familyID: UUID, name: String, color: String,
                         sortOrder: Int) async throws -> Profile {
        let profile = Profile(id: UUID(), familyID: familyID, displayName: name,
                              role: .child, color: color, sortOrder: sortOrder)
        withStore { $0.profiles[profile.id] = profile }
        return profile
    }

    public func updateProfile(_ profile: Profile) async throws {
        withStore { $0.profiles[profile.id] = profile }
    }

    public func generateClaimCode(profileID: UUID) async throws -> String {
        try withStore { store in
            guard let profile = store.profiles[profileID] else {
                throw ChoresBackendError.underlying("no such profile")
            }
            // Issuing a new code invalidates any outstanding unclaimed one.
            store.claimCodes = store.claimCodes.filter {
                !($0.value.profileID == profileID && !$0.value.claimed)
            }
            store.nextCodeSuffix += 1
            let code = String(format: "TEST%02d", store.nextCodeSuffix)
            store.claimCodes[code] = ClaimCodeRecord(
                profileID: profileID, familyID: profile.familyID,
                claimed: false, expiresAt: Date().addingTimeInterval(7 * 24 * 3600))
            return code
        }
    }

    // MARK: Chores

    public func addChore(familyID: UUID, name: String, icon: String?) async throws -> Chore {
        let chore = Chore(id: UUID(), familyID: familyID, name: name, icon: icon)
        withStore { $0.chores[chore.id] = chore }
        return chore
    }

    public func updateChore(_ chore: Chore) async throws {
        withStore { $0.chores[chore.id] = chore }
    }

    // MARK: Schedule

    public func addScheduleEntry(familyID: UUID, profileID: UUID, choreID: UUID,
                                 weekday: Int) async throws -> ScheduleEntry {
        withStore { store in
            // Mirrors the (profile_id, chore_id, weekday) unique constraint.
            if let existing = store.template.values.first(where: {
                $0.profileID == profileID && $0.choreID == choreID && $0.weekday == weekday
            }) {
                return existing
            }
            let entry = ScheduleEntry(id: UUID(), familyID: familyID, profileID: profileID,
                                      choreID: choreID, weekday: weekday)
            store.template[entry.id] = entry
            return entry
        }
    }

    public func removeScheduleEntry(id: UUID) async throws {
        withStore { $0.template[id] = nil }
    }

    public func copyDay(familyID: UUID, from fromWeekday: Int, to toWeekdays: [Int]) async throws {
        withStore { store in
            let source = store.template.values.filter {
                $0.familyID == familyID && $0.weekday == fromWeekday
            }
            for target in toWeekdays where target != fromWeekday {
                for existing in store.template.values
                where existing.familyID == familyID && existing.weekday == target {
                    store.template[existing.id] = nil
                }
                for entry in source {
                    let copy = ScheduleEntry(id: UUID(), familyID: familyID,
                                             profileID: entry.profileID,
                                             choreID: entry.choreID, weekday: target)
                    store.template[copy.id] = copy
                }
            }
        }
    }

    // MARK: Completions

    public func complete(familyID: UUID, profileID: UUID, choreID: UUID,
                         dueOn: CalendarDay, completedBy: UUID) async throws {
        withStore { store in
            // Mirrors the (profile_id, chore_id, due_on) unique constraint, which is
            // what makes outbox replay safe.
            let exists = store.completions.contains {
                $0.profileID == profileID && $0.choreID == choreID && $0.dueOn == dueOn
            }
            guard !exists else { return }
            store.completions.append(Completion(
                id: UUID(), familyID: familyID, profileID: profileID, choreID: choreID,
                dueOn: dueOn, completedBy: completedBy))
        }
    }

    public func uncomplete(profileID: UUID, choreID: UUID, dueOn: CalendarDay) async throws {
        withStore { store in
            store.completions.removeAll {
                $0.profileID == profileID && $0.choreID == choreID && $0.dueOn == dueOn
            }
        }
    }
}
