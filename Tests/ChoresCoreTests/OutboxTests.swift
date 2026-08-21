import Testing
import Foundation
@testable import ChoresCore

@Suite struct OutboxTests {

    let familyID = UUID()
    let profileID = UUID()
    let choreID = UUID()
    let day = CalendarDay(year: 2026, month: 8, day: 10)

    var completeOperation: OutboxOperation {
        .complete(familyID: familyID, profileID: profileID, choreID: choreID,
                  dueOn: day, completedBy: profileID)
    }

    var uncompleteOperation: OutboxOperation {
        .uncomplete(profileID: profileID, choreID: choreID, dueOn: day)
    }

    @Test func flushSendsQueuedOperationsAndEmptiesTheQueue() async throws {
        let backend = FlakyBackend()
        let outbox = Outbox(directory: try makeTestDirectory(), backend: backend)
        await outbox.enqueue(completeOperation)

        let sent = await outbox.flush()

        #expect(sent == 1)
        #expect(backend.completeCallCount == 1)
        #expect(await outbox.pendingCount == 0)
    }

    @Test func failedFlushKeepsOperationsQueued() async throws {
        let backend = FlakyBackend()
        backend.shouldFail = true
        let outbox = Outbox(directory: try makeTestDirectory(), backend: backend)
        await outbox.enqueue(completeOperation)

        let sent = await outbox.flush()

        #expect(sent == 0)
        #expect(await outbox.pendingCount == 1)
    }

    /// The whole point of the outbox: a tap made offline must still reach the
    /// server after the app has been killed and relaunched.
    @Test func operationsSurviveAcrossInstances() async throws {
        let directory = try makeTestDirectory()
        let offlineBackend = FlakyBackend()
        offlineBackend.shouldFail = true
        let first = Outbox(directory: directory, backend: offlineBackend)
        await first.enqueue(completeOperation)
        _ = await first.flush()

        let onlineBackend = FlakyBackend()
        let second = Outbox(directory: directory, backend: onlineBackend)
        #expect(await second.pendingCount == 1)

        let sent = await second.flush()
        #expect(sent == 1)
        #expect(onlineBackend.completeCallCount == 1)
    }

    @Test func replayingTheSameCompletionTwiceIsHarmless() async throws {
        let backend = FlakyBackend()
        let outbox = Outbox(directory: try makeTestDirectory(), backend: backend)
        await outbox.enqueue(completeOperation)
        _ = await outbox.flush()
        await outbox.enqueue(completeOperation)
        _ = await outbox.flush()

        // The database's (profile, chore, date) uniqueness makes the second write a
        // no-op, which is exactly why the outbox can replay without bookkeeping.
        #expect(backend.completeCallCount == 2)
        #expect(await outbox.pendingCount == 0)
    }

    @Test func opposingOperationsOnTheSameKeyCancelOut() async throws {
        let backend = FlakyBackend()
        backend.shouldFail = true
        let outbox = Outbox(directory: try makeTestDirectory(), backend: backend)

        await outbox.enqueue(completeOperation)
        await outbox.enqueue(uncompleteOperation)

        // The server never saw the complete, so neither operation needs sending.
        #expect(await outbox.pendingCount == 0)
    }

    @Test func cancellingOutSurvivesAReload() async throws {
        let directory = try makeTestDirectory()
        let backend = FlakyBackend()
        backend.shouldFail = true
        let outbox = Outbox(directory: directory, backend: backend)
        await outbox.enqueue(completeOperation)
        await outbox.enqueue(uncompleteOperation)

        // The collapse must have been persisted, not just applied in memory.
        #expect(await Outbox(directory: directory, backend: backend).pendingCount == 0)
    }

    @Test func operationsOnDifferentKeysDoNotCancel() async throws {
        let backend = FlakyBackend()
        backend.shouldFail = true
        let outbox = Outbox(directory: try makeTestDirectory(), backend: backend)

        await outbox.enqueue(completeOperation)
        await outbox.enqueue(.uncomplete(profileID: profileID, choreID: UUID(), dueOn: day))

        #expect(await outbox.pendingCount == 2)
    }

    @Test func operationsOnDifferentDaysDoNotCancel() async throws {
        let backend = FlakyBackend()
        backend.shouldFail = true
        let outbox = Outbox(directory: try makeTestDirectory(), backend: backend)

        await outbox.enqueue(completeOperation)
        await outbox.enqueue(.uncomplete(profileID: profileID, choreID: choreID,
                                         dueOn: day.adding(days: -1)))

        #expect(await outbox.pendingCount == 2)
    }

    @Test func flushStopsAtTheFirstFailureToPreserveOrder() async throws {
        let backend = FlakyBackend()
        let outbox = Outbox(directory: try makeTestDirectory(), backend: backend)
        await outbox.enqueue(completeOperation)
        await outbox.enqueue(.complete(familyID: familyID, profileID: profileID,
                                       choreID: UUID(), dueOn: day, completedBy: profileID))
        backend.shouldFail = true

        let sent = await outbox.flush()

        #expect(sent == 0)
        #expect(await outbox.pendingCount == 2)
    }

