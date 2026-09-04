import SwiftUI
import ChoresCore

/// The child's one screen: a headline for the selected day, the week strip that
/// is the whole navigation, and that day's chores. Today and earlier days of the
/// current ISO week are tappable; future days are read-only previews.
/// `ScheduleResolver.eligibility` encodes that rule and is already tested — this
/// view only reads it.
struct KidDayView: View {
    let store: FamilyStore
    let profile: Profile
    @Binding var selectedDay: CalendarDay

    private var hue: ChildHue { ChildHue(hex: profile.color) }
    private var isToday: Bool { selectedDay == store.today }
    private var eligibility: CompletionEligibility { store.eligibility(for: selectedDay) }
    private var isEditable: Bool { eligibility == .allowed }
    private var isFuture: Bool { eligibility == .future }

    private var items: [ChoreForDay] {
        // Completed chores sink to the bottom so what's left is always on top.
        store.chores(for: profile.id, on: selectedDay)
            .sorted { lhs, rhs in
                if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
                return lhs.chore.name.localizedStandardCompare(rhs.chore.name) == .orderedAscending
            }
    }

    private var progress: (done: Int, total: Int) {
        store.progress(for: profile.id, on: selectedDay)
    }

    var body: some View {
        // An empty day is a claim about the schedule, and there is no schedule
        // yet until the first snapshot arrives — so wait it out with a spinner.
        if store.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.blockGap) {
                    header

                    if store.isStale {
                        KidStaleBanner(fetchedAt: store.snapshot?.fetchedAt, tint: hue.base)
                    }

                    KidWeekStrip(store: store, profile: profile, hue: hue,
                                 selectedDay: selectedDay) { day in
                        selectedDay = day
                    }

                    if !isToday {
                        backToToday
                    }

                    // The hint sits just above the rows it explains, so an empty
                    // future day — which has no rows — gets no hint either.
                    if !isEditable && (!items.isEmpty || eligibility == .outsideCurrentWeek) {
                        Text(hintText)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.neutral500)
                    }

                    if items.isEmpty {
                        if isToday { emptyToday } else { emptyOtherDay }
                    } else {
                        list
                    }
                }
                .padding(.horizontal, Theme.screenInset)
                .padding(.top, 12)
                // Nothing sits below the list any more.
                .padding(.bottom, 40)
            }
            .refreshable { await store.refresh() }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            KidKicker(text: kicker)
            KidHeadline(text: headline)
                .padding(.top, 6)
            // A future day has nothing to report yet, whatever the store says.
            KidProgressBar(done: isFuture ? 0 : progress.done, total: progress.total)
                .padding(.top, 14)
        }
    }

    /// "Today · Friday 4 September", or "Thursday · 3 September" for any other day.
    private var kicker: Text {
        let timeZone = store.timeZone
        if isToday {
            return Text("Today · \(selectedDay.formattedLong(in: timeZone))")
        }
        return Text("\(WeekdayNames.full(selectedDay.isoWeekday)) · \(selectedDay.formattedDayAndMonth(in: timeZone))")
    }

    private var headline: Text {
        let weekday = WeekdayNames.full(selectedDay.isoWeekday)
        if isFuture { return Text(weekday) }
        if progress.total == 0 {
            return isToday ? Text("Nothing today") : Text("Nothing scheduled")
        }
        if progress.done == progress.total {
            return isToday ? Text("All done") : Text("\(weekday) done")
        }
        return Text("\(progress.done) of \(progress.total) done")
    }

    // MARK: Below the strip

    private var backToToday: some View {
        Button {
            selectedDay = store.today
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                Text("Back to today")
                    .font(.system(size: 13))
            }
            .foregroundStyle(hue.base)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("kidDay.backToToday")
    }

    private var emptyToday: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(Theme.done)
            Text("Nothing today")
                .font(.system(size: 17))
                .foregroundStyle(Theme.text)
            Text("Enjoy it.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.neutral500)
        }
        .padding(.vertical, 48)
    }

    private var emptyOtherDay: some View {
        Text("Nothing scheduled, enjoy your day off!")
            .font(.system(size: 15))
            .foregroundStyle(Theme.neutral500)
            .padding(.vertical, 8)
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                ChoreRow(item: item, isEnabled: isEditable) {
                    Task {
                        await store.setCompleted(
                            !item.isCompleted, chore: item.chore,
                            profileID: profile.id, on: selectedDay,
                            actor: profile.id)
                    }
                }
            }
        }
        // The store applies a tick asynchronously, so the reorder cannot be
        // wrapped in `withAnimation` at the tap; animate on the order instead.
        .animation(.snappy, value: items.map(\.id))
    }

    private var hintText: String {
        switch eligibility {
        case .future:             return String(localized: "You can tick these off on the day.")
        case .outsideCurrentWeek: return String(localized: "This week only.")
        // Unreachable — the label is only shown behind `if !isEditable`.
        case .allowed:            return ""
        }
    }
}

/// A 2pt capsule under the headline: track in neutral900, done-mint fill.
struct KidProgressBar: View {
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

/// Shown when the screen is rendering the cached snapshot because the last fetch
/// failed. The kid-screen counterpart of `StaleBanner`: a quiet surface card
/// rather than an orange list row.
struct KidStaleBanner: View {
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
