import SwiftUI
import ChoresCore

struct KidTodayView: View {
    let store: FamilyStore
    let profile: Profile
    @Binding var tab: KidTab
    @Binding var selectedDay: CalendarDay

    private var hue: ChildHue { ChildHue(hex: profile.color) }

    private var items: [ChoreForDay] {
        // Completed chores sink to the bottom so what's left is always on top.
        store.chores(for: profile.id, on: store.today)
            .sorted { lhs, rhs in
                if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
                return lhs.chore.name.localizedStandardCompare(rhs.chore.name) == .orderedAscending
            }
    }

    private var progress: (done: Int, total: Int) {
        store.progress(for: profile.id, on: store.today)
    }

    var body: some View {
        // "Nothing today. Enjoy it." is the wrong thing to promise for the moment
        // before the first snapshot lands, so wait it out with a spinner.
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
                                 showsDayNumbers: false, selectedDay: nil,
                                 identifierPrefix: "kidToday.day") { day in
                        selectedDay = day
                        tab = .week
                    }

                    if items.isEmpty {
                        emptyState
                    } else {
                        list
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
        let today = store.today
        return VStack(alignment: .leading, spacing: 0) {
            KidKicker(text: Text("\(WeekdayNames.full(today.isoWeekday)) · \(today.formattedDayAndMonth(in: store.timeZone))"))
            KidHeadline(text: headline)
                .padding(.top, 6)
            KidProgressBar(done: progress.done, total: progress.total)
                .padding(.top, 14)
        }
    }

    private var headline: Text {
        if progress.total == 0 { return Text("Nothing today") }
        if progress.done == progress.total { return Text("All done") }
        return Text("\(progress.done) of \(progress.total) done")
    }

    private var emptyState: some View {
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

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                ChoreRow(item: item, isEnabled: true) {
                    Task {
                        await store.setCompleted(
                            !item.isCompleted, chore: item.chore,
                            profileID: profile.id, on: store.today,
                            actor: profile.id)
                    }
                }
            }
        }
        // The store applies a tick asynchronously, so the reorder cannot be
        // wrapped in `withAnimation` at the tap; animate on the order instead.
        .animation(.snappy, value: items.map(\.id))
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
