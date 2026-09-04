import SwiftUI
import ChoresCore

/// The seven days of the current ISO week as a row of tappable cells, each with
/// a status dot. Today shows it without day numbers as a way into Week; Week
/// shows it with numbers and a selected cell.
struct KidWeekStrip: View {
    let store: FamilyStore
    let profile: Profile
    let hue: ChildHue
    let showsDayNumbers: Bool
    /// `nil` on Today, where no day is selected.
    let selectedDay: CalendarDay?
    /// Prefix of each cell's accessibility identifier — `"kidWeek.day"` yields
    /// `kidWeek.day.1` … `kidWeek.day.7` by ISO weekday.
    let identifierPrefix: String
    let onSelect: (CalendarDay) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(WeekCalendar.isoWeek(containing: store.today), id: \.self) { day in
                cell(for: day)
            }
        }
    }

    private func cell(for day: CalendarDay) -> some View {
        let progress = store.progress(for: profile.id, on: day)
        let eligibility = store.eligibility(for: day)
        let isToday = day == store.today
        let isSelected = day == selectedDay
        let isFuture = eligibility == .future

        return Button {
            onSelect(day)
        } label: {
            VStack(spacing: showsDayNumbers ? 6 : 7) {
                Text(WeekdayNames.short(day.isoWeekday))
                    .font(.system(size: 11))
                    .tracking(11 * 0.04)
                    .foregroundStyle(isToday ? hue.base : Theme.neutral500)

                if showsDayNumbers {
                    Text(verbatim: "\(day.day)")
                        .font(.system(size: 15))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Theme.text
                                         : isFuture ? Theme.neutral500 : Theme.neutral300)
                }

                KidDayDot(progress: progress, isFuture: isFuture, isToday: isToday, hue: hue)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, showsDayNumbers ? 9 : 8)
            .padding(.bottom, showsDayNumbers ? 10 : 9)
            .frame(minHeight: 44)
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .fill(isSelected ? hue.step900 : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(isSelected ? hue.step700 : .clear, lineWidth: 1)
            }
            .animation(.easeInOut(duration: 0.2), value: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(identifierPrefix).\(day.isoWeekday)")
        .accessibilityLabel(accessibilityLabel(for: day, progress: progress))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func accessibilityLabel(for day: CalendarDay,
                                    progress: (done: Int, total: Int)) -> Text {
        let weekday = WeekdayNames.full(day.isoWeekday)
        if progress.total == 0 {
            return Text("\(weekday), nothing scheduled")
        }
        return Text("\(weekday), \(progress.done) of \(progress.total) done")
    }
}

/// The 7pt status dot with its 1.5pt ring. One rule, evaluated per day:
///
/// | Condition             | Fill  | Ring        |
/// |-----------------------|-------|-------------|
/// | nothing scheduled     | clear | neutral800  |
/// | future day            | clear | neutral600  |
/// | everything done       | done  | done        |
/// | today, unfinished     | clear | child colour|
/// | past day, unfinished  | clear | warn        |
struct KidDayDot: View {
    let progress: (done: Int, total: Int)
    let isFuture: Bool
    let isToday: Bool
    let hue: ChildHue

    private var isFull: Bool { progress.total > 0 && progress.done == progress.total }

    private var ring: Color {
        if progress.total == 0 { return Theme.neutral800 }
        if isFuture { return Theme.neutral600 }
        if isFull { return Theme.done }
        return isToday ? hue.base : Theme.warn
    }

    var body: some View {
        Circle()
            .fill(isFull ? Theme.done : .clear)
            .overlay { Circle().strokeBorder(ring, lineWidth: 1.5) }
            .frame(width: 7, height: 7)
            .animation(.easeInOut(duration: 0.2), value: isFull)
    }
}

/// The small uppercase line above a headline: a date, a week range.
struct KidKicker: View {
    let text: Text

    var body: some View {
        text
            .font(.system(size: 11))
            .tracking(11 * 0.1)
            .textCase(.uppercase)
            .foregroundStyle(Theme.neutral500)
    }
}

/// 34pt medium, the largest thing on a kid screen.
struct KidHeadline: View {
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
