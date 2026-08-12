import SwiftUI
import ChoresCore

/// Day-first, mirroring how the requirement was described: "on Monday child A
/// does X and Y". A 7-day by 3-child grid does not fit a phone.
struct ScheduleEditorView: View {
    let store: FamilyStore
    let backend: any ChoresBackend

    @State private var selectedWeekday = 1
    @State private var assigningTo: Profile?
    @State private var isCopying = false
    @State private var copyTargets: Set<Int> = []
    @State private var errorMessage: String?

    private var children: [Profile] { store.snapshot?.children ?? [] }
    private var chores: [Chore] { store.snapshot?.activeChores ?? [] }

    private func entries(for child: Profile) -> [(entry: ScheduleEntry, chore: Chore)] {
        guard let snapshot = store.snapshot else { return [] }
        var byID: [UUID: Chore] = [:]
        for chore in snapshot.chores { byID[chore.id] = chore }

        return snapshot.template
            .filter { $0.profileID == child.id && $0.weekday == selectedWeekday }
            .compactMap { entry in
                guard let chore = byID[entry.choreID], !chore.isArchived else { return nil }
                return (entry, chore)
            }
            .sorted { $0.chore.name.localizedStandardCompare($1.chore.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Day", selection: $selectedWeekday) {
                ForEach(1...7, id: \.self) { weekday in
                    Text(WeekdayNames.short(weekday)).tag(weekday)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .accessibilityIdentifier("schedule.dayPicker")

            List {
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }

                ForEach(children) { child in
                    Section {
                        ForEach(entries(for: child), id: \.entry.id) { pair in
                            Text(pair.chore.name)
                                .swipeActions {
                                    Button("Remove", role: .destructive) {
                                        Task { await remove(pair.entry) }
                                    }
                                }
                        }
                        Button("Add chore") { assigningTo = child }
                            .font(.callout)
                            .accessibilityIdentifier("schedule.add.\(child.displayName)")
                    } header: {
                        HStack {
                            Circle()
                                .fill(Color(hexString: child.color))
                                .frame(width: 10, height: 10)
                            Text(child.displayName)
                        }
                    }
                }

                if children.isEmpty {
                    Section {
                        Text("Add a child under Manage → Children first.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Copy \(WeekdayNames.full(selectedWeekday)) to…") {
                        copyTargets = []
                        isCopying = true
                    }
                    .disabled(children.isEmpty)
                    .accessibilityIdentifier("schedule.copyDay")
                } footer: {
                    Text("Copying replaces everything already assigned on the target days.")
                }
            }
        }
        .navigationTitle("Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $assigningTo) { child in
            AssignChoreSheet(
                child: child,
                chores: chores,
                alreadyAssigned: Set(entries(for: child).map(\.chore.id))
            ) { chore in
                await assign(chore, to: child)
            }
        }
        .sheet(isPresented: $isCopying) { copySheet }
    }

    private var copySheet: some View {
        NavigationStack {
            List {
                Section("Copy to") {
                    ForEach(1...7, id: \.self) { weekday in
                        if weekday != selectedWeekday {
                            Button {
                                if copyTargets.contains(weekday) {
                                    copyTargets.remove(weekday)
                                } else {
                                    copyTargets.insert(weekday)
                                }
                            } label: {
                                HStack {
                                    Text(WeekdayNames.full(weekday))
                                    Spacer()
                                    if copyTargets.contains(weekday) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            .tint(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Copy \(WeekdayNames.full(selectedWeekday))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isCopying = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy") { Task { await copy() } }
                        .disabled(copyTargets.isEmpty)
                }
            }
        }
    }

    private func assign(_ chore: Chore, to child: Profile) async {
        guard let familyID = store.snapshot?.family.id else { return }
        do {
            _ = try await backend.addScheduleEntry(
                familyID: familyID, profileID: child.id, choreID: chore.id,
                weekday: selectedWeekday)
            errorMessage = nil
            await store.reloadAfterEdit()
        } catch {
            errorMessage = "Couldn't assign \(chore.name). Check your connection and try again."
        }
    }

    private func remove(_ entry: ScheduleEntry) async {
        do {
            try await backend.removeScheduleEntry(id: entry.id)
            errorMessage = nil
            await store.reloadAfterEdit()
        } catch {
            errorMessage = "Couldn't remove that chore. Check your connection and try again."
        }
    }

    private func copy() async {
        guard let familyID = store.snapshot?.family.id else { return }
        do {
            try await backend.copyDay(familyID: familyID, from: selectedWeekday,
                                      to: Array(copyTargets))
            errorMessage = nil
            isCopying = false
            await store.reloadAfterEdit()
        } catch {
            isCopying = false
            errorMessage = "Couldn't copy the day. Check your connection and try again."
        }
    }
}
