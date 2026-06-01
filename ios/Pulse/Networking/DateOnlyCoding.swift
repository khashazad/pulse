/// Date coding helpers for the wire format shared with the FastAPI backend.
/// Provides a `YYYY-MM-DD` formatter, a custom decoder helper for date-only
/// fields, and a `JSONDecoder` factory (`pulseDefault`) that accepts
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

    /// Formatter for naive wall-clock datetimes (`yyyy-MM-dd'T'HH:mm:ss`, no
    /// timezone designator) in the device's current time zone. Used when
    /// encoding `consumed_at` for write requests: the server reads the literal
    /// wall-clock value to derive the owning calendar day, so the string must
    /// carry no offset.
    static let wallClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
}

/// `JSONEncoder` factory for diet-tracker wire format.
extension JSONEncoder {
    /// Builds a `JSONEncoder` whose `dateEncodingStrategy` emits naive
    /// wall-clock datetimes (`yyyy-MM-dd'T'HH:mm:ss`, current time zone, no
    /// offset). This matches what the backend expects for `consumed_at`: a
    /// timezone-less value it interprets as wall-clock in its configured zone
    /// to resolve the owning daily-log date. All request bodies carrying a
    /// `Date` should encode through this factory.
    /// Outputs: a configured `JSONEncoder` for diet-tracker request bodies.
    static func pulseDefault() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .formatted(DateOnly.wallClockFormatter)
        return e
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
    static func pulseDefault() -> JSONDecoder {
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
