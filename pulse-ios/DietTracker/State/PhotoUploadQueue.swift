/// PhotoUploadQueue: durable on-disk queue of pending progress-photo uploads.
/// Persists single + batch upload records to a JSON file, supports due-time
/// scheduling with exponential backoff, and serializes all mutations under a lock.
/// Role: storage layer used by ProgressPhotoStore's worker loop.
import Foundation

/// Thread-safe persistent queue for pending single and batch progress-photo uploads.
final class PhotoUploadQueue {
    private let fileURL: URL
    private var entries: [QueuedUpload]
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Initializes the queue, loading any persisted entries from disk.
    /// Inputs:
    ///   - fileURL: location of the JSON backing file (created on first write).
    init(fileURL: URL) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? decoder.decode([QueuedUpload].self, from: data) {
            self.entries = loaded
        } else {
            self.entries = []
        }
    }

    /// Appends a single-slot upload to the queue and persists.
    /// Inputs:
    ///   - upload: pending single upload to enqueue.
    /// Exceptions: rethrows errors from JSON encoding or atomic disk write.
    func enqueueSingle(_ upload: PendingUpload) throws {
        try mutate { $0.append(.single(upload)) }
    }

    /// Appends a multi-slot batch upload to the queue and persists.
    /// Inputs:
    ///   - batch: pending batch upload to enqueue.
    /// Exceptions: rethrows errors from JSON encoding or atomic disk write.
    func enqueueBatch(_ batch: PendingBatchUpload) throws {
        try mutate { $0.append(.batch(batch)) }
    }

    /// Returns every entry whose `nextAttemptAt` has elapsed.
    /// Inputs:
    ///   - now: reference instant used for the comparison.
    /// Outputs: due entries, in queue order.
    func allDue(now: Date) -> [QueuedUpload] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.nextAttemptAt <= now }
    }

    /// Earliest `nextAttemptAt` among entries scheduled strictly after `now`,
    /// used to wake the worker for backoff retries. Returns nil when the
    /// queue is empty or contains no future-scheduled work.
    /// Inputs:
    ///   - now: reference instant; only entries with `nextAttemptAt > now` are considered.
    /// Outputs: the soonest future attempt time, or nil if none.
    func nextDueDate(after now: Date) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return entries.map { $0.nextAttemptAt }.filter { $0 > now }.min()
    }

    /// Removes the entry with the given id (call after a successful upload).
    /// Inputs:
    ///   - id: queued upload identifier.
    /// Exceptions: rethrows errors from JSON encoding or atomic disk write.
    func markSuccess(id: UUID) throws {
        try mutate { $0.removeAll { $0.id == id } }
    }

    /// Increments the attempt count and schedules the next retry using exponential backoff.
    /// Inputs:
    ///   - id: queued upload identifier.
    ///   - now: reference instant used to compute `nextAttemptAt` (defaults to now).
    /// Exceptions: rethrows errors from JSON encoding or atomic disk write.
    func markFailure(id: UUID, now: Date = Date()) throws {
        try mutate { list in
            guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
            switch list[idx] {
            case .single(var u):
                u.attemptCount += 1
                u.nextAttemptAt = now.addingTimeInterval(Self.backoffSeconds(attempt: u.attemptCount))
                list[idx] = .single(u)
            case .batch(var b):
                b.attemptCount += 1
                b.nextAttemptAt = now.addingTimeInterval(Self.backoffSeconds(attempt: b.attemptCount))
                list[idx] = .batch(b)
            }
        }
    }

    /// Backoff schedule for upload retries: 5s, 30s, 2m, 10m, 1h (then clamped at 1h).
    /// Inputs:
    ///   - attempt: 1-based attempt number.
    /// Outputs: seconds to wait before the next attempt.
    static func backoffSeconds(attempt: Int) -> TimeInterval {
        let ladder: [TimeInterval] = [5, 30, 120, 600, 3600]
        let i = min(max(attempt - 1, 0), ladder.count - 1)
        return ladder[i]
    }

    /// Runs `apply` under the lock against the in-memory entries, then atomically writes them to disk.
    /// Inputs:
    ///   - apply: closure mutating the entries array.
    /// Exceptions: rethrows errors from JSON encoding or atomic disk write.
    private func mutate(_ apply: (inout [QueuedUpload]) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        apply(&entries)
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }
}
