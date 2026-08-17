import Testing
import Foundation
import Supabase
@testable import ChoresCore

/// End-to-end tests against a running local Supabase stack.
///
/// These are the only coverage `SupabaseChoresBackend` has — everything else in
/// the app is tested against the in-memory fake — so they exist to catch
/// PostgREST and RLS mistakes here rather than in the simulator.
///
/// Requires:
///   supabase start && supabase db reset
/// Enable with:
///   SUPABASE_INTEGRATION=1 swift test --filter SupabaseIntegrationTests
/// Both keys come from `supabase status -o env`. The service role key is only
/// used to delete an auth user, which no anon-key caller can do.
/// Declared outside the suite: referencing a static member of the type the
/// `@Suite` macro is attached to is a circular reference.
private let integrationTestsEnabled =
    ProcessInfo.processInfo.environment["SUPABASE_INTEGRATION"] == "1"

@Suite(.enabled(if: integrationTestsEnabled,
                "set SUPABASE_INTEGRATION=1 and run `supabase start` to enable"))
struct SupabaseIntegrationTests {

    /// Session storage that lives and dies with the instance, so each backend in a
    /// test is an independent "device".
    final class EphemeralStorage: AuthLocalStorage, @unchecked Sendable {
        private var values: [String: Data] = [:]
        private let lock = NSLock()

        func store(key: String, value: Data) throws {
            lock.withLock { values[key] = value }
        }
        func retrieve(key: String) throws -> Data? {
            lock.withLock { values[key] }
        }
        func remove(key: String) throws {
            lock.withLock { values[key] = nil }
        }

        /// The SDK derives its own key from the project host (`sb-127-auth-token`
        /// against a local stack), so find the session by shape rather than by
        /// name. It encodes with camelCase keys, not the snake_case of the wire
        /// format.
        private var sessionEntry: (key: String, value: Data)? {
            values.first { String(decoding: $0.value, as: UTF8.self).contains("accessToken") }
                .map { ($0.key, $0.value) }
        }

        var storedSession: Data? {
            lock.withLock { sessionEntry?.value }
        }

        /// The auth user the stored session belongs to.
        ///
        /// Read out of storage because the token itself must not be touched. The
        /// SDK verifies signatures locally, so any tampering fails on this device
        /// and never reaches the server — a different code path than the one
        /// worth testing, and an easy way to write a test that passes for the
        /// wrong reason.
        var storedUserID: String? {
            lock.withLock {
                guard let (_, value) = sessionEntry,
                      let json = try? JSONSerialization.jsonObject(with: value)
                          as? [String: Any],
                      let user = json["user"] as? [String: Any] else { return nil }
                return user["id"] as? String
            }
        }

        /// Writes a session obtained over HTTP into the SDK's own storage slot,
        /// so the backend comes up already signed in.
        func plantSession(from signupResponse: Data) throws {
            let wire = try JSONSerialization.jsonObject(with: signupResponse) as? [String: Any]
            // The SDK encodes camelCase, the wire is snake_case.
            let session: [String: Any] = [
                "accessToken": wire?["access_token"] as Any,
                "refreshToken": wire?["refresh_token"] as Any,
                "expiresIn": wire?["expires_in"] as Any,
                "expiresAt": wire?["expires_at"] as Any,
                "tokenType": wire?["token_type"] as Any,
                "user": wire?["user"] as Any
            ]
            lock.withLock {
                values["sb-127-auth-token"] =
                    try? JSONSerialization.data(withJSONObject: session)
            }
        }
    }

