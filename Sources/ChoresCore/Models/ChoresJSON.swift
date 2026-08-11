import Foundation

/// Shared JSON coders for everything that crosses the PostgREST boundary.
///
/// PostgREST emits ISO-8601 timestamps sometimes with fractional seconds and
/// sometimes without, so both are accepted on the way in.
public enum ChoresJSON {

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = iso8601WithFraction.date(from: raw) { return date }
            if let date = iso8601.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Unparseable timestamp \(raw)"))
        }
        return decoder
    }()

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601WithFraction.string(from: date))
        }
        return encoder
    }()

    /// A `CalendarDay` rendered for use as a PostgREST filter value.
    public static func encodedDay(_ day: CalendarDay) -> String {
        String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
