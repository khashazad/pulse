import Foundation

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

struct PendingUpload: Codable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    let slot: ProgressPhotoSlot
    let localPath: String
    var attemptCount: Int
    var nextAttemptAt: Date
}

struct PendingBatchUpload: Codable, Identifiable, Hashable {
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

enum DateOnlyFormatter {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
    static func string(from date: Date) -> String { formatter.string(from: date) }
    static func date(from string: String) -> Date? { formatter.date(from: string) }
}
