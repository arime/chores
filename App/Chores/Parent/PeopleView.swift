import SwiftUI
import ChoresCore

/// Everyone in the family. Children get colours, ordering and chores; parents
/// get none of those and all of the powers, so the two lists differ in what they
/// offer rather than merely in their heading.
struct PeopleView: View {
    let store: FamilyStore
    let backend: any ChoresBackend
    /// The parent using this device, so their own row can say so.
    let me: Profile

    @State private var isAddingChild = false
    @State private var isAddingParent = false
    @State private var newName = ""
    @State private var editing: Profile?
    @State private var showingCodeFor: Profile?
    @State private var errorMessage: String?

    private var children: [Profile] { store.snapshot?.children ?? [] }
    private var parents: [Profile] { store.snapshot?.parents ?? [] }

    var body: some View {
        List {
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }

            Section {
                ForEach(children) { child in
                    Button {
                        editing = child
                    } label: {
                        HStack {
                            Circle()
                                .fill(Color(hexString: child.color))
                                .frame(width: 14, height: 14)
                            Text(child.displayName)
                            Spacer()
                            if child.authUserID == nil {
                                Text("Not set up")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tint(.primary)
                }
                if children.isEmpty {
                    Text("No children yet.").foregroundStyle(.secondary)
                }
                Button("Add child") { isAddingChild = true }
                    .accessibilityIdentifier("people.addChild")
            } header: {
                Text("Children")
            } footer: {
                Text("Tap a child to rename them, change their colour, or show a setup code.")
            }

            Section {
                ForEach(parents) { parent in
                    Button {
                        showingCodeFor = parent
                    } label: {
                        HStack {
                            Text(parent.displayName)
                            Spacer()
                            if parent.id == me.id {
                                Text("This device")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if parent.authUserID == nil {
                                Text("Not set up")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tint(.primary)
                    .accessibilityIdentifier("people.parent.\(parent.displayName)")
                }
                Button("Add parent") { isAddingParent = true }
                    .accessibilityIdentifier("people.addParent")
            } header: {
                Text("Parents")
            } footer: {
                Text("""
                    Parents share everything: each can edit chores and the schedule, and \
                    tick anything off. Tap one to show a setup code for their device.
                    """)
            }
        }
        .navigationTitle("People")
        .alert("Add child", isPresented: $isAddingChild) {
            TextField("Name", text: $newName)
            Button("Add") { Task { await addChild() } }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .alert("Add parent", isPresented: $isAddingParent) {
            TextField("Name", text: $newName)
            Button("Add") { Task { await addParent() } }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .sheet(item: $editing) { child in
            EditChildSheet(child: child, store: store, backend: backend)
        }
        .sheet(item: $showingCodeFor) { parent in
            ClaimCodeSheet(profile: parent, backend: backend,
                           isOwnProfile: parent.id == me.id)
        }
    }

    private func addChild() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let familyID = store.snapshot?.family.id else { return }
        // Cycle the palette so consecutive children get distinct colours.
        let color = ProfilePalette.options[children.count % ProfilePalette.options.count]
        do {
            _ = try await backend.addChild(familyID: familyID, name: name,
                                           color: color, sortOrder: children.count)
            newName = ""
            errorMessage = nil
            await store.reloadAfterEdit()
        } catch {
            errorMessage = "Couldn't add \(name). Check your connection and try again."
        }
    }

    private func addParent() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let familyID = store.snapshot?.family.id else { return }
        do {
            _ = try await backend.addParent(familyID: familyID, name: name)
            newName = ""
            errorMessage = nil
            await store.reloadAfterEdit()
        } catch {
            errorMessage = "Couldn't add \(name). Check your connection and try again."
        }
    }
}

// Deleting anyone is deliberately absent: it raises questions about completion
// history, and for parents about who may remove whom, that v1 does not answer.
