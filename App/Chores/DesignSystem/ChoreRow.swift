import SwiftUI
import ChoresCore

/// The whole row is the button — an 11-year-old should not have to hit a
/// checkbox, and a parent reaches for the same thing. Used by both modes so that
/// ticking a chore off means one gesture everywhere.
struct ChoreRow: View {
    let item: ChoreForDay
    let isEnabled: Bool
    let onToggle: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var isDone: Bool { item.isCompleted }

    /// Exact Nocturne tokens on the (always dark) kid screens; system colours on a
    /// parent's light screen, where `Theme.text` would vanish into the background.
    private var nameColor: Color {
        switch (colorScheme, isDone) {
        case (.dark, false): return Theme.text
        case (.dark, true):  return Theme.neutral500
        case (_, false):     return .primary
        case (_, true):      return .secondary
        }
    }

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
                    .foregroundStyle(nameColor)
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
        // The row draws its own fading rule and sets its own height; a parent's
        // List must not add a second line under it or pad it taller still.
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
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
