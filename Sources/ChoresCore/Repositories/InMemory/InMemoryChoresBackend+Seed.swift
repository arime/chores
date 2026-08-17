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
