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
        store.chores(for: profile.id, on: selectedDay).doneSinking
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
                    ScreenHeader(kicker: kicker, title: headline,
                                 // A future day has nothing to report yet, whatever
                                 // the store says.
                                 progress: (isFuture ? 0 : progress.done, progress.total))

                    if store.isStale {
                        StaleCard(fetchedAt: store.snapshot?.fetchedAt, tint: hue.base)
                    }

                    WeekStrip(store: store, selectedDay: selectedDay,
                              selectionFill: hue.step900, selectionStroke: hue.step700,
                              todayColor: hue.base, identifierPrefix: "kidWeek.day",
                              dots: { day in
                                  [DayDot(progress: store.progress(for: profile.id, on: day),
                                          isFuture: store.eligibility(for: day) == .future,
                                          isToday: day == store.today,
                                          color: hue.base)]
                              },
                              accessibilityLabel: { day in
                                  dayAccessibilityLabel(day, progress: store.progress(for: profile.id, on: day))
                              }) { day in
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
                        ChoreList(items: items, isEnabled: isEditable) { item in
                            Task {
                                await store.setCompleted(
                                    !item.isCompleted, chore: item.chore,
                                    profileID: profile.id, on: selectedDay,
                                    actor: profile.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.screenInset)
                .padding(.top, 12)
                // Nothing sits below the list.
                .padding(.bottom, 40)
            }
            .refreshable { await store.refresh() }
        }
    }

    // MARK: Header

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

    private var hintText: String {
        switch eligibility {
        case .future:             return String(localized: "You can tick these off on the day.")
        case .outsideCurrentWeek: return String(localized: "This week only.")
        // Unreachable — the label is only shown behind `if !isEditable`.
        case .allowed:            return ""
        }
    }
}
