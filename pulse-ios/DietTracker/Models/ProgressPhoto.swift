/// Models for the progress-photos feature.
/// Defines the four-slot enum, server metadata DTO, single- and batch-pending
/// upload records used by the offline retry queue, a unified `QueuedUpload`
/// wrapper, and a `DateOnlyFormatter` helper for `YYYY-MM-DD` IDs/keys.
/// Consumed by the progress-photo views, capture session, and upload queue.
import Foundation

/// The four photo orientations captured per session.
enum ProgressPhotoSlot: String, CaseIterable, Codable, Hashable {
    case front, left, right, back

    var displayName: String {
        switch self {
        case .front: return "Front"
        case .left:  return "Left"
        case .right: return "Right"
        case .back:  return "Back"
        }
    }
}

/// Server-side metadata for one stored progress photo (date+slot uniquely identifies it).
struct ProgressPhotoMetadata: Codable, Hashable, Identifiable {
    let date: Date
    let slot: ProgressPhotoSlot
    let mime: String
    let bytes: Int
    let sha256: String
    let updatedAt: Date

    var id: String { "\(DateOnlyFormatter.string(from: date))-\(slot.rawValue)" }

    enum CodingKeys: String, CodingKey {
        case date, slot, mime, bytes, sha256
        case updatedAt = "updated_at"
    }
}

/// A single queued progress-photo upload awaiting retry, persisted on disk.
struct PendingUpload: Codable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    let slot: ProgressPhotoSlot
    let localPath: String
    var attemptCount: Int
    var nextAttemptAt: Date
}

/// A queued multi-slot batch upload (one date, multiple slots) awaiting retry.
struct PendingBatchUpload: Codable, Identifiable, Hashable {
    /// One slot+path pair inside a batch upload.
    struct Item: Codable, Hashable {
        let slot: ProgressPhotoSlot
        let localPath: String
    }
    let id: UUID
    let date: Date
    let items: [Item]
    var attemptCount: Int
    var nextAttemptAt: Date
}

/// Tagged union of the two pending-upload shapes the queue can hold.
enum QueuedUpload: Codable, Hashable {
    case single(PendingUpload)
    case batch(PendingBatchUpload)

    var id: UUID {
        switch self {
        case .single(let u): return u.id
        case .batch(let u): return u.id
        }
    }

    var nextAttemptAt: Date {
        switch self {
        case .single(let u): return u.nextAttemptAt
        case .batch(let u): return u.nextAttemptAt
        }
    }
}

/// Shared `YYYY-MM-DD` formatter used for date-keyed IDs and request paths.
enum DateOnlyFormatter {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    /// Formats a `Date` as a `YYYY-MM-DD` string.
    /// - Inputs:
    ///   - date: the date to format.
    /// - Outputs: the ISO-8601 full-date string.
    static func string(from date: Date) -> String { formatter.string(from: date) }

    /// Parses a `YYYY-MM-DD` string back into a `Date`.
    /// - Inputs:
    ///   - string: the ISO-8601 full-date string to parse.
    /// - Outputs: the parsed `Date`, or `nil` if the string is malformed.
    static func date(from string: String) -> Date? { formatter.date(from: string) }
}
