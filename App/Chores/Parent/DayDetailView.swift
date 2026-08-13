import SwiftUI
import ChoresCore

/// One child's chores on one day. Reachable by tapping a cell in the week grid.
struct DayDetailView: View {
    let store: FamilyStore
    let child: Profile
    let day: CalendarDay
    /// Recorded as `completed_by`: the parent did this, not the child.
    let parent: Profile

    private var isEditable: Bool { store.eligibility(for: day) == .allowed }

    var body: some View {
        List {
            if !isEditable {
                Section {
                    Label("This day hasn't happened yet.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            let chores = store.chores(for: child.id, on: day)
            if chores.isEmpty {
                Text("Nothing scheduled").foregroundStyle(.secondary)
            }
            ForEach(chores) { item in
                ChoreRow(item: item, isEnabled: isEditable) {
                    Task {
                        await store.setCompleted(!item.isCompleted, chore: item.chore,
                                                 profileID: child.id, on: day,
                                                 actor: parent.id)
                    }
                }
            }
        }
        .navigationTitle("\(child.displayName) · \(WeekdayNames.full(day.isoWeekday))")
        .navigationBarTitleDisplayMode(.inline)
    }
}
