import SwiftUI
import ChoresCore

struct KidTodayView: View {
    let store: FamilyStore
    let profile: Profile

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
        NavigationStack {
            List {
                if store.isStale {
                    StaleBanner(fetchedAt: store.snapshot?.fetchedAt)
                }

                if items.isEmpty {
                    ContentUnavailableView("Nothing today",
                                           systemImage: "checkmark.circle",
                                           description: Text("Enjoy it."))
                } else {
                    Section {
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
                    } header: {
                        HStack {
                            Text("\(progress.done) of \(progress.total) done")
                                .font(.subheadline.bold())
                                .monospacedDigit()
                            Spacer()
                        }
                        .textCase(nil)
                    }
                }
            }
            .navigationTitle(store.today.formattedLong(in: store.timeZone))
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
        }
    }
}
