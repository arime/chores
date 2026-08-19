import Testing
import Foundation
@testable import ChoresCore

@MainActor
@Suite struct FamilyStoreTests {

    /// 2026-08-10T12:00:00Z — a Monday, comfortably mid-day in Helsinki.
    static let mondayNoon = Date(timeIntervalSince1970: 1_786_363_200)

    let monday = CalendarDay(year: 2026, month: 8, day: 10)

    struct Fixture {
        let backend: InMemoryChoresBackend
        let store: FamilyStore
        let familyID: UUID
        let childID: UUID
        let choreID: UUID
        let directory: URL
    }

    /// A family with one child assigned "Bins" every Monday.
    func makeFixture(now: Date = FamilyStoreTests.mondayNoon) async throws -> Fixture {
        let directory = try makeTestDirectory()

        let backend = InMemoryChoresBackend()
        try await backend.signInAnonymously()
        let familyID = try await backend.createFamily(
            familyName: "Koti", parentName: "Parent", timezone: "Europe/Helsinki")
        let child = try await backend.addChild(
            familyID: familyID, name: "Kid", color: "#FF8800", sortOrder: 0)
        let chore = try await backend.addChore(familyID: familyID, name: "Bins", icon: nil)
        _ = try await backend.addScheduleEntry(familyID: familyID, profileID: child.id,
                                               choreID: chore.id, weekday: 1)

        let store = FamilyStore(
            backend: backend,
            cache: SnapshotCache(directory: directory),
            outbox: Outbox(directory: directory, backend: backend),
            familyID: familyID,
            clock: { now })

        return Fixture(backend: backend, store: store, familyID: familyID,
                       childID: child.id, choreID: chore.id, directory: directory)
    }

    /// A store over the same directory but with a dead backend — i.e. the same
    /// device, later, with no connectivity.
    func makeOfflineStore(over fixture: Fixture,
                          now: Date = FamilyStoreTests.mondayNoon) -> FamilyStore {
        let dead = UnavailableBackend()
        return FamilyStore(
            backend: dead,
            cache: SnapshotCache(directory: fixture.directory),
            outbox: Outbox(directory: fixture.directory, backend: dead),
            familyID: fixture.familyID,
            clock: { now })
    }

    // MARK: - Reading

    @Test func todayUsesTheFamilyTimezoneNotUTC() async throws {
        // 2026-08-10T21:10Z is already the 11th in Helsinki (+03:00).
        let fixture = try await makeFixture(now: Date(timeIntervalSince1970: 1_786_396_200))
        await fixture.store.start()
        #expect(fixture.store.today == CalendarDay(year: 2026, month: 8, day: 11))
    }

    @Test func startLoadsChoresForTheChild() async throws {
        let fixture = try await makeFixture()
        await fixture.store.start()

        let chores = fixture.store.chores(for: fixture.childID, on: monday)
        #expect(chores.map(\.chore.name) == ["Bins"])
        #expect(chores.first?.isCompleted == false)
        #expect(fixture.store.isStale == false)
    }

    /// Screens draw a spinner for this instead of their empty state, so that
    /// launching does not flash "No children yet" before the family arrives.
    @Test func isLoadingUntilTheFirstLoadSettles() async throws {
        let fixture = try await makeFixture()

        #expect(fixture.store.isLoading)
        await fixture.store.start()
        #expect(fixture.store.isLoading == false)
    }

    @Test func progressReflectsCompletions() async throws {
        let fixture = try await makeFixture()
        await fixture.store.start()
        let chore = fixture.store.chores(for: fixture.childID, on: monday)[0].chore

        #expect(fixture.store.progress(for: fixture.childID, on: monday) == (done: 0, total: 1))
        await fixture.store.setCompleted(true, chore: chore, profileID: fixture.childID,
                                         on: monday, actor: fixture.childID)
        #expect(fixture.store.progress(for: fixture.childID, on: monday) == (done: 1, total: 1))
    }

    // MARK: - Writing

    @Test func completingUpdatesTheUIImmediately() async throws {
        let fixture = try await makeFixture()
        await fixture.store.start()
        let chore = fixture.store.chores(for: fixture.childID, on: monday)[0].chore

        await fixture.store.setCompleted(true, chore: chore, profileID: fixture.childID,
                                         on: monday, actor: fixture.childID)

        #expect(fixture.store.chores(for: fixture.childID, on: monday)[0].isCompleted)
    }

