import Foundation

final class PhotoUploadQueue {
    private let fileURL: URL
    private var entries: [QueuedUpload]
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

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

    func enqueueSingle(_ upload: PendingUpload) throws {
        try mutate { $0.append(.single(upload)) }
    }

    func enqueueBatch(_ batch: PendingBatchUpload) throws {
        try mutate { $0.append(.batch(batch)) }
    }

    func allDue(now: Date) -> [QueuedUpload] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.nextAttemptAt <= now }
    }

    /// Earliest `nextAttemptAt` among entries scheduled strictly after `now`,
    /// used to wake the worker for backoff retries. Returns nil when the
    /// queue is empty or contains no future-scheduled work.
    func nextDueDate(after now: Date) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return entries.map { $0.nextAttemptAt }.filter { $0 > now }.min()
    }

    func markSuccess(id: UUID) throws {
        try mutate { $0.removeAll { $0.id == id } }
    }

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

    static func backoffSeconds(attempt: Int) -> TimeInterval {
        let ladder: [TimeInterval] = [5, 30, 120, 600, 3600]
        let i = min(max(attempt - 1, 0), ladder.count - 1)
        return ladder[i]
    }

    private func mutate(_ apply: (inout [QueuedUpload]) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        apply(&entries)
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }
}
