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

    @Test func fullParentAndChildLifecycle() async throws {
        let parent = try Self.makeBackend()

        // A fresh device is signed in but unclaimed.
        try await parent.signInAnonymouslyIfNeeded()
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
        try await kidDevice.signInAnonymouslyIfNeeded()
        #expect(try await kidDevice.currentProfile() == nil)
        _ = try await kidDevice.claimProfile(code: code)
        #expect(try await kidDevice.currentProfile()?.id == child.id)

        // Reuse of a spent code is rejected with its own error.
        let thirdDevice = try Self.makeBackend()
        try await thirdDevice.signInAnonymouslyIfNeeded()
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
        let parent = try Self.makeBackend()
        try await parent.signInAnonymouslyIfNeeded()
        let familyID = try await parent.createFamily(
            familyName: "RLS Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await parent.addChild(familyID: familyID, name: "Kid",
                                              color: "#1DB954", sortOrder: 0)
        let code = try await parent.generateClaimCode(profileID: child.id)

        let kidDevice = try Self.makeBackend()
        try await kidDevice.signInAnonymouslyIfNeeded()
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

    /// A stored session outlives the user it names whenever the auth table is
    /// rebuilt — `supabase db reset` in development, a restore from backup in
    /// production. Neither touches the keychain, and the token stays signed and
    /// unexpired, so the session passes every local check and the app carries on
    /// as though claimed. Nothing complains until the first profile write dies
    /// on `profiles_auth_user_id_fkey`, naming a constraint rather than a cause.
    ///
    /// The token is left pristine here on purpose: corrupting it is caught by
    /// the SDK's own signature check before a request is ever sent, which is a
    /// different path than the one this guards.
    @Test func aSessionTheServerDisownsIsReplacedBeforeAnythingIsWritten() async throws {
        let storage = EphemeralStorage()
        try await Self.makeBackend(storage: storage).signInAnonymouslyIfNeeded()
        let disowned = try #require(storage.storedSession)
        try await Self.deleteAuthUser(try #require(storage.storedUserID))

        // A second backend over the same storage is what a relaunch looks like.
        let relaunched = try Self.makeBackend(storage: storage)
        try await relaunched.signInAnonymouslyIfNeeded()

        #expect(storage.storedSession != disowned,
                "the disowned session must be replaced, not carried forward")

        // The recovery is only worth anything if the new session can do the
        // write that was failing.
        _ = try await relaunched.createFamily(
            familyName: "Recovered Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let profile = try #require(try await relaunched.currentProfile())
        #expect(profile.role == .parent)
    }

    /// The recovery above must not fire on a device that is merely offline: a
    /// good session discarded because the network blinked cannot be signed in
    /// again until the network returns, which is exactly when it is needed.
    @Test func anUnreachableServerLeavesAGoodSessionAlone() async throws {
        let storage = EphemeralStorage()
        try await Self.makeBackend(storage: storage).signInAnonymouslyIfNeeded()
        let session = try #require(storage.storedSession)

        // Nothing is listening on this port, so every call fails in transport.
        let offline = SupabaseChoresBackend(
            url: URL(string: "http://127.0.0.1:1")!,
            anonKey: ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"] ?? "",
            sessionStorage: storage)
        _ = try? await offline.signInAnonymouslyIfNeeded()

        #expect(storage.storedSession == session,
                "a transport failure must not be read as the server disowning us")
    }
}
