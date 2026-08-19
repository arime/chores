import SwiftUI
import ChoresCore

struct ParentRootView: View {
    let environment: AppEnvironment
    let profile: Profile
    /// How this parent got here — signed in with Apple, or a code on an
    /// anonymous device. Manage is the only screen that cares.
    let identity: DeviceIdentity
    let onSessionChanged: () async -> Void

    @State private var store: FamilyStore

    init(environment: AppEnvironment, profile: Profile, identity: DeviceIdentity,
         onSessionChanged: @escaping () async -> Void) {
        self.environment = environment
        self.profile = profile
        self.identity = identity
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
                       identity: identity, onSessionChanged: onSessionChanged)
                .tabItem { Label("Manage", systemImage: "gearshape") }
        }
        .task { await store.start() }
    }
}

struct ManageView: View {
    let store: FamilyStore
    let environment: AppEnvironment
    let parent: Profile
    let identity: DeviceIdentity
    let onSessionChanged: () async -> Void

    @State private var isConfirmingLeave = false
    @State private var isConfirmingDelete = false
    @State private var errorMessage: String?

    private var isLastParent: Bool { (store.snapshot?.parents.count ?? 1) <= 1 }

    /// A parent who joined with a code rather than an Apple ID. Their session is
    /// the only thing tying them to the family, which is what the way out below
    /// has to account for.
    private var hasNoAccount: Bool { identity == .anonymous }

    /// Says what each way out costs, since the three differ in ways the labels
    /// alone don't carry — and there is only one of them to explain when the
    /// parent has no account.
    private var leaveFooter: String {
        switch (hasNoAccount, isLastParent) {
        case (true, true):
            return String(localized: "You're the only parent, so leaving removes the whole family.")
        case (true, false):
            return String(localized: "Leaving gives up your place. Getting back in needs a new code from the other parent.")
        case (false, true):
            return String(localized: "You're the only parent, so leaving or deleting your account removes the whole family.")
        case (false, false):
            return String(localized: """
                Signing out keeps your place — sign back in with Apple to return. Leaving gives it \
                up, and deleting your account removes your sign-in with it.
                """)
        }
    }

    /// These two are annotated rather than inlined into the dialogs: a ternary
    /// of two literals inside `Text` leaves the compiler to choose between the
    /// `LocalizedStringKey` and `String` overloads, and `String` would silently
    /// skip the catalog.
    private var leaveWarning: LocalizedStringKey {
        isLastParent
            ? "You're the only parent, so this deletes the family, the children, the chores and all their history. This cannot be undone."
            : "You'll be removed from this family. The other parent can give you a new code if you want back in."
    }

    private var deleteAccountWarning: LocalizedStringKey {
        isLastParent
            ? "You're the only parent, so this deletes your Apple sign-in for Chores along with the family, the children, the chores and all their history. This cannot be undone."
            : "This deletes your Apple sign-in for Chores and removes you from the family. This cannot be undone."
    }

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

                // A parent with no account gets one way out rather than three.
                // Signing out would strand them — there is no credential to sign
                // back in with — and "Delete account" names something they never
                // created. What is left is leaving, and for them that deletes the
                // throwaway anonymous auth user too, so nothing orphaned stays on
                // the server. Hence the destructive RPC behind the gentler label.
                Section {
                    if !hasNoAccount {
                        Button("Sign out") {
                            Task { await perform { try await environment.backend.signOut() } }
                        }
                        .accessibilityIdentifier("manage.signOut")
                    }

                    Button("Leave this family", role: .destructive) {
                        isConfirmingLeave = true
                    }
                    .accessibilityIdentifier("manage.leave")

                    if !hasNoAccount {
                        Button("Delete account", role: .destructive) {
                            isConfirmingDelete = true
                        }
                        .accessibilityIdentifier("manage.deleteAccount")
                    }
                } footer: {
                    Text(leaveFooter)
                }
            }
            .navigationTitle("Manage")
            .confirmationDialog("Leave this family?",
                                isPresented: $isConfirmingLeave, titleVisibility: .visible) {
                Button("Leave", role: .destructive) {
                    Task {
                        await perform {
                            if hasNoAccount {
                                try await environment.backend.deleteAccount()
                            } else {
                                try await environment.backend.leaveFamily()
                            }
                        }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                // The same warning either way: what a parent with no account
                // loses is exactly what any parent loses. That leaving also
                // clears their anonymous auth user is bookkeeping, not news.
                Text(leaveWarning)
            }
            .confirmationDialog("Delete your account?",
                                isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete account", role: .destructive) {
                    Task { await perform { try await environment.backend.deleteAccount() } }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(deleteAccountWarning)
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
            errorMessage = String(localized: "Couldn't do that. Check your connection and try again.")
        }
    }
}
