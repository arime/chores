import SwiftUI
import ChoresCore

/// The child's whole app: today, and this week. No settings, no route back to
/// parent functionality.
struct KidRootView: View {
    let environment: AppEnvironment
    let profile: Profile

    @State private var store: FamilyStore

    init(environment: AppEnvironment, profile: Profile) {
        self.environment = environment
        self.profile = profile
        _store = State(initialValue: FamilyStore(
            backend: environment.backend,
            cache: environment.snapshotCache,
            outbox: environment.outbox,
            familyID: profile.familyID))
    }

    var body: some View {
        TabView {
            KidTodayView(store: store, profile: profile)
                .tabItem { Label("Today", systemImage: "checklist") }

            KidWeekView(store: store, profile: profile)
                .tabItem { Label("Week", systemImage: "calendar") }
        }
        .task {
            await store.start()
            // The system permission alert would block UI tests, and they have
            // nothing to say about notifications anyway.
            if !AppEnvironment.isUITesting {
                await ReminderScheduler.requestAuthorization()
            }
        }
        // Rescheduled whenever the template changes, which is exactly when the set
        // of chore-bearing days can change.
        .onChange(of: store.snapshot?.template) { _, _ in
            guard let snapshot = store.snapshot else { return }
            let plans = ReminderSchedule.plans(for: profile.id, snapshot: snapshot)
            Task { await ReminderScheduler.reschedule(plans: plans,
                                                      timeZone: snapshot.family.timeZone) }
        }
    }
}