    @Test func completionSurvivesARefresh() async throws {
        // Proves the optimistic update actually reached the server rather than
        // only existing in memory.
        let fixture = try await makeFixture()
        await fixture.store.start()
        let chore = fixture.store.chores(for: fixture.childID, on: monday)[0].chore

        await fixture.store.setCompleted(true, chore: chore, profileID: fixture.childID,
                                         on: monday, actor: fixture.childID)
        await fixture.store.refresh()

        #expect(fixture.store.chores(for: fixture.childID, on: monday)[0].isCompleted)
    }

    @Test func uncompletingRemovesTheCompletion() async throws {
        let fixture = try await makeFixture()
        await fixture.store.start()
        let chore = fixture.store.chores(for: fixture.childID, on: monday)[0].chore

        await fixture.store.setCompleted(true, chore: chore, profileID: fixture.childID,
                                         on: monday, actor: fixture.childID)
        await fixture.store.setCompleted(false, chore: chore, profileID: fixture.childID,
                                         on: monday, actor: fixture.childID)
        await fixture.store.refresh()

        #expect(fixture.store.chores(for: fixture.childID, on: monday)[0].isCompleted == false)
    }

    @Test func completingTwiceDoesNotDuplicate() async throws {
        let fixture = try await makeFixture()
        await fixture.store.start()
        let chore = fixture.store.chores(for: fixture.childID, on: monday)[0].chore

        await fixture.store.setCompleted(true, chore: chore, profileID: fixture.childID,
                                         on: monday, actor: fixture.childID)
        await fixture.store.setCompleted(true, chore: chore, profileID: fixture.childID,
                                         on: monday, actor: fixture.childID)

        #expect(fixture.store.snapshot?.completions.count == 1)
    }

    // MARK: - Offline

    @Test func cachedSnapshotIsShownWhenRefreshFails() async throws {
        let fixture = try await makeFixture()
        await fixture.store.start()   // populates the cache

        let offline = makeOfflineStore(over: fixture)
        await offline.start()

        #expect(offline.snapshot != nil)
        #expect(offline.isStale)
        #expect(offline.chores(for: fixture.childID, on: monday).count == 1)
    }

    /// The warm-launch flash: a relaunch adopts the cached snapshot and draws it
    /// straight away, and until the refresh has actually failed there is nothing
    /// stale to announce. Marking it stale on adoption put the "Showing saved
    /// data" banner on screen for the length of every launch's fetch.
    @Test func aCachedSnapshotIsNotStaleWhileTheFirstRefreshIsStillInFlight() async throws {
        let fixture = try await makeFixture()
        await fixture.store.start()   // populates the cache

        let gated = GatedBackend(inner: fixture.backend)
        let relaunched = FamilyStore(
            backend: gated,
            cache: SnapshotCache(directory: fixture.directory),
            outbox: Outbox(directory: fixture.directory, backend: gated),
            familyID: fixture.familyID,
            clock: { Self.mondayNoon })

        let start = Task { await relaunched.start() }
        var spins = 0
        while !gated.isFetching, spins < 500 {
            await Task.yield()
            spins += 1
        }
        try #require(gated.isFetching, "the store never reached the fetch")

        #expect(relaunched.snapshot != nil, "the cached snapshot should already be on screen")
        #expect(relaunched.isStale == false)
        #expect(relaunched.isLoading == false)

        gated.release()
        await start.value
        #expect(relaunched.isStale == false)
    }

    @Test func togglingWhileOfflineStillUpdatesTheUI() async throws {
        let fixture = try await makeFixture()
        await fixture.store.start()

        let offline = makeOfflineStore(over: fixture)
        await offline.start()
        let chore = offline.chores(for: fixture.childID, on: monday)[0].chore
        await offline.setCompleted(true, chore: chore, profileID: fixture.childID,
                                   on: monday, actor: fixture.childID)

        #expect(offline.chores(for: fixture.childID, on: monday)[0].isCompleted)
    }

