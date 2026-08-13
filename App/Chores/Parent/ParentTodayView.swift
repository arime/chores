import SwiftUI
import ChoresCore

/// The parent's at-a-glance screen: one section per child, each headed by a ring
/// showing how much of today is done.
struct ParentTodayView: View {
    let store: FamilyStore
    /// Recorded as `completed_by` when a parent ticks something off on a child's
    /// behalf, so the audit trail says who actually did it.
    let parent: Profile

    private var children: [Profile] { store.snapshot?.children ?? [] }

    var body: some View {
        NavigationStack {
            List {
                if store.isStale {
                    StaleBanner(fetchedAt: store.snapshot?.fetchedAt)
                }

                ForEach(children) { child in
                    Section {
                        let chores = store.chores(for: child.id, on: store.today)
                        if chores.isEmpty {
                            Text("Nothing today").foregroundStyle(.secondary)
                        }
                        ForEach(chores) { item in
                            // Today is completable by definition, so no eligibility
                            // check here — unlike the day detail behind the week grid.
                            ChoreRow(item: item, isEnabled: true) {
                                Task {
                                    await store.setCompleted(
                                        !item.isCompleted, chore: item.chore,
                                        profileID: child.id, on: store.today,
                                        actor: parent.id)
                                }
                            }
                        }
                    } header: {
                        let progress = store.progress(for: child.id, on: store.today)
                        HStack {
                            ProgressRing(done: progress.done, total: progress.total,
                                         color: Color(hexString: child.color))
                            Text(child.displayName).font(.headline)
                            Spacer()
                        }
                        .textCase(nil)
                    }
                }

                if children.isEmpty {
                    ContentUnavailableView("No children yet",
                                           systemImage: "person.2",
                                           description: Text("Add them under Manage → People."))
                }
            }
            .navigationTitle(store.today.formattedLong(in: store.timeZone))
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
        }
    }
}

/// Shown when the screen is rendering the cached snapshot because the last fetch
/// failed. Saying so beats silently showing data that may be hours old.
struct StaleBanner: View {
    let fetchedAt: Date?

    var body: some View {
        HStack {
            Image(systemName: "arrow.triangle.2.circlepath")
            VStack(alignment: .leading) {
                Text("Showing saved data").font(.footnote.bold())
                if let fetchedAt {
                    Text("Last updated \(fetchedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listRowBackground(Color.orange.opacity(0.15))
    }
}
