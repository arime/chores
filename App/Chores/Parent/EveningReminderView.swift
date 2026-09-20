import SwiftUI
import ChoresCore

/// The parent's own evening reminder — theirs, not the family's, so one parent
/// switching it off does not silence the other. Saves on every change; there
/// is nothing to confirm.
struct EveningReminderView: View {
    let store: FamilyStore
    let backend: any ChoresBackend
    /// The parent using this device.
    let me: Profile

    @State private var time: TimeOfDay?
    @State private var errorMessage: String?

    init(store: FamilyStore, backend: any ChoresBackend, me: Profile) {
        self.store = store
        self.backend = backend
        self.me = me
        _time = State(initialValue: me.eveningReminderAt)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.blockGap) {
                BackButton(label: Text("Manage"))
                    .padding(.leading, -6)

                ScreenHeader(kicker: Text("Manage"), title: Text("Evening reminder"))

                ReminderTimeControl(label: Text("Remind me"),
                                    time: $time,
                                    defaultTime: TimeOfDay(hour: 21, minute: 0),
                                    identifier: "reminder.evening")

                Footnote(text: Text("Sent to this phone at this time when a child still has chores unticked."))

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.danger)
                }
            }
            .padding(.horizontal, Theme.screenInset)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .background(Theme.bg)
        .nocturneNavigation()
        .onChange(of: time) { _, newValue in
            Task { await save(newValue) }
        }
    }

    private func save(_ newValue: TimeOfDay?) async {
        var updated = store.snapshot?.profiles.first { $0.id == me.id } ?? me
        updated.eveningReminderAt = newValue
        do {
            try await backend.updateProfile(updated)
            await store.reloadAfterEdit()
        } catch {
            errorMessage = String(localized: "Couldn't save. Check your connection and try again.")
        }
    }
}
