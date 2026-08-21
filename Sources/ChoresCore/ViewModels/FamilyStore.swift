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
    /// Set once the first load has settled, whether it found data or not.
    public private(set) var hasLoaded: Bool = false
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

    /// True only while there is genuinely nothing to draw yet. Screens show a
    /// spinner for this rather than their empty state, which would otherwise
    /// flash "no children yet" at every launch before the snapshot lands. A
    /// cached snapshot is drawn immediately, so this stays false in that case.
    public var isLoading: Bool { !hasLoaded && snapshot == nil }

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
            // Deliberately not marked stale yet. Whether this snapshot is the
            // best available is unknown until the refresh below answers, and
            // guessing "stale" in the meantime flashes the banner on every
            // launch that then succeeds. The catch in `refresh` raises it.
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
            // Not `fresh` itself. The flush above sends what it can, but writes
            // can outlive it either way: one still in flight when a pull-to-refresh
            // lands, or one queued behind a server that takes reads and refuses
            // writes. Both would otherwise come back as a tick undoing itself
            // under the hand that made it.
            let merged = fresh.applying(await outbox.pending, at: clock())
            snapshot = merged
            isStale = false
            errorMessage = nil
            await cache.save(merged)
        } catch {
            isStale = snapshot != nil
            errorMessage = snapshot == nil ? Self.message(for: error) : nil
        }
        hasLoaded = true
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

        let operation: OutboxOperation = completed
            ? .complete(familyID: familyID, profileID: profileID, choreID: chore.id,
                        dueOn: day, completedBy: actorProfileID)
            : .uncomplete(profileID: profileID, choreID: chore.id, dueOn: day)

        // Applied through the same rule the refresh path uses, so the view a tap
        // produces and the view a refresh produces cannot drift apart — and so
        // that replacing a row for the same (child, chore, date) is defined once.
        snapshot = snapshot?.applying([operation], at: clock())
        await outbox.enqueue(operation)

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
