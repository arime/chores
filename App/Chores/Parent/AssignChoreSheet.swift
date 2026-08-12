import SwiftUI
import ChoresCore

struct AssignChoreSheet: View {
    let child: Profile
    let chores: [Chore]
    let alreadyAssigned: Set<UUID>
    let onSelect: (Chore) async -> Void

    @Environment(\.dismiss) private var dismiss

    private var available: [Chore] { chores.filter { !alreadyAssigned.contains($0.id) } }

    var body: some View {
        NavigationStack {
            List {
                ForEach(available) { chore in
                    Button(chore.name) {
                        Task {
                            await onSelect(chore)
                            dismiss()
                        }
                    }
                    .tint(.primary)
                }
                if available.isEmpty {
                    Text(chores.isEmpty
                         ? "Add some chores under Manage → Chores first."
                         : "\(child.displayName) already has every chore on this day.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Assign to \(child.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
