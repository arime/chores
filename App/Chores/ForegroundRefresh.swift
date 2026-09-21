import SwiftUI
import ChoresCore

extension View {
    /// Brings a week screen up to date when the app comes back to the front.
    ///
    /// Two things go stale while the app is in the background, and they fail
    /// separately. The snapshot ages — a tick from the other device, a schedule
    /// edit — which `FamilyStore.refreshIfNeeded` handles, with a window so that
    /// a glance at Control Centre does not fetch. And the selected day, seeded
    /// once at launch, is still yesterday the morning after: the store's `today`
    /// moved on but nothing in it is observable, so the strip kept drawing last
    /// week. Snapping the selection is a state write, so it redraws the strip
    /// even when the refresh cannot reach the server.
    func refreshingOnForeground(store: FamilyStore, selectedDay: Binding<CalendarDay>) -> some View {
        modifier(ForegroundRefresh(store: store, selectedDay: selectedDay))
    }
}

private struct ForegroundRefresh: ViewModifier {
    let store: FamilyStore
    @Binding var selectedDay: CalendarDay

    @Environment(\.scenePhase) private var scenePhase
    /// The day the screen last knew about, seeded with the day it was built on
    /// — the same day its selection was. Only a change in it moves the
    /// selection: a parent who picked Wednesday and comes back ten minutes
    /// later is still on Wednesday.
    @State private var lastKnownDay: CalendarDay

    /// A banner or the app switcher passes through `.inactive` and back within
    /// seconds; a real return is longer than this.
    private static let staleAfter: TimeInterval = 60

    init(store: FamilyStore, selectedDay: Binding<CalendarDay>) {
        self.store = store
        _selectedDay = selectedDay
        _lastKnownDay = State(initialValue: store.today)
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                let today = store.today
                if lastKnownDay != today {
                    selectedDay = today
                    lastKnownDay = today
                }
                Task { await store.refreshIfNeeded(staleAfter: Self.staleAfter) }
            }
    }
}
