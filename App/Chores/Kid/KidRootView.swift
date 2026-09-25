import SwiftUI
import ChoresCore

/// The child's whole app: one screen, the current week, with today selected.
/// No settings, no route back to parent functionality.
struct KidRootView: View {
    let environment: AppEnvironment
    let profile: Profile

    @State private var store: FamilyStore
    @State private var selectedDay: CalendarDay

    init(environment: AppEnvironment, profile: Profile) {
        self.environment = environment
        self.profile = profile
        let store = FamilyStore(
            backend: environment.backend,
            cache: environment.snapshotCache,
            outbox: environment.outbox,
            familyID: profile.familyID,
            clock: environment.clock)
        _store = State(initialValue: store)
        _selectedDay = State(initialValue: store.today)
    }

    var body: some View {
        KidDayView(store: store, profile: profile, selectedDay: $selectedDay)
            .background(Theme.bg.ignoresSafeArea())
            // Every Theme colour is a dark-appearance value.
            .preferredColorScheme(.dark)
            .refreshingOnForeground(store: store, selectedDay: $selectedDay)
            .task {
                await store.start()
                // The system permission alert would block UI tests, and they have
                // nothing to say about notifications anyway.
                if !AppEnvironment.isUITesting {
                    await Notifications.requestAuthorization()
                }
            }
            // Rescheduled on every change, not only the template's: a tick,
            // an untick, a schedule edit, or a changed reminder time all move
            // what should be queued. The recompute is a few dozen rows.
            .onChange(of: store.snapshot) { _, snapshot in
                guard let snapshot else { return }
                let plans = ReminderSchedule.plans(for: profile.id, snapshot: snapshot, now: Date())
                Task { await ReminderScheduler.reschedule(plans: plans,
                                                          timeZone: snapshot.family.timeZone) }
            }
    }
}
