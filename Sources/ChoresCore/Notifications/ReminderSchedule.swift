import Foundation

/// One notification to schedule: which slot, on which day, at what time, and
/// how many of the child's chores are still open.
public struct ReminderPlan: Equatable, Sendable {
    public enum Slot: String, Sendable {
        /// "You have 2 chores today." — the heads-up.
        case afternoon
        /// "2 chores still unticked. Done them? Tick them off." — the nag.
        case evening
    }

    public let day: CalendarDay
    public let slot: Slot
    public let time: TimeOfDay
    public let remaining: Int

    public init(day: CalendarDay, slot: Slot, time: TimeOfDay, remaining: Int) {
        self.day = day
        self.slot = slot
        self.time = time
        self.remaining = remaining
    }
}

/// Works out which reminders a child's phone should have queued, kept here
/// rather than in the app target so the rules are testable without a simulator.
///
/// Pure: a snapshot and a clock in, dated plans out. The phone that runs this
/// is the one the child ticks on, so what it knows about completions is the
/// truth for its own child — except for a parent ticking on the child's behalf
/// before the phone next refreshes, which is the one gap the design accepts.
public enum ReminderSchedule {

    /// Two weeks: 28 notifications at most, under iOS's cap of 64, and long
    /// enough that a phone opened even weekly never runs dry.
    public static let horizonDays = 14

    /// Plans for the next `horizonDays` days starting today, in the family's
    /// timezone. A day contributes a plan per enabled slot when the child still
    /// has something open that day; today's slots whose time has passed are
    /// left out. Ordered by day, then afternoon before evening.
    public static func plans(for profileID: UUID,
                             snapshot: FamilySnapshot,
                             now: Date,
                             horizonDays: Int = horizonDays) -> [ReminderPlan] {
        guard let profile = snapshot.profiles.first(where: { $0.id == profileID }) else {
            return []
        }
        let timeZone = snapshot.family.timeZone
        let today = CalendarDay(now, in: timeZone)
        let wallClock = TimeOfDay(now, in: timeZone)
        let slots: [(ReminderPlan.Slot, TimeOfDay?)] = [
            (.afternoon, profile.afternoonReminderAt),
            (.evening, profile.eveningReminderAt),
        ]

        var plans: [ReminderPlan] = []
        for offset in 0..<horizonDays {
            let day = today.adding(days: offset)
            let remaining = ScheduleResolver.chores(
                for: profileID, on: day, template: snapshot.template,
                chores: snapshot.chores, completions: snapshot.completions)
                .filter { !$0.isCompleted }.count
            guard remaining > 0 else { continue }

            for (slot, time) in slots {
                guard let time else { continue }
                // A reminder for this very minute would fire late or never;
                // one for a minute that has gone is noise.
                if offset == 0 && !(wallClock < time) { continue }
                plans.append(ReminderPlan(day: day, slot: slot, time: time, remaining: remaining))
            }
        }
        return plans
    }
}
