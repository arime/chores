import Foundation

/// A timezone-free calendar date. All day arithmetic in the app goes through this type
/// so that "today" is always a *local* day and never a UTC one.
public struct CalendarDay: Hashable, Sendable, Comparable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The local calendar day that `date` falls on in `timeZone`.
    public init(_ date: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: components.year!, month: components.month!, day: components.day!)
    }

    /// Midnight at the start of this day, in `timeZone`.
    public func date(in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)!
    }

    /// ISO 8601 weekday: 1 = Monday … 7 = Sunday.
    ///
    /// This deliberately differs from `Calendar.component(.weekday:)`, which is
    /// 1 = Sunday. The conversion is centralised here so nothing else has to think
    /// about it.
    public var isoWeekday: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        let weekday = calendar.component(.weekday, from: date(in: Self.utc))
        return weekday == 1 ? 7 : weekday - 1
    }

    /// Day arithmetic runs in UTC so that a DST transition — which can make a local
    /// day 23 or 25 hours long — cannot skew the result.
    public func adding(days: Int) -> CalendarDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        let shifted = calendar.date(byAdding: .day, value: days, to: date(in: Self.utc))!
        return CalendarDay(shifted, in: Self.utc)
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    private static let utc = TimeZone(identifier: "UTC")!
}

extension CalendarDay: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let parts = raw.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Expected YYYY-MM-DD, got \(raw)"))
        }
        self.init(year: year, month: month, day: day)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(format: "%04d-%02d-%02d", year, month, day))
    }
}

extension CalendarDay {
    /// e.g. "Monday 10 August". Rendered in the family's timezone and the device locale.
    public func formattedLong(in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter.string(from: date(in: timeZone))
    }

    /// e.g. "10 Aug".
    public func formattedShort(in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return formatter.string(from: date(in: timeZone))
    }
}
