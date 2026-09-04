import SwiftUI
import ChoresCore

/// Today and earlier days of the current ISO week are tappable; future days are
/// read-only previews. `ScheduleResolver.eligibility` encodes that rule and is
/// already tested — this view only reads it.
struct KidWeekView: View {
    let store: FamilyStore
    let profile: Profile
    @Binding var selectedDay: CalendarDay

    private var hue: ChildHue { ChildHue(hex: profile.color) }
    private var week: [CalendarDay] { WeekCalendar.isoWeek(containing: store.today) }
    private var eligibility: CompletionEligibility { store.eligibility(for: selectedDay) }
    private var isEditable: Bool { eligibility == .allowed }

    var body: some View {
        // Same reason as Today: an empty week is a claim about the schedule, and
        // there is no schedule yet until the first snapshot arrives.
        if store.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.blockGap) {
                    header

                    KidWeekStrip(store: store, profile: profile, hue: hue,
                                 showsDayNumbers: true, selectedDay: selectedDay,
                                 identifierPrefix: "kidWeek.day") { day in
                        selectedDay = day
                    }

                    if !isEditable {
                        Text(hintText)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.neutral500)
                    }

                    let items = store.chores(for: profile.id, on: selectedDay)
                    if items.isEmpty {
                        Text("Nothing scheduled")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.neutral500)
                            .padding(.vertical, 8)
                    } else {
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
                    }
                }
                .padding(.horizontal, Theme.screenInset)
                .padding(.top, 12)
                .padding(.bottom, Theme.blockGap)
            }
            .refreshable { await store.refresh() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            KidKicker(text: weekRange)
            KidHeadline(text: selectedDay == store.today
                        ? Text("Today")
                        : Text(WeekdayNames.full(selectedDay.isoWeekday)))
                .padding(.top, 6)
        }
    }

    /// "31 Aug – 6 Sep", Monday to Sunday of the current ISO week.
    private var weekRange: Text {
        let timeZone = store.timeZone
        guard let monday = week.first, let sunday = week.last else { return Text(verbatim: "") }
        return Text("\(monday.formattedShort(in: timeZone)) – \(sunday.formattedShort(in: timeZone))")
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
