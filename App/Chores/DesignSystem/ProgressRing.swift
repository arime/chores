import SwiftUI

struct ProgressRing: View {
    let done: Int
    let total: Int
    let color: Color

    private var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: 6)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.snappy, value: fraction)
            Text("\(done)/\(total)")
                .font(.caption2.bold())
                .monospacedDigit()
        }
        .frame(width: 44, height: 44)
        // The "3/5" inside is shorthand for sighted readers; spell it out instead
        // of letting VoiceOver read the fraction.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(done) of \(total) done")
    }
}
