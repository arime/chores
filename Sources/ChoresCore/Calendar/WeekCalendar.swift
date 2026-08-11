import Foundation

public enum WeekCalendar {
    /// The seven days of the ISO week containing `day`, Monday first.
    public static func isoWeek(containing day: CalendarDay) -> [CalendarDay] {
        let monday = day.adding(days: -(day.isoWeekday - 1))
        return (0..<7).map { monday.adding(days: $0) }
    }
}
