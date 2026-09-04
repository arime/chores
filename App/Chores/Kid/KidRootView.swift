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
            familyID: profile.familyID)
        _store = State(initialValue: store)
        _selectedDay = State(initialValue: store.today)
    }

    var body: some View {
        KidDayView(store: store, profile: profile, selectedDay: $selectedDay)
            .background(Theme.bg.ignoresSafeArea())
            // Every Theme colour is a dark-appearance value.
            .preferredColorScheme(.dark)
            .task {
                await store.start()
                // The system permission alert would block UI tests, and they have
                // nothing to say about notifications anyway.
                if !AppEnvironment.isUITesting {
                    await ReminderScheduler.requestAuthorization()
                }
            }
            // Rescheduled whenever the template changes, which is exactly when the
            // set of chore-bearing days can change.
            .onChange(of: store.snapshot?.template) { _, _ in
                guard let snapshot = store.snapshot else { return }
                let plans = ReminderSchedule.plans(for: profile.id, snapshot: snapshot)
                Task { await ReminderScheduler.reschedule(plans: plans,
                                                          timeZone: snapshot.family.timeZone) }
            }
    }
}
