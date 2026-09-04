import SwiftUI
import ChoresCore

enum KidTab {
    case today
    case week
}

/// The child's whole app: today, and this week. No settings, no route back to
/// parent functionality.
///
/// Tab and selected day live here rather than in the tabs so that Today's week
/// strip can jump into Week with a day already picked.
struct KidRootView: View {
    let environment: AppEnvironment
    let profile: Profile

    @State private var store: FamilyStore
    @State private var tab: KidTab = .today
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

    private var hue: ChildHue { ChildHue(hex: profile.color) }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case .today:
                    KidTodayView(store: store, profile: profile,
                                 tab: $tab, selectedDay: $selectedDay)
                case .week:
                    KidWeekView(store: store, profile: profile, selectedDay: $selectedDay)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            KidTabBar(tab: tab, hue: hue) { picked in
                tab = picked
                // Opening Week from its tab always lands on today; only Today's
                // strip preselects another day.
                if picked == .week { selectedDay = store.today }
            }
        }
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

/// Two cells, icon over label, a fading rule along the top. Replaces the system
/// tab bar so the active colour can be the child's own.
struct KidTabBar: View {
    let tab: KidTab
    let hue: ChildHue
    let onSelect: (KidTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            cell(.today, systemImage: "checklist", title: Text("Today"), identifier: "kidTab.today")
            cell(.week, systemImage: "calendar", title: Text("Week"), identifier: "kidTab.week")
        }
        .padding(.top, 8)
        .padding(.bottom, 30)
        .padding(.horizontal, 24)
        .overlay(alignment: .top) { FadingRule(ramp: 48) }
        .background(Theme.bg)
        // The 30pt below the cells is the space above the home indicator; the
        // bar owns it rather than stacking on top of the safe area.
        .ignoresSafeArea(.container, edges: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
    }

    private func cell(_ target: KidTab, systemImage: String, title: Text,
                      identifier: String) -> some View {
        let isActive = tab == target
        return Button {
            onSelect(target)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 24))
                    .frame(height: 24)
                title
                    .font(.system(size: 11))
                    .tracking(11 * 0.02)
            }
            .foregroundStyle(isActive ? hue.base : Theme.neutral500)
            .animation(.easeInOut(duration: 0.2), value: isActive)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
