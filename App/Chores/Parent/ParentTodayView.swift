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
                            HStack {
                                Image(systemName: item.isCompleted
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.isCompleted ? .green : .secondary)
                                Text(item.chore.name)
                                    .strikethrough(item.isCompleted)
                                    .foregroundStyle(item.isCompleted ? .secondary : .primary)
                            }
                            .swipeActions {
                                if item.isCompleted {
                                    Button("Undo") {
                                        Task {
                                            await store.setCompleted(
                                                false, chore: item.chore, profileID: child.id,
                                                on: store.today, actor: parent.id)
                                        }
                                    }
                                    .tint(.orange)
                                } else {
                                    Button("Mark done") {
                                        Task {
                                            await store.setCompleted(
                                                true, chore: item.chore, profileID: child.id,
                                                on: store.today, actor: parent.id)
                                        }
                                    }
                                    .tint(.green)
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
                                           description: Text("Add them under Manage → Children."))
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
