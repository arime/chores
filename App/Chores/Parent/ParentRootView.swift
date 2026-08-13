import SwiftUI
import ChoresCore

struct ParentRootView: View {
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
            ParentTodayView(store: store, parent: profile)
                .tabItem { Label("Today", systemImage: "checklist") }

            ParentWeekView(store: store, parent: profile)
                .tabItem { Label("Week", systemImage: "calendar") }

            ManageView(store: store, backend: environment.backend)
                .tabItem { Label("Manage", systemImage: "gearshape") }
        }
        .task { await store.start() }
    }
}

struct ManageView: View {
    let store: FamilyStore
    let backend: any ChoresBackend

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    ChildrenView(store: store, backend: backend)
                } label: {
                    Label("Children", systemImage: "person.2")
                }
                NavigationLink {
                    ChoresView(store: store, backend: backend)
                } label: {
                    Label("Chores", systemImage: "list.bullet")
                }
                NavigationLink {
                    ScheduleEditorView(store: store, backend: backend)
                } label: {
                    Label("Schedule", systemImage: "calendar.badge.clock")
                }
            }
            .navigationTitle("Manage")
        }
    }
}
