import SwiftUI

/// A 22pt ring with a 2pt stroke: track in neutral900, fill in the child's colour,
/// switching to done-mint once everything is done. Purely visual — the count it
/// sits next to carries the words for VoiceOver.
struct ProgressRing: View {
    let done: Int
    let total: Int
    let color: Color
    var size: CGFloat = 22

    private var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    private var isFull: Bool { total > 0 && done == total }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.neutral900, lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(isFull ? Theme.done : color,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.snappy(duration: 0.35), value: fraction)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
