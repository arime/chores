import Foundation

enum WeekdayNames {
    /// `isoWeekday` is 1 = Monday … 7 = Sunday, whereas `DateFormatter`'s symbol
    /// arrays are indexed 0 = Sunday. Hence the shift.
    private static func index(_ isoWeekday: Int) -> Int { isoWeekday % 7 }

    static func short(_ isoWeekday: Int) -> String {
        DateFormatter().shortStandaloneWeekdaySymbols[index(isoWeekday)].capitalized
    }

    static func full(_ isoWeekday: Int) -> String {
        DateFormatter().standaloneWeekdaySymbols[index(isoWeekday)].capitalized
    }
}
