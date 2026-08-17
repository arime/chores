import SwiftUI
import ChoresCore

struct ParentRootView: View {
    let environment: AppEnvironment
    let profile: Profile
    let onSessionChanged: () async -> Void

    @State private var store: FamilyStore

    init(environment: AppEnvironment, profile: Profile, onSessionChanged: @escaping () async -> Void) {
        self.environment = environment
        self.profile = profile
        self.onSessionChanged = onSessionChanged
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

            ManageView(store: store, environment: environment, parent: profile,
                       onSessionChanged: onSessionChanged)
                .tabItem { Label("Manage", systemImage: "gearshape") }
        }
        .task { await store.start() }
    }
}

struct ManageView: View {
    let store: FamilyStore
    let environment: AppEnvironment
    let parent: Profile
    let onSessionChanged: () async -> Void

    @State private var isShowingOwnCode = false
    @State private var isConfirmingLeave = false
    @State private var isConfirmingDelete = false
    @State private var errorMessage: String?

    private var isLastParent: Bool { (store.snapshot?.parents.count ?? 1) <= 1 }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        PeopleView(store: store, backend: environment.backend, me: parent)
                    } label: {
                        Label("People", systemImage: "person.2")
                    }
                    NavigationLink {
                        ChoresView(store: store, backend: environment.backend)
                    } label: {
                        Label("Chores", systemImage: "list.bullet")
                    }
                    NavigationLink {
                        ScheduleEditorView(store: store, backend: environment.backend)
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

                Section {
                    Button("Sign out") {
                        Task { await perform { try await environment.backend.signOut() } }
                    }
                    .accessibilityIdentifier("manage.signOut")

                    Button("Leave this family", role: .destructive) {
                        isConfirmingLeave = true
                    }
                    .accessibilityIdentifier("manage.leave")

                    Button("Delete account", role: .destructive) {
                        isConfirmingDelete = true
                    }
                    .accessibilityIdentifier("manage.deleteAccount")
                } footer: {
                    Text(isLastParent
                         ? "You're the only parent, so leaving or deleting your account removes the whole family."
                         : "Signing out keeps your place. Leaving gives it up.")
                }
            }
            .navigationTitle("Manage")
            .sheet(isPresented: $isShowingOwnCode) {
                ClaimCodeSheet(profile: parent, backend: environment.backend, isOwnProfile: true)
            }
            .confirmationDialog("Leave this family?",
                                isPresented: $isConfirmingLeave, titleVisibility: .visible) {
                Button("Leave", role: .destructive) {
                    Task { await perform { try await environment.backend.leaveFamily() } }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(isLastParent
                     ? "You're the only parent, so this deletes the family, the children, the chores and all their history. This cannot be undone."
                     : "You'll be removed from this family. The other parent can give you a new code if you want back in.")
            }
            .confirmationDialog("Delete your account?",
                                isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete account", role: .destructive) {
                    Task { await perform { try await environment.backend.deleteAccount() } }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(isLastParent
                     ? "You're the only parent, so this deletes your Apple sign-in for Chores along with the family, the children, the chores and all their history. This cannot be undone."
                     : "This deletes your Apple sign-in for Chores and removes you from the family. This cannot be undone.")
            }
            .alert("Something went wrong", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    /// Every one of these ends the session, so the root has to re-read it —
    /// staying on a Manage screen for a family you just left would be a ghost.
    ///
    /// The cache and outbox are cleared here too, not just on the root's next
    /// read: `SnapshotCache` holds one snapshot for the whole app, and without
    /// this, a different parent signing in on this device — or this parent
    /// claiming into a different family — would see this family's data until
    /// the next successful fetch replaces it, or forever if offline. Queued
    /// writes for a family the device is leaving must not fire into whatever
    /// family it joins next either.
    private func perform(_ action: @escaping () async throws -> Void) async {
        do {
            try await action()
            await environment.snapshotCache.clear()
            await environment.outbox.clear()
            await onSessionChanged()
        } catch {
            errorMessage = "Couldn't do that. Check your connection and try again."
        }
    }
}
