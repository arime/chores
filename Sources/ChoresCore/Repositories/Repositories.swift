import Foundation

public enum ChoresBackendError: Error, Equatable, Sendable {
    case notAuthenticated
    case alreadyClaimed
    case unknownClaimCode
    case claimCodeAlreadyUsed
    case claimCodeExpired
    /// The project is paused or unreachable. Kept distinct because the remedy is
    /// resuming a paused project, not retrying — and a generic "network error"
    /// would send the maintainer debugging the app instead.
    case projectUnavailable
    case underlying(String)
}

/// What kind of identity this device currently holds.
///
/// The distinction is drawn from the session's `is_anonymous` claim rather than
/// from which provider was used: the database rule is about durability of
/// identity, not about Apple. Apple is simply the only way a person can obtain
/// a `.signedIn` session today.
public enum DeviceIdentity: Equatable, Sendable {
    case none
    case anonymous
    case signedIn
}

/// The app's entire data boundary. View models depend on this and never on
/// Supabase types, which is what lets every one of them be tested in-process.
///
/// One protocol rather than five: the app always needs the whole family graph at
/// once, and splitting it would only create five fakes to keep in sync.
public protocol ChoresBackend: Sendable {

    // MARK: Session

    func currentIdentity() async throws -> DeviceIdentity
    /// A child device. Parents never take this path.
    func signInAnonymously() async throws
    /// The token and nonce come from `AuthenticationServices` in the app target;
    /// this layer never imports it.
    func signInWithApple(idToken: String, nonce: String) async throws
    func signOut() async throws
    /// The profile bound to the current session, or nil if this device is unclaimed.
    func currentProfile() async throws -> Profile?

    // MARK: Bootstrap

    func createFamily(familyName: String, parentName: String, timezone: String) async throws -> UUID
    func claimProfile(code: String) async throws -> UUID

    // MARK: Reads

    func fetchSnapshot(familyID: UUID, weekOf day: CalendarDay) async throws -> FamilySnapshot

    // MARK: People

    func addChild(familyID: UUID, name: String, color: String, sortOrder: Int) async throws -> Profile
    /// A second parent. They get the full set of parent powers the moment they
    /// claim a device, because every policy asks `is_parent()` rather than
    /// naming a particular one.
    func addParent(familyID: UUID, name: String) async throws -> Profile
    func updateProfile(_ profile: Profile) async throws
    func generateClaimCode(profileID: UUID) async throws -> String

    // MARK: Chores

    func addChore(familyID: UUID, name: String, icon: String?) async throws -> Chore
    func updateChore(_ chore: Chore) async throws

    // MARK: Schedule

    func addScheduleEntry(familyID: UUID, profileID: UUID, choreID: UUID,
                          weekday: Int) async throws -> ScheduleEntry
    func removeScheduleEntry(id: UUID) async throws
    /// Replaces the assignments on each day in `toWeekdays` with those from
    /// `fromWeekday`. Replaces rather than merges — copying a day onto a populated
    /// one should leave it looking like the source.
    func copyDay(familyID: UUID, from fromWeekday: Int, to toWeekdays: [Int]) async throws

    // MARK: Completions

    func complete(familyID: UUID, profileID: UUID, choreID: UUID,
                  dueOn: CalendarDay, completedBy: UUID) async throws
    func uncomplete(profileID: UUID, choreID: UUID, dueOn: CalendarDay) async throws
}