    static func makeBackend(
        storage: EphemeralStorage = EphemeralStorage()
    ) throws -> SupabaseChoresBackend {
        let environment = ProcessInfo.processInfo.environment
        let urlString = environment["SUPABASE_URL"] ?? "http://127.0.0.1:54321"
        let key = try #require(environment["SUPABASE_ANON_KEY"],
                               "SUPABASE_ANON_KEY must be set (see `supabase status -o env`)")
        return SupabaseChoresBackend(url: URL(string: urlString)!,
                                     anonKey: key,
                                     sessionStorage: storage)
    }

    /// A confirmed email user, signed in, with the session planted in `storage`.
    ///
    /// Apple cannot be automated, but the rule under test is `is_anonymous`, not
    /// which provider was used — so this exercises the real server on the real
    /// code path a parent takes.
    static func makeSignedInBackend(storage: EphemeralStorage) async throws
        -> SupabaseChoresBackend {
        let environment = ProcessInfo.processInfo.environment
        let urlString = environment["SUPABASE_URL"] ?? "http://127.0.0.1:54321"
        let anonKey = try #require(environment["SUPABASE_ANON_KEY"])
        let email = "parent-\(UUID().uuidString)@example.com"

        var request = URLRequest(url: URL(string: "\(urlString)/auth/v1/signup")!)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email, "password": "hunter2hunter2"
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        #expect(status == 200, "signup failed with \(status)")

        let backend = try makeBackend(storage: storage)
        try storage.plantSession(from: data)
        return backend
    }

    @Test func fullParentAndChildLifecycle() async throws {
        // A parent must hold a durable identity to bootstrap a family — the
        // rule Task 2 added at the database. Everything below the child's
        // claim stays anonymous, because that is the real shape of a child
        // device.
        let parent = try await Self.makeSignedInBackend(storage: EphemeralStorage())

        // A fresh device is signed in but unclaimed.
        #expect(try await parent.currentProfile() == nil)

        // create_family() bootstraps the family and the parent profile together.
        let familyID = try await parent.createFamily(
            familyName: "Integration Koti", parentName: "Parent",
            timezone: "Europe/Helsinki")
        let parentProfile = try #require(try await parent.currentProfile())
        #expect(parentProfile.role == .parent)
        #expect(parentProfile.displayName == "Parent")

        // A second create_family() from the same session must be refused.
        await #expect(throws: ChoresBackendError.self) {
            _ = try await parent.createFamily(familyName: "Another", parentName: "Parent",
                                              timezone: "Europe/Helsinki")
        }

        // Children and chores.
        let child = try await parent.addChild(familyID: familyID, name: "Kid",
                                              color: "#E8710A", sortOrder: 0)
        let dishes = try await parent.addChore(familyID: familyID, name: "Dishes", icon: nil)
        let bins = try await parent.addChore(familyID: familyID, name: "Bins", icon: nil)

        // Weekly template: Monday dishes, Tuesday bins.
        _ = try await parent.addScheduleEntry(familyID: familyID, profileID: child.id,
                                              choreID: dishes.id, weekday: 1)
        _ = try await parent.addScheduleEntry(familyID: familyID, profileID: child.id,
                                              choreID: bins.id, weekday: 2)
        // Re-adding is a no-op rather than a unique violation.
        _ = try await parent.addScheduleEntry(familyID: familyID, profileID: child.id,
                                              choreID: dishes.id, weekday: 1)

        let monday = CalendarDay(year: 2026, month: 8, day: 10)
        var snapshot = try await parent.fetchSnapshot(familyID: familyID, weekOf: monday)
        #expect(snapshot.family.name == "Integration Koti")
        #expect(snapshot.children.map(\.displayName) == ["Kid"])
        #expect(snapshot.activeChores.map(\.name) == ["Bins", "Dishes"])
        #expect(snapshot.template.count == 2)

        // The resolver runs over real fetched data.
        let mondayChores = ScheduleResolver.chores(
            for: child.id, on: monday, template: snapshot.template,
            chores: snapshot.chores, completions: snapshot.completions)
        #expect(mondayChores.map(\.chore.name) == ["Dishes"])

        // Completions: write, verify, then prove the write is idempotent.
        try await parent.complete(familyID: familyID, profileID: child.id,
                                  choreID: dishes.id, dueOn: monday, completedBy: child.id)
        try await parent.complete(familyID: familyID, profileID: child.id,
                                  choreID: dishes.id, dueOn: monday, completedBy: child.id)
        snapshot = try await parent.fetchSnapshot(familyID: familyID, weekOf: monday)
        #expect(snapshot.completions.count == 1)
        #expect(snapshot.completions.first?.dueOn == monday)

        // A completion outside the requested week is not returned.
        let previousWeek = CalendarDay(year: 2026, month: 8, day: 5)
        try await parent.complete(familyID: familyID, profileID: child.id,
                                  choreID: dishes.id, dueOn: previousWeek, completedBy: child.id)
        snapshot = try await parent.fetchSnapshot(familyID: familyID, weekOf: monday)
        #expect(snapshot.completions.count == 1)

        // Reverting removes only the matching row.
        try await parent.uncomplete(profileID: child.id, choreID: dishes.id, dueOn: monday)
        snapshot = try await parent.fetchSnapshot(familyID: familyID, weekOf: monday)
        #expect(snapshot.completions.isEmpty)

        // Archiving hides a chore but keeps its schedule entry.
        var archived = bins
        archived.isArchived = true
        try await parent.updateChore(archived)
        snapshot = try await parent.fetchSnapshot(familyID: familyID, weekOf: monday)
        #expect(snapshot.activeChores.map(\.name) == ["Dishes"])
        #expect(snapshot.template.count == 2)

        // Renaming a child persists.
        var renamed = child
        renamed.displayName = "Renamed"
        try await parent.updateProfile(renamed)
        snapshot = try await parent.fetchSnapshot(familyID: familyID, weekOf: monday)
        #expect(snapshot.children.first?.displayName == "Renamed")

        // copyDay replaces the target day rather than merging into it.
        try await parent.copyDay(familyID: familyID, from: 1, to: [3])
        snapshot = try await parent.fetchSnapshot(familyID: familyID, weekOf: monday)
        let wednesday = snapshot.template.filter { $0.weekday == 3 }
        #expect(wednesday.count == 1)
        #expect(wednesday.first?.choreID == dishes.id)

        // Claim the child profile from a genuinely separate device.
        let code = try await parent.generateClaimCode(profileID: child.id)
        #expect(code.count == 6)

        let kidDevice = try Self.makeBackend()
        try await kidDevice.signInAnonymously()
        #expect(try await kidDevice.currentProfile() == nil)
        _ = try await kidDevice.claimProfile(code: code)
        #expect(try await kidDevice.currentProfile()?.id == child.id)

        // Reuse of a spent code is rejected with its own error.
        let thirdDevice = try Self.makeBackend()
        try await thirdDevice.signInAnonymously()
        await #expect(throws: ChoresBackendError.claimCodeAlreadyUsed) {
            _ = try await thirdDevice.claimProfile(code: code)
        }

        // An unknown code is distinguishable from a spent one.
        await #expect(throws: ChoresBackendError.unknownClaimCode) {
            _ = try await thirdDevice.claimProfile(code: "ZZZZZZ")
        }
    }

    /// RLS enforcement seen through the real client, not just through psql.
    @Test func rlsPreventsChildFromWritingParentOnlyTables() async throws {
        // Signed-in parent, anonymous child — the same split as above, and for
        // the same reason: the RLS rules under test here depend on it.
        let parent = try await Self.makeSignedInBackend(storage: EphemeralStorage())
        let familyID = try await parent.createFamily(
            familyName: "RLS Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await parent.addChild(familyID: familyID, name: "Kid",
                                              color: "#1DB954", sortOrder: 0)
        let code = try await parent.generateClaimCode(profileID: child.id)

        let kidDevice = try Self.makeBackend()
        try await kidDevice.signInAnonymously()
        _ = try await kidDevice.claimProfile(code: code)

        // A child cannot create chores.
        await #expect(throws: ChoresBackendError.self) {
            _ = try await kidDevice.addChore(familyID: familyID, name: "Sneaky", icon: nil)
        }

        // A child may complete their own chore.
        let chore = try await parent.addChore(familyID: familyID, name: "Bins", icon: nil)
        let monday = CalendarDay(year: 2026, month: 8, day: 10)
        try await kidDevice.complete(familyID: familyID, profileID: child.id,
                                     choreID: chore.id, dueOn: monday, completedBy: child.id)

        let snapshot = try await kidDevice.fetchSnapshot(familyID: familyID, weekOf: monday)
        #expect(snapshot.completions.count == 1)
    }

    /// Deletes an auth user out from under a live session, the way
    /// `supabase db reset` does in development and a restore from backup does in
    /// production.
    static func deleteAuthUser(_ id: String) async throws {
        let environment = ProcessInfo.processInfo.environment
        let urlString = environment["SUPABASE_URL"] ?? "http://127.0.0.1:54321"
        let key = try #require(
            environment["SUPABASE_SERVICE_ROLE_KEY"],
            "SUPABASE_SERVICE_ROLE_KEY must be set (see `supabase status -o env`)")

        var request = URLRequest(
            url: URL(string: "\(urlString)/auth/v1/admin/users/\(id)")!)
        request.httpMethod = "DELETE"
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        #expect(status == 200, "admin delete failed with \(status)")
    }

    /// Whether the admin API still knows this user, straight from the server —
    /// not inferred from whether a local session still works.
    static func authUserExists(_ id: String) async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let urlString = environment["SUPABASE_URL"] ?? "http://127.0.0.1:54321"
        let key = try #require(
            environment["SUPABASE_SERVICE_ROLE_KEY"],
            "SUPABASE_SERVICE_ROLE_KEY must be set (see `supabase status -o env`)")

        var request = URLRequest(
            url: URL(string: "\(urlString)/auth/v1/admin/users/\(id)")!)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return status == 200
    }

    /// A stored session outlives the user it names whenever the auth table is
    /// rebuilt — `supabase db reset` in development, a restore from backup in
    /// production. Neither touches the keychain, and the token stays signed and
    /// unexpired, so the session passes every local check and the app carries on
    /// as though claimed. Nothing complains until the first profile write dies
    /// on `profiles_auth_user_id_fkey`, naming a constraint rather than a cause.
    ///
    /// A parent cannot be silently re-authenticated against Apple, so recovery
    /// here is to clear the dead session and report `.none` — not to mint a
    /// fresh one behind the caller's back.
    ///
    /// The token is left pristine here on purpose: corrupting it is caught by
    /// the SDK's own signature check before a request is ever sent, which is a
    /// different path than the one this guards.
    @Test func aSessionTheServerDisownsIsClearedRatherThanCarriedForward() async throws {
        let storage = EphemeralStorage()
        try await Self.makeBackend(storage: storage).signInAnonymously()
        try await Self.deleteAuthUser(try #require(storage.storedUserID))

        // A second backend over the same storage is what a relaunch looks like.
        let relaunched = try Self.makeBackend(storage: storage)
        let identity = try await relaunched.currentIdentity()

        #expect(identity == .none)
        #expect(storage.storedSession == nil,
                "the disowned session must be cleared, not carried forward")

        // The device can still recover on its own, now that the dead session
        // is out of the way. A real parent's recovery path is signing in with
        // Apple again; createFamily now requires a durable identity, so the
        // stand-in here is the same signed-in path the rest of the suite uses.
        let recovered = try await Self.makeSignedInBackend(storage: storage)
        _ = try await recovered.createFamily(
            familyName: "Recovered Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let profile = try #require(try await recovered.currentProfile())
        #expect(profile.role == .parent)
    }

    /// The clearing above must not fire on a device that is merely offline: a
    /// good session discarded because the network blinked cannot be recovered
    /// until the network returns, which is exactly when it is needed.
    @Test func anUnreachableServerLeavesAGoodSessionAlone() async throws {
        let storage = EphemeralStorage()
        try await Self.makeBackend(storage: storage).signInAnonymously()
        let session = try #require(storage.storedSession)

        // Nothing is listening on this port, so every call fails in transport.
        let offline = SupabaseChoresBackend(
            url: URL(string: "http://127.0.0.1:1")!,
            anonKey: ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"] ?? "",
            sessionStorage: storage)
        let identity = try await offline.currentIdentity()

        #expect(identity == .anonymous,
                "an offline device keeps the identity it already had")
        #expect(storage.storedSession == session,
                "a transport failure must not be read as the server disowning us")
    }

    /// The rule the whole design rests on, seen through the real server.
    @Test func anAnonymousCallerCannotCreateAFamily() async throws {
        let backend = try Self.makeBackend()
        try await backend.signInAnonymously()

        await #expect(throws: ChoresBackendError.mustSignIn) {
            _ = try await backend.createFamily(familyName: "Sneaky", parentName: "Kid",
                                               timezone: "Europe/Helsinki")
        }
    }

    @Test func aSignedInParentCanCreateLeaveAndStartAgain() async throws {
        let storage = EphemeralStorage()
        let backend = try await Self.makeSignedInBackend(storage: storage)
        #expect(try await backend.currentIdentity() == .signedIn)

        _ = try await backend.createFamily(familyName: "Koti", parentName: "Parent",
                                           timezone: "Europe/Helsinki")
        #expect(try await backend.currentProfile() != nil)

        try await backend.leaveFamily()
        #expect(try await backend.currentProfile() == nil)

        // Leaving is only worth anything if it frees you to start over.
        _ = try await backend.createFamily(familyName: "Uusi", parentName: "Parent",
                                           timezone: "Europe/Helsinki")
        #expect(try await backend.currentProfile() != nil)
    }

    /// The App Review 5.1.1(v) path, seen through the real server on both
    /// halves nothing else covers: the auth user is actually gone, and the
    /// local session — which `deleteAccount()` signs out only after the RPC
    /// succeeds, by which point it names a user the server no longer has — is
    /// actually cleared rather than left behind for the next launch to trip
    /// over.
    @Test func deletingTheAccountRemovesTheAuthUserAndClearsLocalSession() async throws {
        let storage = EphemeralStorage()
        let backend = try await Self.makeSignedInBackend(storage: storage)
        let userID = try #require(storage.storedUserID)
        _ = try await backend.createFamily(familyName: "Koti", parentName: "Parent",
                                           timezone: "Europe/Helsinki")

        try await backend.deleteAccount()

        #expect(try await Self.authUserExists(userID) == false,
                "delete_account() should have removed the auth user")
        #expect(storage.storedSession == nil,
                "the local session must be cleared, not left naming a user that no longer exists")
    }

    @Test func deletingAChildTakesTheirHistoryAndSparesTheirSibling() async throws {
        let storage = EphemeralStorage()
        let backend = try await Self.makeSignedInBackend(storage: storage)
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
    }

    /// A parent who ticks a chore off for a child, then leaves, must not take the
    /// child's record with them.
    @Test func aDepartingParentLeavesTheChildrensHistoryIntact() async throws {
        let storage = EphemeralStorage()
        let first = try await Self.makeSignedInBackend(storage: storage)
        let familyID = try await first.createFamily(familyName: "Koti", parentName: "First",
                                                     timezone: "Europe/Helsinki")
        let child = try await first.addChild(familyID: familyID, name: "Kid",
                                             color: "#FF8800", sortOrder: 0)
        let chore = try await first.addChore(familyID: familyID, name: "Bins", icon: nil)
        let monday = CalendarDay(year: 2026, month: 8, day: 10)
        let me = try #require(try await first.currentProfile())
        try await first.complete(familyID: familyID, profileID: child.id, choreID: chore.id,
                                 dueOn: monday, completedBy: me.id)

        // A second parent, so leaving does not delete the family outright.
        let secondSeat = try await first.addParent(familyID: familyID, name: "Second")
        let code = try await first.generateClaimCode(profileID: secondSeat.id)
        let secondStorage = EphemeralStorage()
        let second = try await Self.makeSignedInBackend(storage: secondStorage)
        _ = try await second.claimProfile(code: code)

        try await first.leaveFamily()

        let snapshot = try await second.fetchSnapshot(familyID: familyID, weekOf: monday)
        #expect(snapshot.completions.count == 1,
                "the child's record must outlive the parent who entered it")
        #expect(snapshot.completions.first?.completedBy == nil)
    }
}
