import SwiftUI
import ChoresCore

struct EditChildSheet: View {
    let child: Profile
    let store: FamilyStore
    let backend: any ChoresBackend

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var color: String
    @State private var showingCode = false
    @State private var errorMessage: String?

    init(child: Profile, store: FamilyStore, backend: any ChoresBackend) {
        self.child = child
        self.store = store
        self.backend = backend
        _name = State(initialValue: child.displayName)
        _color = State(initialValue: child.color)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                }

                Section("Colour") {
                    HStack(spacing: 12) {
                        ForEach(ProfilePalette.options, id: \.self) { option in
                            Button {
                                color = option
                            } label: {
                                Circle()
                                    .fill(Color(hexString: option))
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        if option == color {
                                            Circle().strokeBorder(.primary, lineWidth: 3)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option)
                        }
                    }
                }

                Section {
                    Button("Show setup code") { showingCode = true }
                } footer: {
                    Text(child.authUserID == nil
                         ? "This child's device isn't set up yet."
                         : "Only needed if they get a new device or reinstall the app.")
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(child.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $showingCode) {
                ClaimCodeSheet(profile: child, backend: backend)
            }
        }
    }

    private func save() async {
        var updated = child
        updated.displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.color = color
        do {
            try await backend.updateProfile(updated)
            await store.reloadAfterEdit()
            dismiss()
        } catch {
            errorMessage = "Couldn't save. Check your connection and try again."
        }
    }
}