    /// The end-to-end offline story: tick with no connection, relaunch, reconnect,
    /// and the tick reaches the server without anyone pressing anything.
    @Test func offlineTickReachesTheServerOnceConnectivityReturns() async throws {
        let fixture = try await makeFixture()
        await fixture.store.start()

        let offline = makeOfflineStore(over: fixture)
        await offline.start()
        let chore = offline.chores(for: fixture.childID, on: monday)[0].chore
        await offline.setCompleted(true, chore: chore, profileID: fixture.childID,
                                   on: monday, actor: fixture.childID)

        // Relaunch against a working backend, same directory.
        let reconnected = FamilyStore(
            backend: fixture.backend,
            cache: SnapshotCache(directory: fixture.directory),
            outbox: Outbox(directory: fixture.directory, backend: fixture.backend),
            familyID: fixture.familyID,
            clock: { Self.mondayNoon })
        await reconnected.start()

        #expect(reconnected.isStale == false)
        #expect(reconnected.chores(for: fixture.childID, on: monday)[0].isCompleted)

        // And it is genuinely on the server, not just in the local snapshot.
        let serverSnapshot = try await fixture.backend.fetchSnapshot(
            familyID: fixture.familyID, weekOf: monday)
        #expect(serverSnapshot.completions.count == 1)
    }

    @Test func aFailedFirstLoadWithNoCacheReportsAnError() async throws {
        let directory = try makeTestDirectory()
        let dead = UnavailableBackend()
        let store = FamilyStore(
            backend: dead,
            cache: SnapshotCache(directory: directory),
            outbox: Outbox(directory: directory, backend: dead),
            familyID: UUID(),
            clock: { Self.mondayNoon })

        await store.start()

        #expect(store.snapshot == nil)
        #expect(store.errorMessage != nil)
        // Not stuck on the spinner: a failed load has still settled.
        #expect(store.isLoading == false)
    }

    /// `SnapshotCache` holds one file for the whole app. After a sign-out hands
    /// the device to a different parent — or after leaving one family and
    /// claiming into another — a store constructed for the new family must
    /// never adopt a cached snapshot left behind by the old one. Proven
    /// offline, where nothing else would ever correct it: online, a
    /// successful refresh happens to paper over the same bug within the same
    /// call to `start()`.
    @Test func startIgnoresACachedSnapshotForADifferentFamilyEvenOffline() async throws {
        let fixture = try await makeFixture()
        await fixture.store.start()   // populates the cache with fixture.familyID

        let otherFamilyID = UUID()
        let now = Self.mondayNoon
        let offlineOtherFamily = FamilyStore(
            backend: UnavailableBackend(),
            cache: SnapshotCache(directory: fixture.directory),
            outbox: Outbox(directory: fixture.directory, backend: UnavailableBackend()),
            familyID: otherFamilyID,
            clock: { now })
        await offlineOtherFamily.start()

        #expect(offlineOtherFamily.snapshot == nil,
                "family A's cached snapshot must not be adopted for family B's store")
        #expect(offlineOtherFamily.errorMessage != nil)
    }

    @Test func recoveringFromStaleClearsTheFlag() async throws {
        let fixture = try await makeFixture()
        await fixture.store.start()

        let offline = makeOfflineStore(over: fixture)
        await offline.start()
        #expect(offline.isStale)

        // Same cache directory, working backend again.
        let online = FamilyStore(
            backend: fixture.backend,
            cache: SnapshotCache(directory: fixture.directory),
            outbox: Outbox(directory: fixture.directory, backend: fixture.backend),
            familyID: fixture.familyID,
            clock: { Self.mondayNoon })
        await online.start()

        #expect(online.isStale == false)
        #expect(online.errorMessage == nil)
    }

    // MARK: - Eligibility passthrough

    @Test func eligibilityIsEvaluatedAgainstTheFamilyTimezone() async throws {
        let fixture = try await makeFixture()
        await fixture.store.start()

        #expect(fixture.store.eligibility(for: monday) == .allowed)
        #expect(fixture.store.eligibility(for: monday.adding(days: 1)) == .future)
        #expect(fixture.store.eligibility(for: monday.adding(days: -1)) == .outsideCurrentWeek)
    }
}
