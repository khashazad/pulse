/// Date coding helpers for the wire format shared with the FastAPI backend.
/// Provides a `YYYY-MM-DD` formatter, a custom decoder helper for date-only
/// fields, and a `JSONDecoder` factory (`dietTrackerDefault`) that accepts
/// either date-only strings or ISO-8601 timestamps (with or without fractional
/// seconds). All networking code in the app decodes through this factory.
import Foundation

/// Namespace for date-only (`YYYY-MM-DD`) parsing and formatting.
enum DateOnly {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Decodes a single-value `YYYY-MM-DD` string from `decoder` into a `Date`.
    /// Inputs:
    ///   - decoder: the active `Decoder` whose single-value container holds the date string.
    /// Outputs: the parsed `Date` in the current time zone at midnight.
    /// Exceptions: `DecodingError.dataCorrupted` when the value is not a valid `YYYY-MM-DD` string.
    static func decode(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let date = formatter.date(from: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected YYYY-MM-DD, got '\(raw)'"
            )
        }
        return date
    }

    /// Formats a `Date` as a `YYYY-MM-DD` string in the current time zone.
    /// Inputs:
    ///   - date: the date to format.
    /// Outputs: the formatted date-only string.
    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}

/// `JSONDecoder` factory for diet-tracker wire format.
extension JSONDecoder {
    /// Builds a `JSONDecoder` that tolerates the date encodings the backend
    /// emits: `YYYY-MM-DD` first, then ISO-8601 with fractional seconds, then
    /// plain ISO-8601.
    /// Outputs: a configured `JSONDecoder` whose `dateDecodingStrategy` accepts
    /// any of the three formats; raw values that match none cause decoding to
    /// throw `DecodingError.dataCorrupted`.
    static func dietTrackerDefault() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            // Try date-only first
            if let date = DateOnly.formatter.date(from: raw) {
                return date
            }
            // Fall back to ISO-8601 with fractional seconds tolerance
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: raw) { return date }
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date format: '\(raw)'"
            )
        }
        return d
    }
}
