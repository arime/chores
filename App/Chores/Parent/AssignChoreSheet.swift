import SwiftUI
import ChoresCore

struct AssignChoreSheet: View {
    let child: Profile
    let chores: [Chore]
    let alreadyAssigned: Set<UUID>
    let onSelect: (Chore) async -> Void

    @Environment(\.dismiss) private var dismiss

    private var available: [Chore] { chores.filter { !alreadyAssigned.contains($0.id) } }

    /// Annotated rather than inlined: a ternary of two literals inside `Text`
    /// leaves the compiler to choose between the `LocalizedStringKey` and
    /// `String` overloads, and picking `String` would silently skip the catalog.
    private var emptyMessage: LocalizedStringKey {
        chores.isEmpty
            ? "Add some chores under Manage → Chores first."
            : "\(child.displayName) already has every chore on this day."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(onCancel: { dismiss() }, title: Text("Assign to \(child.displayName)")) {
                EmptyView()
            }
            .padding(.bottom, Theme.blockGap)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(available) { chore in
                        Button {
                            Task {
                                await onSelect(chore)
                                dismiss()
                            }
                        } label: {
                            Text(chore.name)
                                .font(.system(size: 17))
                                .foregroundStyle(Theme.text)
                                .ruledRow(minHeight: 52)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if available.isEmpty {
                        Text(emptyMessage)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.neutral500)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 2)
                    }
                }
            }
        }
        .nocturneSheet()
    }
}
