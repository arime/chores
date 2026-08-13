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

            ManageView(store: store, backend: environment.backend, parent: profile)
                .tabItem { Label("Manage", systemImage: "gearshape") }
        }
        .task { await store.start() }
    }
}

struct ManageView: View {
    let store: FamilyStore
    let backend: any ChoresBackend
    let parent: Profile

    @State private var isShowingOwnCode = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        PeopleView(store: store, backend: backend, me: parent)
                    } label: {
                        Label("People", systemImage: "person.2")
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

                Section {
                    Button {
                        isShowingOwnCode = true
                    } label: {
                        Label("Get a code for this device", systemImage: "iphone.and.arrow.forward")
                    }
                    .accessibilityIdentifier("manage.ownCode")
                } footer: {
                    Text("""
                        A code is how you move parent access to another device, or get back \
                        in if this one is wiped or replaced. Make one when you need it — they \
                        last 7 days.
                        """)
                }
            }
            .navigationTitle("Manage")
            .sheet(isPresented: $isShowingOwnCode) {
                ClaimCodeSheet(profile: parent, backend: backend, isOwnProfile: true)
            }
        }
    }
}
