import SwiftUI
import ChoresCore

/// Day-first, mirroring how the requirement was described: "on Monday child A
/// does X and Y". A 7-day by 3-child grid does not fit a phone.
///
/// A `List` rather than a scroll view, because removing an entry is a swipe.
struct ScheduleEditorView: View {
    let store: FamilyStore
    let backend: any ChoresBackend

    @State private var selectedWeekday = 1
    @State private var assigningTo: Profile?
    @State private var isCopying = false
    @State private var errorMessage: String?

    private var children: [Profile] { store.snapshot?.children ?? [] }
    private var chores: [Chore] { store.snapshot?.activeChores ?? [] }
    private var dayName: String { WeekdayNames.full(selectedWeekday) }

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
        List {
            BackButton(label: Text("Manage"))
                .padding(.leading, -6)
                .nocturneRow()

            ScreenHeader(kicker: Text("Manage"), title: Text("Schedule"))
                .padding(.top, 4)
                .padding(.bottom, Theme.blockGap)
                .nocturneRow()

            dayPicker
                .padding(.bottom, Theme.blockGap)
                .nocturneRow()

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.danger)
                    .padding(.bottom, 12)
                    .nocturneRow()
            }

            ForEach(children) { child in
                HStack(spacing: 8) {
                    Circle()
                        .fill(ChildHue(hex: child.color).base)
                        .frame(width: 8, height: 8)
                    Text(child.displayName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.text)
                }
                .frame(minHeight: 32)
                .nocturneRow()

                let assigned = entries(for: child)
                ForEach(assigned, id: \.entry.id) { pair in
                    Text(pair.chore.name)
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.text)
                        .ruledRow(minHeight: 50)
                        .swipeActions {
                            Button("Remove", role: .destructive) {
                                Task { await remove(pair.entry) }
                            }
                        }
                        .nocturneRow()
                }

                if assigned.isEmpty {
                    Text("Nothing on \(dayName).")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.neutral500)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                        .padding(.horizontal, 2)
                        .nocturneRow()
                }

                AddRow(label: Text("Add chore"), minHeight: 44) { assigningTo = child }
                    .padding(.bottom, Theme.blockGap)
                    .accessibilityIdentifier("schedule.add.\(child.displayName)")
                    .nocturneRow()
            }

            if children.isEmpty {
                Text("Add a child under Manage → People first.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.neutral500)
                    .padding(.bottom, Theme.blockGap)
                    .nocturneRow()
            }

            VStack(alignment: .leading, spacing: 8) {
                Button("Copy \(dayName) to…") { isCopying = true }
                    .buttonStyle(.primary)
                    .disabled(children.isEmpty)
                    .accessibilityIdentifier("schedule.copyDay")
                Footnote(text: Text("Copying replaces everything already assigned on the target days."))
            }
            .padding(.bottom, 40)
            .nocturneRow()
        }
        .nocturneList()
        .nocturneNavigation()
        .sheet(item: $assigningTo) { child in
            AssignChoreSheet(
                child: child,
                chores: chores,
                alreadyAssigned: Set(entries(for: child).map(\.chore.id))
            ) { chore in
                await assign(chore, to: child)
            }
        }
        .sheet(isPresented: $isCopying) {
            CopyDaySheet(sourceWeekday: selectedWeekday) { targets in
                await copy(to: targets)
            }
        }
    }

    /// Seven equal cells in a surface track. Replaces the system segmented
    /// control, whose chrome has no place on this ground.
    private var dayPicker: some View {
        HStack(spacing: 4) {
            ForEach(1...7, id: \.self) { weekday in
                let isSelected = weekday == selectedWeekday
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedWeekday = weekday }
                } label: {
                    Text(WeekdayNames.short(weekday))
                        .font(.system(size: 12))
                        .tracking(12 * 0.02)
                        .foregroundStyle(isSelected ? Theme.text : Theme.neutral500)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 34)
                        .background {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected ? Theme.neutral800 : .clear)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("schedule.day.\(weekday)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(Theme.surface)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("schedule.dayPicker")
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
            errorMessage = String(localized: "Couldn't assign \(chore.name). Check your connection and try again.")
        }
    }

    private func remove(_ entry: ScheduleEntry) async {
        do {
            try await backend.removeScheduleEntry(id: entry.id)
            errorMessage = nil
            await store.reloadAfterEdit()
        } catch {
            errorMessage = String(localized: "Couldn't remove that chore. Check your connection and try again.")
        }
    }

    private func copy(to targets: Set<Int>) async {
        guard let familyID = store.snapshot?.family.id else { return }
        do {
            try await backend.copyDay(familyID: familyID, from: selectedWeekday,
                                      to: Array(targets))
            errorMessage = nil
            isCopying = false
            await store.reloadAfterEdit()
        } catch {
            isCopying = false
            errorMessage = String(localized: "Couldn't copy the day. Check your connection and try again.")
        }
    }
}

/// Pick the days a day's assignments should be copied onto.
struct CopyDaySheet: View {
    let sourceWeekday: Int
    let onCopy: (Set<Int>) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var targets: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(onCancel: { dismiss() },
                        title: Text("Copy \(WeekdayNames.full(sourceWeekday))")) {
                SheetPrimaryButton(title: Text("Copy"), isEnabled: !targets.isEmpty) {
                    Task { await onCopy(targets) }
                }
            }
            .padding(.bottom, Theme.blockGap)

            Kicker(text: Text("Copy to"))
                .padding(.bottom, 4)

            ForEach(1...7, id: \.self) { weekday in
                if weekday != sourceWeekday {
                    dayRow(weekday)
                }
            }
        }
        .nocturneSheet()
    }

    private func dayRow(_ weekday: Int) -> some View {
        let isChecked = targets.contains(weekday)
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isChecked { targets.remove(weekday) } else { targets.insert(weekday) }
            }
        } label: {
            HStack {
                Text(WeekdayNames.full(weekday))
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                ZStack {
                    Circle().fill(isChecked ? Theme.accent : .clear)
                    Circle().strokeBorder(isChecked ? Theme.accent : Theme.neutral600, lineWidth: 1.5)
                    if isChecked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.bg)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 22, height: 22)
            }
            .ruledRow(minHeight: 50, verticalPadding: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChecked ? .isSelected : [])
    }
}
