import Testing
import Foundation
@testable import ChoresCore

@Suite struct SnapshotCacheTests {

    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Timestamps are whole seconds so they survive the ISO-8601 round trip exactly,
    /// which lets the round-trip test assert whole-struct equality. See
    /// `timestampsRoundTripToMillisecondPrecision` for the general case.
    func makeSnapshot(familyName: String = "Koti") -> FamilySnapshot {
        let fixedDate = Date(timeIntervalSince1970: 1_786_000_000)
        let familyID = UUID()
        let childID = UUID()
        let choreID = UUID()
        return FamilySnapshot(
            family: Family(id: familyID, name: familyName, createdAt: fixedDate),
            profiles: [Profile(id: childID, familyID: familyID,
                               displayName: "Kid", role: .child, createdAt: fixedDate)],
            chores: [Chore(id: choreID, familyID: familyID, name: "Bins",
                           createdAt: fixedDate)],
            template: [ScheduleEntry(id: UUID(), familyID: familyID, profileID: childID,
                                     choreID: choreID, weekday: 1)],
            completions: [Completion(id: UUID(), familyID: familyID, profileID: childID,
                                     choreID: choreID,
                                     dueOn: CalendarDay(year: 2026, month: 8, day: 10),
                                     completedAt: fixedDate,
                                     completedBy: childID)],
            fetchedAt: fixedDate)
    }

    @Test func loadReturnsNilWhenNothingHasBeenSaved() async throws {
        let cache = SnapshotCache(directory: try makeTemporaryDirectory())
        #expect(await cache.load() == nil)
    }

    @Test func savedSnapshotRoundTripsCompletely() async throws {
        let cache = SnapshotCache(directory: try makeTemporaryDirectory())
        let snapshot = makeSnapshot()
        await cache.save(snapshot)

        let loaded = await cache.load()
        #expect(loaded == snapshot)
        // Spot-check the pieces the UI depends on most.
        #expect(loaded?.family.name == "Koti")
        #expect(loaded?.chores.first?.name == "Bins")
        #expect(loaded?.template.first?.weekday == 1)
        #expect(loaded?.completions.first?.dueOn == CalendarDay(year: 2026, month: 8, day: 10))
        #expect(loaded?.fetchedAt == snapshot.fetchedAt)
    }

    @Test func savingOverwritesThePreviousSnapshot() async throws {
        let cache = SnapshotCache(directory: try makeTemporaryDirectory())
        await cache.save(makeSnapshot(familyName: "First"))
        await cache.save(makeSnapshot(familyName: "Second"))
        #expect(await cache.load()?.family.name == "Second")
    }

    @Test func clearRemovesTheSnapshot() async throws {
        let cache = SnapshotCache(directory: try makeTemporaryDirectory())
        await cache.save(makeSnapshot())
        await cache.clear()
        #expect(await cache.load() == nil)
    }

    @Test func clearOnAnEmptyCacheIsHarmless() async throws {
        let cache = SnapshotCache(directory: try makeTemporaryDirectory())
        await cache.clear()
        #expect(await cache.load() == nil)
    }

    /// A corrupt cache must degrade to "no cache" rather than crash — the app can
    /// always refetch, but it cannot recover from a trap on launch.
    @Test func corruptFileIsTreatedAsAbsent() async throws {
        let directory = try makeTemporaryDirectory()
        let cache = SnapshotCache(directory: directory)
        try Data("not json".utf8)
            .write(to: directory.appendingPathComponent("snapshot.json"))
        #expect(await cache.load() == nil)
    }

    /// Documents a real limit of the JSON representation: timestamps survive to
    /// millisecond precision, not to `Date`'s full resolution. Nothing in the app
    /// compares snapshots or relies on sub-millisecond times, so this is recorded
    /// rather than fixed — but it should be a deliberate choice, not a surprise.
    @Test func timestampsRoundTripToMillisecondPrecision() async throws {
        let cache = SnapshotCache(directory: try makeTemporaryDirectory())
        let preciseDate = Date(timeIntervalSince1970: 1_786_000_000.123456789)
        var snapshot = makeSnapshot()
        snapshot.fetchedAt = preciseDate
        await cache.save(snapshot)

        let loaded = try #require(await cache.load())
        let drift = abs(loaded.fetchedAt.timeIntervalSince(preciseDate))
        #expect(drift < 0.001)
        #expect(loaded.fetchedAt != preciseDate)
    }

    @Test func aSeparateInstanceOverTheSameDirectorySeesTheSavedSnapshot() async throws {
        // This is the relaunch case: a new process must find what the last one wrote.
        let directory = try makeTemporaryDirectory()
        await SnapshotCache(directory: directory).save(makeSnapshot(familyName: "Persisted"))
        #expect(await SnapshotCache(directory: directory).load()?.family.name == "Persisted")
    }
}
