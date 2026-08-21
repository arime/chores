import Foundation

extension InMemoryChoresBackend {
    /// Seeds a family whose child is already claimed by this device's session.
    ///
    /// The real path to kid mode spans two devices — a parent generates a code,
    /// the child types it — which a single-process UI test cannot walk. This is
    /// the seam that lets one exist, and it doubles as preview data.
    ///
    /// Returns the child's profile.
    @discardableResult
    public func seedClaimedChild(familyName: String = "Koti",
                                 childName: String,
                                 choreNames: [String],
                                 onISOWeekdays weekdays: [Int]) -> Profile {
        let userID = UUID()
        sessionUserID = userID

        let family = Family(id: UUID(), name: familyName)
        let parent = Profile(id: UUID(), familyID: family.id, displayName: "Parent",
                             role: .parent)
        let child = Profile(id: UUID(), familyID: family.id, authUserID: userID,
                            displayName: childName, role: .child)
        let chores = choreNames.map { Chore(id: UUID(), familyID: family.id, name: $0) }

        withStore { store in
            store.families[family.id] = family
            store.profiles[parent.id] = parent
            store.profiles[child.id] = child
            for chore in chores { store.chores[chore.id] = chore }
            for weekday in weekdays {
                for chore in chores {
                    let entry = ScheduleEntry(id: UUID(), familyID: family.id,
                                              profileID: child.id, choreID: chore.id,
                                              weekday: weekday)
                    store.template[entry.id] = entry
                }
            }
        }
        return child
    }

    /// Seeds a family that looks lived-in: several children, a full week of
    /// chores, and a history of ticking them off.
    ///
    /// This exists for the App Store screenshots. The other seeds above are built
    /// for assertions and are deliberately bare — two chores and one child make a
    /// readable test and a listing nobody would install. `tools/screenshots.sh`
    /// drives this one.
    ///
    /// The shape of what it produces, which is what the screenshots are of:
    ///
    /// - Every child has three chores on every weekday, taken from `choreNames`
    ///   in turn, so a child's day is a short list rather than one item.
    /// - Every earlier day of the current week is fully done, so the parent's
    ///   week grid is a wall of progress rather than an empty table.
    /// - Today is partly done, and differently per child: the first is finished,
    ///   the second is halfway, the rest have not started. A progress ring is
    ///   worth showing at three different fills.
    ///
    /// `claimingChildAt` decides which side of the app the launch lands on: an
    /// index claims that child, so the device is in kid mode; nil claims the
    /// parent instead.
    ///
    /// Returns the claimed profile.
    @discardableResult
    public func seedDemoFamily(familyName: String,
                               parentName: String,
                               childNames: [String],
                               childColors: [String],
                               choreNames: [String],
                               today: CalendarDay,
                               claimingChildAt claimedChildIndex: Int?) -> Profile {
        precondition(!childNames.isEmpty && !choreNames.isEmpty,
                     "a demo family needs at least one child and one chore")

        let userID = UUID()
        sessionUserID = userID
        sessionIsAnonymous = claimedChildIndex != nil

        let family = Family(id: UUID(), name: familyName)
        let parent = Profile(id: UUID(), familyID: family.id,
                             authUserID: claimedChildIndex == nil ? userID : nil,
                             displayName: parentName, role: .parent)
        let children = childNames.enumerated().map { index, name in
            Profile(id: UUID(), familyID: family.id,
                    authUserID: index == claimedChildIndex ? userID : nil,
                    displayName: name, role: .child,
                    color: childColors.isEmpty
                        ? "#4C8BF5"
                        : childColors[index % childColors.count],
                    sortOrder: index)
        }
        let chores = choreNames.map { Chore(id: UUID(), familyID: family.id, name: $0) }

        /// Three chores per child per day, walking `chores` so that two children
        /// rarely share a day's list — the same chore landing on two children is
        /// allowed, both here and in the database.
        func assignment(for childIndex: Int) -> [Chore] {
            (0..<min(3, chores.count)).map { chores[(childIndex * 3 + $0) % chores.count] }
        }

        // Monday of the current ISO week, which is where the week grid starts.
        let monday = today.adding(days: -(today.isoWeekday - 1))

        withStore { store in
            store.families[family.id] = family
            store.profiles[parent.id] = parent
            for child in children { store.profiles[child.id] = child }
            for chore in chores { store.chores[chore.id] = chore }

            for (childIndex, child) in children.enumerated() {
                let assigned = assignment(for: childIndex)
                for weekday in 1...7 {
                    for chore in assigned {
                        let entry = ScheduleEntry(id: UUID(), familyID: family.id,
                                                  profileID: child.id, choreID: chore.id,
                                                  weekday: weekday)
                        store.template[entry.id] = entry
                    }
                }

                for dayOffset in 0..<today.isoWeekday {
                    let day = monday.adding(days: dayOffset)
                    let isToday = day == today
                    // Earlier days: all of them. Today: all for the first child,
                    // the first chore for the second, none for anyone else.
                    let doneCount: Int
                    switch (isToday, childIndex) {
                    case (false, _): doneCount = assigned.count
                    case (true, 0): doneCount = assigned.count
                    case (true, 1): doneCount = 1
                    case (true, _): doneCount = 0
                    }

                    for chore in assigned.prefix(doneCount) {
                        store.completions.append(Completion(
                            id: UUID(), familyID: family.id, profileID: child.id,
                            choreID: chore.id, dueOn: day,
                            completedAt: day.date(in: family.timeZone),
                            completedBy: child.id))
                    }
                }
            }
        }

        return claimedChildIndex.map { children[$0] } ?? parent
    }

    /// Marks the device as already claimed anonymously, with no profile — the
    /// state a device is in once its profile is removed elsewhere, which is
    /// what `LostSessionView` exists for.
    ///
    /// The real path there is `signInAnonymously()`, called at launch when
    /// `currentIdentity()` comes back `.none`. That is async, and `AppEnvironment`'s
    /// `-ui-testing-lost-session` fixture builds its environment synchronously,
    /// before `RootView` ever reads state — so this seam sets the same fields
    /// `signInAnonymously()` would, without a suspension point to await.
    public func seedLostSession() {
        sessionUserID = UUID()
        sessionIsAnonymous = true
    }
}
