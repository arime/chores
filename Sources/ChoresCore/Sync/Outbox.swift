import Foundation

/// A completion write that has not yet reached the server.
public enum OutboxOperation: Codable, Equatable, Sendable {
    case complete(familyID: UUID, profileID: UUID, choreID: UUID,
                  dueOn: CalendarDay, completedBy: UUID)
    case uncomplete(profileID: UUID, choreID: UUID, dueOn: CalendarDay)

    /// Identifies the completion row this operation targets — the same tuple the
    /// database's uniqueness constraint uses.
    struct Key: Hashable, Sendable {
        let profileID: UUID
        let choreID: UUID
        let dueOn: CalendarDay
    }

    var key: Key {
        switch self {
        case let .complete(_, profileID, choreID, dueOn, _):
            return Key(profileID: profileID, choreID: choreID, dueOn: dueOn)
        case let .uncomplete(profileID, choreID, dueOn):
            return Key(profileID: profileID, choreID: choreID, dueOn: dueOn)
        }
    }

    var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }
}

/// A durable, ordered queue of completion writes.
///
/// Replay is safe because the server upserts on (profile_id, chore_id, due_on),
/// so this holds no deduplication bookkeeping — the only cleverness is collapsing
/// a pending pair that cancels itself out.
public actor Outbox {

    private let fileURL: URL
    private let backend: ChoresBackend
    private var queue: [OutboxOperation]
    /// True for as long as a flush is running. Anything that observes it has, by
    /// definition, interleaved with that flush's send, so the operation at the
    /// front of the queue is one already on its way to the server.
    private var isFlushing = false

    public init(directory: URL, backend: ChoresBackend) {
        self.fileURL = directory.appendingPathComponent("outbox.json")
        self.backend = backend
        // A corrupt queue is treated as empty: losing a pending tick is recoverable,
        // crashing on launch is not.
        self.queue = (try? Data(contentsOf: fileURL))
            .flatMap { try? ChoresJSON.decoder.decode([OutboxOperation].self, from: $0) } ?? []
    }

    public var pendingCount: Int { queue.count }

    public func enqueue(_ operation: OutboxOperation) {
        // If an unsent operation targets the same row in the opposite direction, the
        // server never observed either — drop both rather than sending a write and
        // then immediately undoing it.
        //
        // The one at the front of a running flush does not count as unsent: it is
        // on the wire, and the server may already have it. Cancelling that pair
        // would leave a completion standing on the server that the screen no
        // longer shows, and no operation left to correct it.
        let unsent = queue.indices.dropFirst(isFlushing ? 1 : 0)
        if let index = unsent.last(where: { queue[$0].key == operation.key }),
           queue[index].isComplete != operation.isComplete {
            queue.remove(at: index)
        } else {
            queue.append(operation)
        }
        persist()
    }

    /// Sends queued operations in order, stopping at the first failure so ordering
    /// is preserved. Returns how many were sent.
    ///
    /// Actor isolation does not make this safe on its own: the send in the middle
    /// is a suspension point, and a second caller can walk in through it. Two
    /// flushes then drain one queue — each sends the operation the other has
    /// already sent, and each removes whatever happens to be first when it comes
    /// back, until one of them asks an emptied queue for its first element and the
    /// app dies. Which is what ticking off three chores in a row did: three taps,
    /// three flushes, one crash.
    ///
    /// So only one flush runs at a time. A caller who finds one already running
    /// can simply leave: it has enqueued its operation before asking, and the
    /// running flush keeps taking from the front until the queue is empty, so it
    /// will carry that operation too.
    @discardableResult
    public func flush() async -> Int {
        guard !isFlushing else { return 0 }
        isFlushing = true
        defer { isFlushing = false }

        var sent = 0
        while let operation = queue.first {
            do {
                switch operation {
                case let .complete(familyID, profileID, choreID, dueOn, completedBy):
                    try await backend.complete(familyID: familyID, profileID: profileID,
                                               choreID: choreID, dueOn: dueOn,
                                               completedBy: completedBy)
                case let .uncomplete(profileID, choreID, dueOn):
                    try await backend.uncomplete(profileID: profileID, choreID: choreID,
                                                 dueOn: dueOn)
                }
                // Not `removeFirst`: the send suspended, and the queue can have
                // moved on meanwhile — a sign-out cleared it, a deleted child's
                // operations were dropped. Take out the operation that actually
                // went, if it is still there, and let the loop re-read the front.
                if let index = queue.firstIndex(of: operation) {
                    queue.remove(at: index)
                    persist()
                }
                sent += 1
            } catch {
                break
            }
        }
        return sent
    }

    /// Drops everything queued. Called when a session ends — sign-out, leaving
    /// a family, or deleting the account — so a write meant for the family just
    /// left cannot land in whichever family the device signs into next.
    public func clear() {
        queue = []
        persist()
    }

    /// Drops only the operations naming one profile. Called after deleting a
    /// child, so a tick queued for them before deletion cannot wedge every
    /// completion queued after it — the server would refuse it forever, since
    /// the profile it names is now gone.
    public func drop(profileID: UUID) {
        queue.removeAll { $0.key.profileID == profileID }
        persist()
    }

    private func persist() {
        guard let data = try? ChoresJSON.encoder.encode(queue) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
