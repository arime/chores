import SwiftUI
import ChoresCore

/// The whole row is the button — an 11-year-old should not have to hit a
/// checkbox, and a parent reaches for the same thing. Used by both modes so that
/// ticking a chore off means one gesture everywhere.
struct ChoreRow: View {
    let item: ChoreForDay
    let isEnabled: Bool
    let onToggle: () -> Void

    private var isDone: Bool { item.isCompleted }

    private var rowOpacity: Double {
        if isDone { return 0.55 }
        return isEnabled ? 1 : 0.8
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 16) {
                check

                Text(item.chore.name)
                    .font(.system(size: 17))
                    .lineSpacing(17 * 0.3)
                    .strikethrough(isDone)
                    .foregroundStyle(isDone ? Theme.neutral500 : Theme.text)
                    .animation(.easeInOut(duration: 0.2), value: isDone)

                Spacer(minLength: 0)
            }
            .frame(minHeight: 60)
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { FadingRule() }
            .opacity(rowOpacity)
            .animation(.easeInOut(duration: 0.25), value: rowOpacity)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .sensoryFeedback(.success, trigger: item.isCompleted) { _, new in new }
    }

    private var check: some View {
        ZStack {
            Circle()
                .fill(isDone ? Theme.doneTint : .clear)
            Circle()
                .strokeBorder(isDone ? Theme.done : Theme.neutral600, lineWidth: 1.5)

            if isDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.doneSoft)
                    // The pop: scale 0.85 → 1.08 → 1 over 0.3s, eased out.
                    .keyframeAnimator(initialValue: 1.0, trigger: isDone) { glyph, scale in
                        glyph.scaleEffect(scale)
                    } keyframes: { _ in
                        MoveKeyframe(0.85)
                        CubicKeyframe(1.08, duration: 0.18)
                        CubicKeyframe(1.0, duration: 0.12)
                    }
            }
        }
        .frame(width: 28, height: 28)
        .animation(.easeInOut(duration: 0.2), value: isDone)
    }
}

extension Array where Element == ChoreForDay {
    /// Completed chores sink to the bottom so what's left is always on top;
    /// within each half, alphabetical.
    var doneSinking: [ChoreForDay] {
        sorted { lhs, rhs in
            if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
            return lhs.chore.name.localizedStandardCompare(rhs.chore.name) == .orderedAscending
        }
    }
}

/// A list of chore rows whose reorder animates. The store applies a tick
/// asynchronously, so the reorder cannot be wrapped in `withAnimation` at the
/// tap; animating on the order does the same job.
struct ChoreList: View {
    let items: [ChoreForDay]
    let isEnabled: Bool
    let onToggle: (ChoreForDay) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                ChoreRow(item: item, isEnabled: isEnabled) { onToggle(item) }
            }
        }
        .animation(.snappy, value: items.map(\.id))
    }
}
