import SwiftUI
import ChoresCore

/// Everyone in the family. Children get colours, ordering and chores; parents
/// get none of those and all of the powers, so the two lists differ in what they
/// offer rather than merely in their heading.
///
/// A `List` rather than a scroll view, because deleting a child is a swipe.
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
    @State private var deleting: Profile?

    private var children: [Profile] { store.snapshot?.children ?? [] }
    private var parents: [Profile] { store.snapshot?.parents ?? [] }

    var body: some View {
        List {
            BackButton(label: Text("Manage"))
                .padding(.leading, -6)
                .nocturneRow()

            ScreenHeader(kicker: Text("Manage"), title: Text("People"))
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

            SectionHeading(title: Text("Children"))
                .nocturneRow()

            ForEach(children) { child in
                Button {
                    editing = child
                } label: {
                    HStack(spacing: 14) {
                        Circle()
                            .fill(ChildHue(hex: child.color).base)
                            .frame(width: 14, height: 14)
                        Text(child.displayName)
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.text)
                        Spacer(minLength: 0)
                        if child.authUserID == nil {
                            Text("Not set up")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.neutral500)
                        }
                    }
                    .ruledRow(minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("people.child.\(child.displayName)")
                .swipeActions(edge: .trailing) {
                    Button("Delete", role: .destructive) { deleting = child }
                        .accessibilityIdentifier("people.deleteChild.\(child.displayName)")
                }
                .nocturneRow()
            }

            if children.isEmpty {
                Text("No children yet.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.neutral500)
                    .padding(.vertical, 8)
                    .nocturneRow()
            }

            AddRow(label: Text("Add child")) { isAddingChild = true }
                .accessibilityIdentifier("people.addChild")
                .nocturneRow()

            Footnote(text: Text("Tap a child to rename them, change their colour, or show a setup code."))
                .padding(.top, 8)
                .padding(.bottom, Theme.blockGap)
                .nocturneRow()

            SectionHeading(title: Text("Parents"))
                .nocturneRow()

            ForEach(parents) { parent in
                parentRow(parent)
                    .nocturneRow()
            }

            AddRow(label: Text("Add parent")) { isAddingParent = true }
                .accessibilityIdentifier("people.addParent")
                .nocturneRow()

            Footnote(text: Text("""
                Parents share everything: each can edit chores and the schedule, and \
                tick anything off. Tap another parent to show a setup code for their \
                device.
                """))
                .padding(.top, 8)
                .padding(.bottom, 40)
                .nocturneRow()
        }
        .nocturneList()
        .nocturneNavigation()
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
            ClaimCodeSheet(profile: parent, backend: backend)
        }
        .confirmationDialog("Delete \(deleting?.displayName ?? "")?",
                            isPresented: Binding(
                                get: { deleting != nil },
                                set: { isPresented in if !isPresented { deleting = nil } }
                            ),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let child = deleting { Task { await delete(child) } }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            // Naming what goes, rather than asking "are you sure?", which invites
            // a reflex yes.
            Text("""
                This removes \(deleting?.displayName ?? "") from the family, takes them off \
                the schedule, and deletes everything they've ever ticked off. This cannot be \
                undone.
                """)
        }
    }

    /// Your own row is inert. A code for your own profile only ever hands it to
    /// a different Apple ID and leaves you bound to nothing, which is not
    /// something to offer by accident — signing in with Apple is how you reach
    /// your own family.
    @ViewBuilder private func parentRow(_ parent: Profile) -> some View {
        let isMe = parent.id == me.id
        let content = HStack(spacing: 14) {
            Text(parent.displayName)
                .font(.system(size: 17))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
            if isMe {
                Text("This device")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.neutral500)
            } else if parent.authUserID == nil {
                Text("Not set up")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.neutral500)
            }
        }
        .ruledRow(minHeight: 56)

        if isMe {
            content
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("people.parent.\(parent.displayName)")
        } else {
            Button {
                showingCodeFor = parent
            } label: {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("people.parent.\(parent.displayName)")
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
            errorMessage = String(localized: "Couldn't add \(name). Check your connection and try again.")
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
            errorMessage = String(localized: "Couldn't add \(name). Check your connection and try again.")
        }
    }

    private func delete(_ child: Profile) async {
        do {
            try await backend.deleteChild(profileID: child.id)
            // A tick queued for them before deletion would otherwise wedge
            // every completion queued after it — the server will refuse it
            // forever, since the profile it names is now gone.
            await store.dropQueuedOperations(for: child.id)
            deleting = nil
            errorMessage = nil
            await store.reloadAfterEdit()
        } catch {
            deleting = nil
            errorMessage = String(localized: "Couldn't delete \(child.displayName). Check your connection and try again.")
        }
    }
}

// Only children can be deleted here. Removing another parent raises a separate
// question about who may evict whom; each parent leaves under their own account
// from Manage instead.
