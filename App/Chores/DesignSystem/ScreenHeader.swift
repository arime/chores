import SwiftUI
import ChoresCore

/// The small uppercase line above a headline: a date, a week range, a parent
/// screen's section name.
struct Kicker: View {
    let text: Text

    var body: some View {
        text
            .font(.system(size: 11))
            .tracking(11 * 0.1)
            .textCase(.uppercase)
            .foregroundStyle(Theme.neutral500)
    }
}

/// 34pt medium, the largest thing on any screen.
struct Headline: View {
    let text: Text

    var body: some View {
        text
            .font(.system(size: 34, weight: .medium))
            .tracking(-34 * 0.02)
            .monospacedDigit()
            .foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A 2pt capsule: track in neutral900, done-mint fill.
struct ThinProgressBar: View {
    let done: Int
    let total: Int

    private var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.neutral900)
                Capsule().fill(Theme.done)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 2)
        .animation(.snappy(duration: 0.35), value: fraction)
        // The headline above already says "2 of 4 done".
        .accessibilityHidden(true)
    }
}

/// Kicker, title, and optionally the progress rule beneath. Every screen opens
/// with one of these instead of a navigation title.
struct ScreenHeader: View {
    let kicker: Text
    let title: Text
    var progress: (done: Int, total: Int)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Kicker(text: kicker)
            Headline(text: title)
                .padding(.top, 6)
            if let progress {
                ThinProgressBar(done: progress.done, total: progress.total)
                    .padding(.top, 14)
            }
        }
    }
}

/// 12pt neutral500, the line of explanation under a list.
struct Footnote: View {
    let text: Text

    var body: some View {
        text
            .font(.system(size: 12))
            .lineSpacing(12 * 0.5)
            .foregroundStyle(Theme.neutral500)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A 15pt medium heading in a 32pt row.
struct SectionHeading: View {
    let title: Text

    var body: some View {
        title
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 32)
    }
}

/// A child's heading on the family screen: name, then how far they are.
struct ChildSectionHeading: View {
    let child: Profile
    let progress: (done: Int, total: Int)

    var body: some View {
        HStack(spacing: 10) {
            Text(child.displayName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
            if progress.total > 0 {
                // "3/5" is shorthand for sighted readers; VoiceOver gets the words.
                Text("\(progress.done)/\(progress.total)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.neutral500)
                    .accessibilityLabel(Text("\(progress.done) of \(progress.total) done"))
            }
            ProgressRing(done: progress.done, total: progress.total,
                         color: ChildHue(hex: child.color).base)
        }
        .frame(minHeight: 32)
    }
}

/// Shown when the screen is rendering the cached snapshot because the last fetch
/// failed. Saying so beats silently showing data that may be hours old.
struct StaleCard: View {
    let fetchedAt: Date?
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 16))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Showing saved data")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                if let fetchedAt {
                    Text("Last updated \(fetchedAt.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.neutral500)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background {
            RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(Theme.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .strokeBorder(Theme.neutral800, lineWidth: 1)
        }
    }
}
