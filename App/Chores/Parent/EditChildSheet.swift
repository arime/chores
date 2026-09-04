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

    /// Annotated so the `LocalizedStringKey` overload is chosen by declaration
    /// rather than inferred from a ternary of two literals.
    private var codeFooter: LocalizedStringKey {
        child.authUserID == nil
            ? "This child's device isn't set up yet."
            : "Only needed if they get a new device or reinstall the app."
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    init(child: Profile, store: FamilyStore, backend: any ChoresBackend) {
        self.child = child
        self.store = store
        self.backend = backend
        _name = State(initialValue: child.displayName)
        _color = State(initialValue: child.color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.blockGap) {
            SheetHeader(onCancel: { dismiss() }, title: Text(child.displayName)) {
                SheetPrimaryButton(title: Text("Save"), isEnabled: canSave) {
                    Task { await save() }
                }
            }

            NocturneField(kicker: Text("Name"), placeholder: "Name", text: $name,
                          identifier: "editChild.name")

            VStack(alignment: .leading, spacing: 10) {
                Kicker(text: Text("Colour"))
                HStack(spacing: 12) {
                    ForEach(ProfilePalette.options, id: \.self) { option in
                        swatch(option)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Button("Show setup code") { showingCode = true }
                    .buttonStyle(.primary)
                Footnote(text: Text(codeFooter))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.danger)
            }
        }
        .nocturneSheet()
        .sheet(isPresented: $showingCode) {
            ClaimCodeSheet(profile: child, backend: backend)
        }
    }

    /// 36pt of colour; the chosen one gets a 2pt gap of surface and then a
    /// 1.5pt ring in its own colour.
    private func swatch(_ option: String) -> some View {
        let isSelected = option == color
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { color = option }
        } label: {
            Circle()
                .fill(Color(hexString: option))
                .frame(width: 36, height: 36)
                .overlay {
                    Circle()
                        .strokeBorder(Color(hexString: option), lineWidth: 1.5)
                        .frame(width: 43, height: 43)
                        .opacity(isSelected ? 1 : 0)
                }
                .padding(4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
            errorMessage = String(localized: "Couldn't save. Check your connection and try again.")
        }
    }
}
