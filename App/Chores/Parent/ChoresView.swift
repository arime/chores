import SwiftUI
import ChoresCore

/// A `List` rather than a scroll view, because archiving is a swipe.
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
            BackButton(label: Text("Manage"))
                .padding(.leading, -6)
                .nocturneRow()

            ScreenHeader(kicker: Text("Manage"), title: Text("Chores"))
                .padding(.top, 4)
                .padding(.bottom, Theme.blockGap)
                .nocturneRow()

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.danger)
                    .padding(.bottom, 12)
                    .nocturneRow()
            }

            SectionHeading(title: Text("Active"))
                .nocturneRow()

            ForEach(active) { chore in
                Button {
                    renameText = chore.name
                    renaming = chore
                } label: {
                    Text(chore.name)
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.text)
                        .ruledRow(minHeight: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Archive") {
                        Task { await setArchived(true, chore) }
                    }
                    .tint(Theme.neutral600)
                }
                .nocturneRow()
            }

            if active.isEmpty {
                Text("No chores yet.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.neutral500)
                    .padding(.vertical, 8)
                    .nocturneRow()
            }

            AddRow(label: Text("Add chore")) { isAdding = true }
                .accessibilityIdentifier("chores.add")
                .nocturneRow()

            Footnote(text: Text("Tap to rename. Swipe to archive."))
                .padding(.top, 8)
                .padding(.bottom, Theme.blockGap)
                .nocturneRow()

            if !archived.isEmpty {
                archivedDisclosure
                    .nocturneRow()

                if showArchived {
                    ForEach(archived) { chore in
                        HStack(spacing: 14) {
                            Text(chore.name)
                                .font(.system(size: 17))
                                .foregroundStyle(Theme.neutral500)
                            Spacer(minLength: 0)
                            Button("Restore") {
                                Task { await setArchived(false, chore) }
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.accent300)
                            .buttonStyle(.plain)
                            .frame(minHeight: 44)
                            .padding(.horizontal, 4)
                        }
                        .ruledRow(minHeight: 52)
                        .nocturneRow()
                    }

                    Footnote(text: Text("Archived chores keep their history and their place in the schedule, but don't appear on anyone's list."))
                        .padding(.top, 8)
                        .nocturneRow()
                }
            }

            Color.clear
                .frame(height: 24)
                .nocturneRow()
        }
        .nocturneList()
        .nocturneNavigation()
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
            // Read the chore and the typed name here, synchronously: dismissing
            // the alert clears `renaming`, and it would already be nil by the
            // time a task spawned here got to look at it.
            Button("Save") {
                if let chore = renaming { Task { await rename(chore, to: renameText) } }
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    /// "Archived (n)" with a chevron that turns to point down while open.
    private var archivedDisclosure: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showArchived.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .rotationEffect(.degrees(showArchived ? 90 : 0))
                Text("Archived (\(archived.count))")
                    .font(.system(size: 15))
            }
            .foregroundStyle(Theme.neutral300)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            errorMessage = String(localized: "Couldn't add \(name). Check your connection and try again.")
        }
    }

    private func rename(_ chore: Chore, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != chore.name else { return }
        var updated = chore
        updated.name = trimmed
        do {
            try await backend.updateChore(updated)
            errorMessage = nil
            await store.reloadAfterEdit()
        } catch {
            errorMessage = String(localized: "Couldn't rename that chore. Check your connection and try again.")
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
            errorMessage = String(localized: "Couldn't update \(chore.name). Check your connection and try again.")
        }
    }
}
