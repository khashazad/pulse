/// Models for the progress-photos feature.
/// Defines `ProgressPhotoTag` (user-defined tag rows), `ProgressPhotoMetadata`
/// (server metadata for one stored photo, keyed by photo id), the pending-
/// upload record persisted by the offline retry queue, and a `DateOnlyFormatter`
/// helper for `YYYY-MM-DD` IDs/keys. Consumed by the progress-photo views,
/// capture session, stores, and upload queue.
import Foundation

/// A user-defined progress-photo tag (e.g. "front", "morning", "flexed").
struct ProgressPhotoTag: Codable, Hashable, Identifiable {
    let id: UUID
    let name: String
    let normalizedName: String
    let sortOrder: Int
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name
        case normalizedName = "normalized_name"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Server-side metadata for one stored progress photo.
struct ProgressPhotoMetadata: Codable, Hashable, Identifiable {
    let id: UUID
    let date: Date
    let tagId: UUID
    let mime: String
    let bytes: Int
    let sha256: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, date, mime, bytes, sha256
        case tagId = "tag_id"
        case updatedAt = "updated_at"
    }
}

/// A single queued progress-photo upload awaiting retry, persisted on disk.
struct PendingUpload: Codable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    let tagId: UUID
    let localPath: String
    var attemptCount: Int
    var nextAttemptAt: Date
}

/// Tagged union wrapper for the queue. Kept around so the on-disk JSON schema
/// can evolve in the future without breaking the worker loop.
enum QueuedUpload: Codable, Hashable {
    case single(PendingUpload)

    var id: UUID {
        switch self {
        case .single(let u): return u.id
        }
    }

    var nextAttemptAt: Date {
        switch self {
        case .single(let u): return u.nextAttemptAt
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
    static func string(from date: Date) -> String { formatter.string(from: date) }

    /// Parses a `YYYY-MM-DD` string back into a `Date`.
    static func date(from string: String) -> Date? { formatter.date(from: string) }
}
