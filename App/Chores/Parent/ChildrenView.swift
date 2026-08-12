import SwiftUI
import ChoresCore

struct ChildrenView: View {
    let store: FamilyStore
    let backend: any ChoresBackend

    @State private var isAdding = false
    @State private var newName = ""
    @State private var editing: Profile?
    @State private var errorMessage: String?

    private var children: [Profile] { store.snapshot?.children ?? [] }

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
            } footer: {
                Text("Tap a child to rename them, change their colour, or show a setup code.")
            }

            Section {
                Button("Add child") { isAdding = true }
            }
        }
        .navigationTitle("Children")
        .alert("Add child", isPresented: $isAdding) {
            TextField("Name", text: $newName)
            Button("Add") { Task { await addChild() } }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .sheet(item: $editing) { child in
            EditChildSheet(child: child, store: store, backend: backend)
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
}

// Deleting a child is deliberately absent: it raises questions about their
// completion history that v1 does not answer.
