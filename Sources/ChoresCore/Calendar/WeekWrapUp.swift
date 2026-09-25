import Foundation

/// Whether the week wrap-up card is due, and which week it reports on.
///
/// The card lives from Sunday 18:00 through the end of Monday, in the family's
/// time zone. Sunday reports the week that is ending; Monday reports the week
/// that has just ended — the same week, so the two moments share one `key` and
/// one dismissal.
///
/// A pure function over a clock, like `ScheduleResolver`: no store, no SwiftUI,
/// so every boundary is a unit test.
public struct WeekWrapUp: Equatable, Sendable {
    public enum Moment: Sendable {
        case sundayEvening
        case monday
    }

    public let moment: Moment
    /// The seven days reported on, Monday first.
    public let week: [CalendarDay]
    /// The reported ISO week, e.g. "2026-W39". What a dismissal remembers.
    public let key: String

    /// nil outside Sunday 18:00 … Monday 23:59:59 in `timeZone`.
    public static func current(now: Date, timeZone: TimeZone) -> WeekWrapUp? {
        let today = CalendarDay(now, in: timeZone)
        switch today.isoWeekday {
        case 7:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            // The hour as the family's clock shows it, so the Sunday the clocks
            // change is no different from any other.
            guard calendar.component(.hour, from: now) >= 18 else { return nil }
            return WeekWrapUp(moment: .sundayEvening, week: WeekCalendar.isoWeek(containing: today))
        case 1:
            return WeekWrapUp(moment: .monday, week: WeekCalendar.isoWeek(containing: today.adding(days: -7)))
        default:
            return nil
        }
    }

    private init(moment: Moment, week: [CalendarDay]) {
        self.moment = moment
        self.week = week
        self.key = Self.key(forWeekStarting: week[0])
    }

    /// ISO week-numbering year and week of `monday`, so the week that spans New
    /// Year keys by the year that owns it (2026-12-28 → "2026-W53").
    static func key(forWeekStarting monday: CalendarDay) -> String {
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = utc
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear],
                                                 from: monday.date(in: utc))
        return String(format: "%04d-W%02d", components.yearForWeekOfYear!, components.weekOfYear!)
    }

    // MARK: Copy rules

    /// Rounded to the nearest whole percent; 0 when nothing was scheduled.
    public static func percent(done: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(done) / Double(total) * 100).rounded())
    }

    /// The kid card's Monday line.
    public enum KidVerdict: Sendable {
        case complete, great, good, freshStart
    }

    /// Complete at 100 %, great from 80 %, good from 50 %, otherwise a fresh start.
    public static func kidVerdict(done: Int, total: Int) -> KidVerdict {
        guard total > 0 else { return .freshStart }
        if done == total { return .complete }
        let fraction = Double(done) / Double(total)
        if fraction >= 0.8 { return .great }
        if fraction >= 0.5 { return .good }
        return .freshStart
    }

    /// The colour of a child's percentage on the parent card.
    public enum Tone: Sendable {
        case complete, warn, neutral
    }

    /// Complete at 100 %, warn under 60 %, neutral otherwise — and neutral for
    /// a child with nothing scheduled, who shows no percentage at all.
    public static func tone(done: Int, total: Int) -> Tone {
        guard total > 0 else { return .neutral }
        if done == total { return .complete }
        return Double(done) / Double(total) < 0.6 ? .warn : .neutral
    }
}
