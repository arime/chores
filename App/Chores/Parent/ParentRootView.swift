import SwiftUI
import ChoresCore

enum ParentTab {
    case family
    case manage
}

/// The parent's app: the family's week on one tab, everything editable on the
/// other.
struct ParentRootView: View {
    let environment: AppEnvironment
    let profile: Profile
    /// How this parent got here — signed in with Apple, or a code on an
    /// anonymous device. Manage is the only screen that cares.
    let identity: DeviceIdentity
    let onSessionChanged: () async -> Void

    @State private var store: FamilyStore
    @State private var tab: ParentTab = .family
    @State private var selectedDay: CalendarDay
    /// Manage's navigation, held here so that tapping its tab a second time can
    /// pop back to the hub — what the system tab bar did on its own.
    @State private var managePath: [ManageDestination] = []

    init(environment: AppEnvironment, profile: Profile, identity: DeviceIdentity,
         onSessionChanged: @escaping () async -> Void) {
        self.environment = environment
        self.profile = profile
        self.identity = identity
        self.onSessionChanged = onSessionChanged
        let store = FamilyStore(
            backend: environment.backend,
            cache: environment.snapshotCache,
            outbox: environment.outbox,
            familyID: profile.familyID)
        _store = State(initialValue: store)
        _selectedDay = State(initialValue: store.today)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case .family:
                    FamilyView(store: store, parent: profile, selectedDay: $selectedDay)
                case .manage:
                    ManageView(store: store, environment: environment, parent: profile,
                               identity: identity, path: $managePath,
                               onSessionChanged: onSessionChanged)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            NocturneTabBar(
                items: [
                    TabBarItem(tab: .family, systemImage: "checklist",
                               title: Text("Family"), identifier: "tab.family"),
                    TabBarItem(tab: .manage, systemImage: "slider.horizontal.3",
                               title: Text("Manage"), identifier: "tab.manage"),
                ],
                selection: tab, activeColor: Theme.accent) { picked in
                    // Tapping the tab you are already on goes back to its start.
                    if picked == tab && picked == .manage { managePath.removeAll() }
                    tab = picked
                    // Coming back to Family always lands on today.
                    if picked == .family { selectedDay = store.today }
                }
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await store.start() }
    }
}

/// The three screens behind the hub.
enum ManageDestination: Hashable {
    case people
    case chores
    case schedule
}

/// The hub: People, Chores and Schedule behind three rows, then the pages the
/// App Store listing points at, then the ways out.
struct ManageView: View {
    let store: FamilyStore
    let environment: AppEnvironment
    let parent: Profile
    let identity: DeviceIdentity
    @Binding var path: [ManageDestination]
    let onSessionChanged: () async -> Void

    @State private var isConfirmingLeave = false
    @State private var isConfirmingDelete = false
    @State private var errorMessage: String?

    private var isLastParent: Bool { (store.snapshot?.parents.count ?? 1) <= 1 }
    private var childCount: Int { store.snapshot?.children.count ?? 0 }
    private var activeChoreCount: Int { store.snapshot?.activeChores.count ?? 0 }

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
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.blockGap) {
                    ScreenHeader(kicker: Text("Parent"), title: Text("Manage"))

                    hub

                    about

                    account
                }
                .padding(.horizontal, Theme.screenInset)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ManageDestination.self) { destination in
                Group {
                    switch destination {
                    case .people:
                        PeopleView(store: store, backend: environment.backend, me: parent)
                    case .chores:
                        ChoresView(store: store, backend: environment.backend)
                    case .schedule:
                        ScheduleEditorView(store: store, backend: environment.backend)
                    }
                }
                // Their back buttons sit in List rows, where `dismiss()` does
                // not pop; popping the path does.
                .environment(\.popAction) {
                    if !path.isEmpty { path.removeLast() }
                }
            }
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

    private var hub: some View {
        VStack(spacing: 0) {
            NavigationLink(value: ManageDestination.people) {
                HubRow(systemImage: "person.2", label: Text("People"),
                       meta: Text("\(childCount) children"))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("manage.people")

            NavigationLink(value: ManageDestination.chores) {
                HubRow(systemImage: "list.bullet", label: Text("Chores"),
                       meta: Text("\(activeChoreCount) active"))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("manage.chores")

            NavigationLink(value: ManageDestination.schedule) {
                HubRow(systemImage: "calendar.badge.clock", label: Text("Schedule"))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("manage.schedule")
        }
    }

    // Both pages are also what the App Store listing points at. They are here
    // because this is where someone looks for them, and only in parent mode —
    // the child's side has no way out to the web, which is a thing worth
    // keeping true.
    private var about: some View {
        VStack(alignment: .leading, spacing: 0) {
            linkRow(Text("Privacy policy"), to: AppLinks.privacyPolicy)
                .accessibilityIdentifier("manage.privacyPolicy")
            linkRow(Text("Help"), to: AppLinks.support)
                .accessibilityIdentifier("manage.help")
            // The build number earns its place here: it is the one thing
            // someone can quote in a support email that identifies the exact
            // binary, and build/uploads.log maps it to a commit.
            Footnote(text: Text(verbatim: AppIdentity.summary))
                .monospacedDigit()
                .padding(.top, 8)
        }
    }

    private func linkRow(_ label: Text, to destination: URL) -> some View {
        Link(destination: destination) {
            HStack(spacing: 14) {
                label
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.neutral600)
            }
            .ruledRow(minHeight: 52, verticalPadding: 4)
            .contentShape(Rectangle())
        }
    }

    // A parent with no account gets one way out rather than three. Signing out
    // would strand them — there is no credential to sign back in with — and
    // "Delete account" names something they never created. What is left is
    // leaving, and for them that deletes the throwaway anonymous auth user too,
    // so nothing orphaned stays on the server. Hence the destructive RPC behind
    // the gentler label.
    private var account: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !hasNoAccount {
                accountRow(Text("Sign out"), color: Theme.text) {
                    Task { await perform { try await environment.backend.signOut() } }
                }
                .accessibilityIdentifier("manage.signOut")
            }

            accountRow(Text("Leave this family"), color: Theme.danger) {
                isConfirmingLeave = true
            }
            .accessibilityIdentifier("manage.leave")

            if !hasNoAccount {
                accountRow(Text("Delete account"), color: Theme.danger) {
                    isConfirmingDelete = true
                }
                .accessibilityIdentifier("manage.deleteAccount")
            }

            Footnote(text: Text(leaveFooter))
                .padding(.top, 8)
        }
    }

    private func accountRow(_ label: Text, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label
                .font(.system(size: 17))
                .foregroundStyle(color)
                .ruledRow(minHeight: 52, verticalPadding: 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
