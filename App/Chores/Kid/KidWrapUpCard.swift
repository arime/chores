import SwiftUI
import ChoresCore

/// Sunday evening's and Monday's card on the kid screen: how the week went,
/// in the child's own colour — mint once every chore is ticked.
struct KidWrapUpCard: View {
    let store: FamilyStore
    let profile: Profile
    let hue: ChildHue
    let wrapUp: WeekWrapUp
    let onDismiss: () -> Void

    private var progress: (done: Int, total: Int) {
        store.weekProgress(for: profile.id, in: wrapUp.week)
    }
    private var isComplete: Bool { progress.total > 0 && progress.done == progress.total }
    private var accent: Color { isComplete ? Theme.done : hue.base }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    title
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.text)
                    line
                        .font(.system(size: 13))
                        .lineSpacing(13 * 0.45)
                        .foregroundStyle(Theme.neutral300)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                CardDismissButton(identifier: "kidDay.wrapUp.dismiss", action: onDismiss)
            }

            HStack(spacing: 12) {
                Text("\(progress.done) of \(progress.total)")
                    .font(.system(size: 28, weight: .medium))
                    .tracking(-28 * 0.02)
                    .monospacedDigit()
                    .foregroundStyle(accent)
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    ForEach(wrapUp.week, id: \.self) { day in
                        DayDot(progress: store.progress(for: profile.id, on: day),
                               isFuture: store.eligibility(for: day) == .future,
                               isToday: day == store.today,
                               color: hue.base,
                               size: 9)
                    }
                }
                .accessibilityHidden(true)
            }

            ThinProgressBar(done: progress.done, total: progress.total, fill: accent)
        }
        .wrapUpCard()
        .accessibilityIdentifier("kidDay.wrapUp")
    }

    private var title: Text {
        switch wrapUp.moment {
        case .sundayEvening:
            return isComplete ? Text("Week complete!") : Text("Nearly the end of the week")
        case .monday:
            return Text("Last week")
        }
    }

    private var line: Text {
        switch wrapUp.moment {
        case .sundayEvening:
            if isComplete { return Text("You ticked every single chore. Nice one.") }
            return Text("\(progress.total - progress.done) left to tick — there's still time before bed.")
        case .monday:
            switch WeekWrapUp.kidVerdict(done: progress.done, total: progress.total) {
            case .complete:   return Text("Every chore, every day. Legend.")
            case .great:      return Text("Great week! Keep it rolling.")
            case .good:       return Text("Good going. New week, fresh start.")
            case .freshStart: return Text("New week, fresh start!")
            }
        }
    }
}
