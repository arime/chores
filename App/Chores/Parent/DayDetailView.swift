import SwiftUI
import ChoresCore

/// One child's chores on one day. Reachable by tapping a cell in the week grid.
struct DayDetailView: View {
    let store: FamilyStore
    let child: Profile
    let day: CalendarDay
    /// Recorded as `completed_by`: the parent did this, not the child.
    let parent: Profile

    var body: some View {
        List {
            let chores = store.chores(for: child.id, on: day)
            if chores.isEmpty {
                Text("Nothing scheduled").foregroundStyle(.secondary)
            }
            ForEach(chores) { item in
                HStack {
                    Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.isCompleted ? .green : .secondary)
                    Text(item.chore.name)
                        .strikethrough(item.isCompleted)
                    Spacer()
                }
                .swipeActions {
                    if item.isCompleted {
                        Button("Undo") {
                            Task {
                                await store.setCompleted(false, chore: item.chore,
                                                         profileID: child.id, on: day,
                                                         actor: parent.id)
                            }
                        }
                        .tint(.orange)
                    } else if store.eligibility(for: day) == .allowed {
                        Button("Mark done") {
                            Task {
                                await store.setCompleted(true, chore: item.chore,
                                                         profileID: child.id, on: day,
                                                         actor: parent.id)
                            }
                        }
                        .tint(.green)
                    }
                }
            }
        }
        .navigationTitle("\(child.displayName) · \(WeekdayNames.full(day.isoWeekday))")
        .navigationBarTitleDisplayMode(.inline)
    }
}
