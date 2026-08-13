import SwiftUI
import ChoresCore

/// The whole row is the button — an 11-year-old should not have to hit a
/// checkbox, and a parent reaches for the same thing. Used by both modes so that
/// ticking a chore off means one gesture everywhere.
struct ChoreRow: View {
    let item: ChoreForDay
    let isEnabled: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 16) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(item.isCompleted ? .green : .secondary)
                    .contentTransition(.symbolEffect(.replace))

                Text(item.chore.name)
                    .font(.body)
                    .strikethrough(item.isCompleted)
                    .foregroundStyle(item.isCompleted ? .secondary : .primary)

                Spacer()
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .sensoryFeedback(.success, trigger: item.isCompleted) { _, new in new }
    }
}
