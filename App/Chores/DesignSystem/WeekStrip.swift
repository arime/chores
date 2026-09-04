import SwiftUI
import ChoresCore

/// The seven days of the current ISO week as a row of tappable cells: weekday,
/// day number, and a line of status dots. The kid screen shows one dot in the
/// child's own hue and selects in that hue; the family screen shows one dot per
/// child and selects in the app accent.
struct WeekStrip: View {
    let store: FamilyStore
    let selectedDay: CalendarDay
    /// The selected cell's fill and 1pt stroke, and today's label colour.
    let selectionFill: Color
    let selectionStroke: Color
    let todayColor: Color
    /// Prefix of each cell's accessibility identifier — `"kidWeek.day"` yields
    /// `kidWeek.day.1` … `kidWeek.day.7` by ISO weekday.
    let identifierPrefix: String
    let dots: (CalendarDay) -> [DayDot]
    let accessibilityLabel: (CalendarDay) -> Text
    let onSelect: (CalendarDay) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(WeekCalendar.isoWeek(containing: store.today), id: \.self) { day in
                cell(for: day)
            }
        }
    }

    private func cell(for day: CalendarDay) -> some View {
        let isToday = day == store.today
        let isSelected = day == selectedDay
        let isFuture = store.eligibility(for: day) == .future
        let dayDots = dots(day)

        return Button {
            onSelect(day)
        } label: {
            VStack(spacing: 6) {
                Text(WeekdayNames.short(day.isoWeekday))
                    .font(.system(size: 11))
                    .tracking(11 * 0.04)
                    .foregroundStyle(isToday ? todayColor : Theme.neutral500)

                Text(verbatim: "\(day.day)")
                    .font(.system(size: 15))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Theme.text
                                     : isFuture ? Theme.neutral500 : Theme.neutral300)

                HStack(spacing: 3) {
                    ForEach(Array(dayDots.enumerated()), id: \.offset) { _, dot in
                        dot
                    }
                }
                .frame(minHeight: 7)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 9)
            .padding(.bottom, 10)
            .frame(minHeight: 44)
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .fill(isSelected ? selectionFill : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(isSelected ? selectionStroke : .clear, lineWidth: 1)
            }
            .animation(.easeInOut(duration: 0.2), value: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(identifierPrefix).\(day.isoWeekday)")
        .accessibilityLabel(accessibilityLabel(day))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A status dot with a 1.5pt ring. One rule, evaluated per day and child:
///
/// | Condition             | Fill  | Ring          |
/// |-----------------------|-------|---------------|
/// | nothing scheduled     | clear | neutral800    |
/// | future day            | clear | neutral600    |
/// | everything done       | done  | done          |
/// | today, unfinished     | clear | child colour  |
/// | past day, unfinished  | clear | warn          |
struct DayDot: View {
    let progress: (done: Int, total: Int)
    let isFuture: Bool
    let isToday: Bool
    let color: Color
    var size: CGFloat = 7

    private var isFull: Bool { progress.total > 0 && progress.done == progress.total }

    private var ring: Color {
        if progress.total == 0 { return Theme.neutral800 }
        if isFuture { return Theme.neutral600 }
        if isFull { return Theme.done }
        return isToday ? color : Theme.warn
    }

    var body: some View {
        Circle()
            .fill(isFull ? Theme.done : .clear)
            .overlay { Circle().strokeBorder(ring, lineWidth: 1.5) }
            .frame(width: size, height: size)
            .animation(.easeInOut(duration: 0.2), value: isFull)
    }
}

/// "{Weekday}, 2 of 4 done" or "{Weekday}, nothing scheduled" — what a strip
/// cell says to VoiceOver.
func dayAccessibilityLabel(_ day: CalendarDay, progress: (done: Int, total: Int)) -> Text {
    let weekday = WeekdayNames.full(day.isoWeekday)
    if progress.total == 0 {
        return Text("\(weekday), nothing scheduled")
    }
    return Text("\(weekday), \(progress.done) of \(progress.total) done")
}
