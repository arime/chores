import SwiftUI
import ChoresCore

/// Today and earlier days of the current ISO week are tappable; future days are
/// read-only previews. `ScheduleResolver.eligibility` encodes that rule and is
/// already tested — this view only reads it.
struct KidWeekView: View {
    let store: FamilyStore
    let profile: Profile

    @State private var selectedDay: CalendarDay?

    private var week: [CalendarDay] { WeekCalendar.isoWeek(containing: store.today) }
    private var day: CalendarDay { selectedDay ?? store.today }
    private var isEditable: Bool { store.eligibility(for: day) == .allowed }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(day.formattedLong(in: store.timeZone))
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder private var content: some View {
        // Same reason as Today: an empty week is a claim about the schedule, and
        // there is no schedule yet until the first snapshot arrives.
        if store.isLoading {
            ProgressView()
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(week, id: \.self) { candidate in
                        let progress = store.progress(for: profile.id, on: candidate)
                        Button {
                            selectedDay = candidate
                        } label: {
                            VStack(spacing: 4) {
                                Text(WeekdayNames.short(candidate.isoWeekday))
                                    .font(.caption2)
                                Circle()
                                    .fill(dotColor(done: progress.done, total: progress.total))
                                    .frame(width: 8, height: 8)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(candidate == day
                                          ? Color.accentColor.opacity(0.15) : .clear)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("kidWeek.day.\(candidate.isoWeekday)")
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)

                List {
                    if !isEditable {
                        Section {
                            Label(hintText, systemImage: "info.circle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    let items = store.chores(for: profile.id, on: day)
                    if items.isEmpty {
                        Text("Nothing scheduled").foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        ChoreRow(item: item, isEnabled: isEditable) {
                            Task {
                                await store.setCompleted(
                                    !item.isCompleted, chore: item.chore,
                                    profileID: profile.id, on: day, actor: profile.id)
                            }
                        }
                    }
                }
            }
            .refreshable { await store.refresh() }
        }
    }

    private var hintText: String {
        switch store.eligibility(for: day) {
        case .future:             return String(localized: "You can tick these off on the day.")
        case .outsideCurrentWeek: return String(localized: "This week only.")
        // Unreachable — the label is only shown behind `if !isEditable`.
        case .allowed:            return ""
        }
    }

    private func dotColor(done: Int, total: Int) -> Color {
        if total == 0 { return .secondary.opacity(0.25) }
        return done == total ? .green : .orange
    }
}