    @Test func flushOnAnEmptyQueueSendsNothing() async throws {
        let backend = FlakyBackend()
        let outbox = Outbox(directory: try makeTestDirectory(), backend: backend)
        #expect(await outbox.flush() == 0)
        #expect(backend.completeCallCount == 0)
    }

    @Test func aPartialFlushKeepsTheRemainderInOrder() async throws {
        let directory = try makeTestDirectory()
        let backend = FlakyBackend()
        let outbox = Outbox(directory: directory, backend: backend)

        let firstChore = UUID()
        let secondChore = UUID()
        await outbox.enqueue(.complete(familyID: familyID, profileID: profileID,
                                       choreID: firstChore, dueOn: day, completedBy: profileID))
        _ = await outbox.flush()   // sends the first

        backend.shouldFail = true
        await outbox.enqueue(.complete(familyID: familyID, profileID: profileID,
                                       choreID: secondChore, dueOn: day, completedBy: profileID))
        _ = await outbox.flush()   // cannot send the second

        #expect(backend.completeCallCount == 1)
        #expect(await outbox.pendingCount == 1)

        backend.shouldFail = false
        #expect(await outbox.flush() == 1)
        #expect(backend.completeCallCount == 2)
    }

    @Test func uncompleteIsSentAsADelete() async throws {
        let backend = FlakyBackend()
        let outbox = Outbox(directory: try makeTestDirectory(), backend: backend)
        await outbox.enqueue(uncompleteOperation)

        _ = await outbox.flush()

        #expect(backend.uncompleteCallCount == 1)
        #expect(backend.completeCallCount == 0)
    }

    /// The session-ending path: sign-out, leaving a family, or deleting the
    /// account must not leave a write meant for the old family queued up to
    /// fire into whatever family the device joins next.
    @Test func clearEmptiesTheQueueAndPersistsIt() async throws {
        let directory = try makeTestDirectory()
        let backend = FlakyBackend()
        backend.shouldFail = true
        let outbox = Outbox(directory: directory, backend: backend)
        await outbox.enqueue(completeOperation)

        await outbox.clear()

        #expect(await outbox.pendingCount == 0)
        // The empty queue must be the one a relaunch finds too.
        #expect(await Outbox(directory: directory, backend: backend).pendingCount == 0)
    }

    @Test func clearOnAnEmptyQueueIsHarmless() async throws {
        let outbox = Outbox(directory: try makeTestDirectory(), backend: FlakyBackend())
        await outbox.clear()
        #expect(await outbox.pendingCount == 0)
    }

    /// Deleting a child must not leave a tick queued in their name — the
    /// server would refuse it forever, since the profile it names is gone.
    @Test func dropRemovesOnlyTheNamedProfilesOperationsAndPersists() async throws {
        let directory = try makeTestDirectory()
        let backend = FlakyBackend()
        backend.shouldFail = true
        let outbox = Outbox(directory: directory, backend: backend)
        let otherProfileID = UUID()
        await outbox.enqueue(completeOperation)
        await outbox.enqueue(.complete(familyID: familyID, profileID: otherProfileID,
                                       choreID: choreID, dueOn: day, completedBy: otherProfileID))

        await outbox.drop(profileID: profileID)

        #expect(await outbox.pendingCount == 1)
        #expect(await Outbox(directory: directory, backend: backend).pendingCount == 1)
    }

    /// Three ticks in a row each kick off their own flush, and the network call
    /// in the middle of one is a suspension point the others can walk straight
    /// through. Two flushes draining the same queue is what took the app down: one
    /// of them eventually asks an already-emptied queue for its first element.
    @Test func overlappingFlushesDrainTheQueueOnce() async throws {
        let backend = OverlappingWriteBackend()
        let outbox = Outbox(directory: try makeTestDirectory(), backend: backend)
        for _ in 0..<3 {
            await outbox.enqueue(.complete(familyID: familyID, profileID: profileID,
                                           choreID: UUID(), dueOn: day, completedBy: profileID))
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask { _ = await outbox.flush() }
            }
        }

        #expect(await backend.tally.peak == 1)
        #expect(await backend.tally.calls == 3)
        #expect(await outbox.pendingCount == 0)
    }

    /// A tick undone while the tick itself is still on the wire. The pair may not
    /// collapse here: the server has already been told, or is about to be, so the
    /// undo is the only thing that can put it right. Taking the sent operation off
    /// a queue that shrank underneath is also how the app dies.
    @Test func anUndoArrivingMidSendIsStillDelivered() async throws {
        let backend = ParkedWriteBackend()
        let outbox = Outbox(directory: try makeTestDirectory(), backend: backend)
        await outbox.enqueue(completeOperation)

        async let flushed: Int = outbox.flush()
        await backend.gate.waitForArrivals(1)
        await outbox.enqueue(uncompleteOperation)
        await backend.gate.releaseAll()

        #expect(await flushed == 2)
        #expect(backend.uncompleteCallCount == 1)
        #expect(await outbox.pendingCount == 0)
    }

    @Test func corruptQueueFileIsTreatedAsEmpty() async throws {
        let directory = try makeTestDirectory()
        try Data("not json".utf8)
            .write(to: directory.appendingPathComponent("outbox.json"))
        let outbox = Outbox(directory: directory, backend: FlakyBackend())
        #expect(await outbox.pendingCount == 0)
    }
}
