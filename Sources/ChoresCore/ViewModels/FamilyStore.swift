import Foundation
import Observation

/// The app's single read model, shared by every screen in both modes.
///
/// Offline behaviour lives here — cache, outbox, optimistic writes — so that no
/// view has to know whether the device is online.
@MainActor
@Observable
public final class FamilyStore {

    private let backend: ChoresBackend
    private let cache: SnapshotCache
    private let outbox: Outbox
    private let familyID: UUID
    private let clock: @Sendable () -> Date

    public private(set) var snapshot: FamilySnapshot?
    /// True when what's on screen came from cache after a failed refresh.
    public private(set) var isStale: Bool = false
    /// Set only when there is nothing to show at all; a stale snapshot is shown
    /// with a banner instead of an error.
    public private(set) var errorMessage: String?

    public init(backend: ChoresBackend,
                cache: SnapshotCache,
                outbox: Outbox,
                familyID: UUID,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.backend = backend
        self.cache = cache
        self.outbox = outbox
        self.familyID = familyID
        self.clock = clock
    }

    public var timeZone: TimeZone { snapshot?.family.timeZone ?? .current }

    /// The current day in the family's timezone — never a UTC day.
    public var today: CalendarDay { CalendarDay(clock(), in: timeZone) }

    // MARK: Loading

    public func start() async {
        // A cached snapshot only belongs here if it names this store's own
        // family. The cache is a single file shared by the whole app, so after
        // a sign-out hands the device to a different parent — or after leaving
        // one family and claiming into another — a stale snapshot for the
        // previous family must never be adopted, online or off.
        if let cached = await cache.load(), cached.family.id == familyID {
            snapshot = cached
            isStale = true          // provisional; the refresh below clears it
        }
        await refresh()
    }

    /// Drops any operations queued for a profile that no longer exists. Called
    /// after deleting a child, so a tick queued for them cannot wedge every
    /// completion queued after it.
    public func dropQueuedOperations(for profileID: UUID) async {
        await outbox.drop(profileID: profileID)
    }

    public func refresh() async {
        // Send anything queued before reading, so the state we fetch already
        // includes this device's offline work.
        await outbox.flush()
        do {
            let fresh = try await backend.fetchSnapshot(familyID: familyID, weekOf: today)
            snapshot = fresh
            isStale = false
            errorMessage = nil
            await cache.save(fresh)
        } catch {
            isStale = snapshot != nil
            errorMessage = snapshot == nil ? Self.message(for: error) : nil
        }
    }

    /// Called after a parent edits children, chores, or the schedule.
    public func reloadAfterEdit() async {
        await refresh()
    }

    // MARK: Reads

    public func chores(for profileID: UUID, on day: CalendarDay) -> [ChoreForDay] {
        guard let snapshot else { return [] }
        return ScheduleResolver.chores(
            for: profileID, on: day, template: snapshot.template,
            chores: snapshot.chores, completions: snapshot.completions)
    }

    public func progress(for profileID: UUID, on day: CalendarDay) -> (done: Int, total: Int) {
        guard let snapshot else { return (0, 0) }
        return ScheduleResolver.progress(
            for: profileID, on: day, template: snapshot.template,
            chores: snapshot.chores, completions: snapshot.completions)
    }

    public func eligibility(for day: CalendarDay) -> CompletionEligibility {
        ScheduleResolver.eligibility(for: day, today: today)
    }

    // MARK: Writes

    /// Applies the change locally first, then queues it. The outbox flushes
    /// immediately when online and survives a relaunch when not, so a tap always
    /// sticks from the child's point of view.
    public func setCompleted(_ completed: Bool, chore: Chore, profileID: UUID,
                             on day: CalendarDay, actor actorProfileID: UUID) async {
        guard snapshot != nil else { return }

        // Remove any existing row for this key either way, so completing twice
        // cannot duplicate.
        snapshot?.completions.removeAll {
            $0.profileID == profileID && $0.choreID == chore.id && $0.dueOn == day
        }

        if completed {
            snapshot?.completions.append(Completion(
                id: UUID(), familyID: familyID, profileID: profileID, choreID: chore.id,
                dueOn: day, completedAt: clock(), completedBy: actorProfileID))
            await outbox.enqueue(.complete(
                familyID: familyID, profileID: profileID, choreID: chore.id,
                dueOn: day, completedBy: actorProfileID))
        } else {
            await outbox.enqueue(.uncomplete(
                profileID: profileID, choreID: chore.id, dueOn: day))
        }

        if let snapshot { await cache.save(snapshot) }
        await outbox.flush()
    }

    private static func message(for error: Error) -> String {
        switch error as? ChoresBackendError {
        case .projectUnavailable:
            return "Can't reach the server."
        case .underlying(let detail):
            return detail
        case .some(let known):
            return String(describing: known)
        case nil:
            return error.localizedDescription
        }
    }
}
