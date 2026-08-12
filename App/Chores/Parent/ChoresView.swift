import SwiftUI
import ChoresCore

struct ChoresView: View {
    let store: FamilyStore
    let backend: any ChoresBackend

    @State private var isAdding = false
    @State private var newName = ""
    @State private var renaming: Chore?
    @State private var renameText = ""
    @State private var showArchived = false
    @State private var errorMessage: String?

    private var active: [Chore] { store.snapshot?.activeChores ?? [] }

    private var archived: [Chore] {
        (store.snapshot?.chores ?? [])
            .filter(\.isArchived)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }

            Section {
                ForEach(active) { chore in
                    Button(chore.name) {
                        renameText = chore.name
                        renaming = chore
                    }
                    .tint(.primary)
                    .swipeActions {
                        Button("Archive") {
                            Task { await setArchived(true, chore) }
                        }
                        .tint(.orange)
                    }
                }
                if active.isEmpty {
                    Text("No chores yet.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Active")
            } footer: {
                Text("Tap to rename. Swipe to archive.")
            }

            if !archived.isEmpty {
                Section {
                    DisclosureGroup("Archived (\(archived.count))", isExpanded: $showArchived) {
                        ForEach(archived) { chore in
                            Text(chore.name)
                                .foregroundStyle(.secondary)
                                .swipeActions {
                                    Button("Restore") {
                                        Task { await setArchived(false, chore) }
                                    }
                                    .tint(.blue)
                                }
                        }
                    }
                } footer: {
                    Text("Archived chores keep their history and their place in the schedule, but don't appear on anyone's list.")
                }
            }

            Section {
                Button("Add chore") { isAdding = true }
                    .accessibilityIdentifier("chores.add")
            }
        }
        .navigationTitle("Chores")
        .alert("Add chore", isPresented: $isAdding) {
            TextField("Name", text: $newName)
                .accessibilityIdentifier("chores.newName")
            Button("Add") { Task { await add() } }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .alert("Rename chore", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") { Task { await rename() } }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func add() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let familyID = store.snapshot?.family.id else { return }
        do {
            _ = try await backend.addChore(familyID: familyID, name: name, icon: nil)
            newName = ""
            errorMessage = nil
            await store.reloadAfterEdit()
        } catch {
            errorMessage = "Couldn't add \(name). Check your connection and try again."
        }
    }

    private func rename() async {
        guard var updated = renaming else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !trimmed.isEmpty, trimmed != updated.name else { return }
        updated.name = trimmed
        do {
            try await backend.updateChore(updated)
            errorMessage = nil
            await store.reloadAfterEdit()
        } catch {
            errorMessage = "Couldn't rename that chore. Check your connection and try again."
        }
    }

    // Archive rather than delete: deleting would orphan completion history, and
    // the schedule entries are kept so un-archiving restores the old assignments.
    private func setArchived(_ isArchived: Bool, _ chore: Chore) async {
        var updated = chore
        updated.isArchived = isArchived
        do {
            try await backend.updateChore(updated)
            errorMessage = nil
            await store.reloadAfterEdit()
        } catch {
            errorMessage = "Couldn't update \(chore.name). Check your connection and try again."
        }
    }
}
