import SwiftUI
import ChoresCore

/// The parent's one view of the week: a strip with a dot per child per day, and
/// beneath it one section per child for whichever day is selected. Replaces the
/// old Today tab, Week grid and day detail with a single screen.
struct FamilyView: View {
    let store: FamilyStore
    /// Recorded as `completed_by` when a parent ticks something off on a child's
    /// behalf, so the audit trail says who actually did it.
    let parent: Profile
    @Binding var selectedDay: CalendarDay

    private var children: [Profile] { store.snapshot?.children ?? [] }
    private var week: [CalendarDay] { WeekCalendar.isoWeek(containing: store.today) }
    private var isToday: Bool { selectedDay == store.today }
    private var eligibility: CompletionEligibility { store.eligibility(for: selectedDay) }
    private var isEditable: Bool { eligibility == .allowed }
    private var isFuture: Bool { eligibility == .future }

    /// Everyone's chores on the selected day, added up.
    private var totals: (done: Int, total: Int) {
        totals(on: selectedDay)
    }

    private func totals(on day: CalendarDay) -> (done: Int, total: Int) {
        children.reduce(into: (done: 0, total: 0)) { sum, child in
            let progress = store.progress(for: child.id, on: day)
            sum.done += progress.done
            sum.total += progress.total
        }
    }

    var body: some View {
        // A spinner until the first snapshot settles: without it "No children yet"
        // flashes at every launch, before the family has arrived.
        if store.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.blockGap) {
                    ScreenHeader(kicker: weekRange, title: title,
                                 progress: totals.total > 0 && !isFuture ? totals : nil)

                    if store.isStale {
                        StaleCard(fetchedAt: store.snapshot?.fetchedAt, tint: Theme.accent)
                    }

                    WeekStrip(store: store, selectedDay: selectedDay,
                              selectionFill: Theme.accent900, selectionStroke: Theme.accent700,
                              todayColor: Theme.accent, identifierPrefix: "family.day",
                              dots: { day in
                                  children.map { child in
                                      DayDot(progress: store.progress(for: child.id, on: day),
                                             isFuture: store.eligibility(for: day) == .future,
                                             isToday: day == store.today,
                                             color: ChildHue(hex: child.color).base,
                                             size: 6)
                                  }
                              },
                              accessibilityLabel: { day in
                                  dayAccessibilityLabel(day, progress: totals(on: day))
                              }) { day in
                        selectedDay = day
                    }

                    // No hint for a future day: the disabled rows say enough.
                    if !isToday {
                        backToToday
                    }

                    if children.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No children yet")
                                .font(.system(size: 17))
                                .foregroundStyle(Theme.text)
                            Text("Add them under Manage → People.")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.neutral500)
                        }
                        .padding(.vertical, 24)
                    }

                    ForEach(children) { child in
                        section(for: child)
                    }
                }
                .padding(.horizontal, Theme.screenInset)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .refreshable { await store.refresh() }
        }
    }

    /// "31 Aug – 6 Sep", Monday to Sunday of the current ISO week.
    private var weekRange: Text {
        let timeZone = store.timeZone
        guard let monday = week.first, let sunday = week.last else { return Text(verbatim: "") }
        return Text("\(monday.formattedShort(in: timeZone)) – \(sunday.formattedShort(in: timeZone))")
    }

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
            .foregroundStyle(Theme.accent)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("family.backToToday")
    }

    private var title: Text {
        if !isToday { return Text(WeekdayNames.full(selectedDay.isoWeekday)) }
        if totals.total == 0 { return Text("Nothing today") }
        if totals.done == totals.total { return Text("All done") }
        return Text("\(totals.done) of \(totals.total) done")
    }

    private func section(for child: Profile) -> some View {
        let items = store.chores(for: child.id, on: selectedDay).doneSinking
        return VStack(alignment: .leading, spacing: 0) {
            ChildSectionHeading(child: child,
                                progress: store.progress(for: child.id, on: selectedDay))

            if items.isEmpty {
                (isToday ? Text("Nothing today") : Text("Nothing scheduled"))
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.neutral500)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
            } else {
                ChoreList(items: items, isEnabled: isEditable) { item in
                    Task {
                        await store.setCompleted(
                            !item.isCompleted, chore: item.chore,
                            profileID: child.id, on: selectedDay,
                            actor: parent.id)
                    }
                }
            }
        }
    }
}
