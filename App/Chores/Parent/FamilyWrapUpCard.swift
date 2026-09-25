import SwiftUI
import ChoresCore

/// Sunday evening's and Monday's card on Family: the week's share ticked,
/// then one row per child. The line is honest — "every chore is ticked" only
/// when it is.
struct FamilyWrapUpCard: View {
    let store: FamilyStore
    let children: [Profile]
    let wrapUp: WeekWrapUp
    let onDismiss: () -> Void

    private struct Row: Identifiable {
        let child: Profile
        let progress: (done: Int, total: Int)
        var id: UUID { child.id }
    }

    private var rows: [Row] {
        children.map { Row(child: $0, progress: store.weekProgress(for: $0.id, in: wrapUp.week)) }
    }

    private var totals: (done: Int, total: Int) {
        rows.reduce(into: (done: 0, total: 0)) { sum, row in
            sum.done += row.progress.done
            sum.total += row.progress.total
        }
    }
    private var isComplete: Bool { totals.total > 0 && totals.done == totals.total }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    title
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.text)
                    line
                        .font(.system(size: 12))
                        .lineSpacing(12 * 0.45)
                        .foregroundStyle(Theme.neutral500)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                CardDismissButton(identifier: "family.wrapUp.dismiss", action: onDismiss)
            }

            VStack(spacing: 0) {
                ForEach(rows) { row in
                    childRow(row)
                }
            }
        }
        .wrapUpCard(bottomPadding: 8)
        .accessibilityIdentifier("family.wrapUp")
    }

    private func childRow(_ row: Row) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(ChildHue(hex: row.child.color).base)
                .frame(width: 8, height: 8)
            Text(row.child.displayName)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
            if row.progress.total == 0 {
                Text("Nothing scheduled")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.neutral300)
            } else {
                Text("\(row.progress.done) of \(row.progress.total)")
                    .font(.system(size: 14))
                    .monospacedDigit()
                    .foregroundStyle(Theme.neutral300)
                Text(percentText(WeekWrapUp.percent(done: row.progress.done, total: row.progress.total)))
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(toneColor(WeekWrapUp.tone(done: row.progress.done, total: row.progress.total)))
                    // 40pt is the design's column; "100%" at this size is a
                    // little wider, and must never wrap.
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 40, alignment: .trailing)
            }
        }
        .frame(minHeight: 36)
        .overlay(alignment: .top) { FadingRule(ramp: 24) }
    }

    private var title: Text {
        switch wrapUp.moment {
        case .sundayEvening: return isComplete ? Text("This week, wrapped up") : Text("This week so far")
        case .monday:        return Text("Last week")
        }
    }

    private var line: Text {
        let percent = percentText(WeekWrapUp.percent(done: totals.done, total: totals.total))
        switch wrapUp.moment {
        case .sundayEvening:
            if isComplete { return Text("Every chore for this week is ticked.") }
            return Text("\(percent) of this week's chores ticked so far.")
        case .monday:
            return Text("\(percent) of chores were ticked, \(weekRange).")
        }
    }

    /// "21 Sep – 27 Sep", the same shape as the Family header's kicker.
    private var weekRange: String {
        let timeZone = store.timeZone
        guard let monday = wrapUp.week.first, let sunday = wrapUp.week.last else { return "" }
        return "\(monday.formattedShort(in: timeZone)) – \(sunday.formattedShort(in: timeZone))"
    }

    /// "40%" in English, "40 %" in Finnish — the locale decides.
    private func percentText(_ percent: Int) -> String {
        (Double(percent) / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    private func toneColor(_ tone: WeekWrapUp.Tone) -> Color {
        switch tone {
        case .complete: return Theme.done
        case .warn:     return Theme.warn
        case .neutral:  return Theme.neutral300
        }
    }
}
