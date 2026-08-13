import SwiftUI
import ChoresCore

/// The current ISO week as a child-by-day grid. Browsing earlier weeks is
/// deliberately out of scope for v1 — the snapshot only carries this week's
/// completions.
struct ParentWeekView: View {
    let store: FamilyStore
    /// Passed through to `DayDetailView`, which records it as `completed_by`.
    let parent: Profile

    @State private var selection: WeekSelection?

    private var children: [Profile] { store.snapshot?.children ?? [] }
    private var week: [CalendarDay] { WeekCalendar.isoWeek(containing: store.today) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.isStale {
                        StaleBanner(fetchedAt: store.snapshot?.fetchedAt)
                            .padding(.horizontal)
                    }

                    // Header row of weekday initials.
                    HStack(spacing: 4) {
                        Text("").frame(width: 88, alignment: .leading)
                        ForEach(week, id: \.self) { day in
                            Text(WeekdayNames.short(day.isoWeekday))
                                .font(.caption2)
                                .foregroundStyle(day == store.today ? Color.accentColor : .secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal)

                    ForEach(children) { child in
                        HStack(spacing: 4) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color(hexString: child.color))
                                    .frame(width: 8, height: 8)
                                Text(child.displayName)
                                    .font(.subheadline)
                                    .lineLimit(1)
                            }
                            .frame(width: 88, alignment: .leading)

                            ForEach(week, id: \.self) { day in
                                let progress = store.progress(for: child.id, on: day)
                                Button {
                                    selection = WeekSelection(child: child, day: day)
                                } label: {
                                    WeekCell(done: progress.done,
                                             total: progress.total,
                                             isToday: day == store.today,
                                             color: Color(hexString: child.color))
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier(
                                    "week.\(child.displayName).\(day.isoWeekday)")
                            }
                        }
                        .padding(.horizontal)
                    }

                    if children.isEmpty {
                        ContentUnavailableView("No children yet",
                                               systemImage: "person.2",
                                               description: Text("Add them under Manage → Children."))
                            .padding(.top, 40)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("This week")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
            .navigationDestination(item: $selection) { selected in
                DayDetailView(store: store, child: selected.child, day: selected.day,
                              parent: parent)
            }
        }
    }
}

/// `navigationDestination(item:)` needs a single Identifiable value.
struct WeekSelection: Identifiable, Hashable {
    let child: Profile
    let day: CalendarDay
    var id: String { "\(child.id)|\(day.year)-\(day.month)-\(day.day)" }
}

struct WeekCell: View {
    let done: Int
    let total: Int
    let isToday: Bool
    let color: Color

    private var background: Color {
        if total == 0 { return .secondary.opacity(0.08) }
        return done == total ? color.opacity(0.85) : color.opacity(0.18)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(background)
            .overlay {
                if total > 0 {
                    Text("\(done)/\(total)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(done == total ? .white : .primary)
                }
            }
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .frame(height: 34)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(total == 0 ? "nothing scheduled" : "\(done) of \(total) done")
    }
}
