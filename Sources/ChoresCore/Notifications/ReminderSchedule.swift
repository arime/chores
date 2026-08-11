import Foundation

/// One day's worth of reminder: how many chores a child has on a given weekday.
public struct ReminderPlan: Equatable, Sendable {
    /// ISO weekday: 1 = Monday … 7 = Sunday.
    public let isoWeekday: Int
    public let choreCount: Int

    public init(isoWeekday: Int, choreCount: Int) {
        self.isoWeekday = isoWeekday
        self.choreCount = choreCount
    }
}

/// Works out which weekdays deserve a reminder, kept here rather than in the app
/// target so the rules are testable without a simulator.
public enum ReminderSchedule {

    /// One plan per weekday on which this child has at least one active chore,
    /// ordered Monday first. Days with nothing scheduled produce no notification
    /// at all — a reminder that says "0 chores today" is just noise.
    public static func plans(for profileID: UUID, snapshot: FamilySnapshot) -> [ReminderPlan] {
        let activeChoreIDs = Set(snapshot.chores.filter { !$0.isArchived }.map(\.id))

        var countsByWeekday: [Int: Int] = [:]
        for entry in snapshot.template
        where entry.profileID == profileID && activeChoreIDs.contains(entry.choreID) {
            countsByWeekday[entry.weekday, default: 0] += 1
        }

        return countsByWeekday
            .sorted { $0.key < $1.key }
            .map { ReminderPlan(isoWeekday: $0.key, choreCount: $0.value) }
    }
}
