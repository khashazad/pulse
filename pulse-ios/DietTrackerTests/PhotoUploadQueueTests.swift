/// Unit tests for `PhotoUploadQueue`, the on-disk retry queue used by the
/// progress-photo upload pipeline.
/// Covers enqueue + persist semantics for both single uploads and batches,
/// success-removal, failure-with-backoff scheduling, the escalating
/// backoff schedule, and that a fresh queue instance rehydrates pending
/// items from disk.
/// Part of the iOS app's progress-photo test suite.
import XCTest
@testable import DietTracker

final class PhotoUploadQueueTests: XCTestCase {

    /// Creates a fresh `PhotoUploadQueue` backed by a temporary file.
    /// Outputs: tuple of `(queue, file URL)`; caller uses the URL to make a
    /// second queue instance for persistence checks.
    /// Exceptions: throws if the temp directory cannot be created.
    private func tempQueue() throws -> (PhotoUploadQueue, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("queuetest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("pending_uploads.json")
        return (PhotoUploadQueue(fileURL: file), file)
    }

    /// Verifies enqueuing a single upload writes the JSON file and a fresh
    /// queue instance reading the same path sees it as due.
    func testEnqueueSinglePersists() throws {
        let (q, file) = try tempQueue()
        let upload = PendingUpload(
            id: UUID(),
            date: Date(),
            slot: .front,
            localPath: "/tmp/x.jpg",
            attemptCount: 0,
            nextAttemptAt: Date()
        )
        try q.enqueueSingle(upload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let q2 = PhotoUploadQueue(fileURL: file)
        XCTAssertEqual(q2.allDue(now: Date().addingTimeInterval(60)).count, 1)
    }

    /// Verifies `markSuccess` removes the entry from the queue.
    func testMarkSuccessRemovesEntry() throws {
        let (q, _) = try tempQueue()
        let id = UUID()
        let upload = PendingUpload(
            id: id, date: Date(), slot: .front, localPath: "/tmp/x.jpg",
            attemptCount: 0, nextAttemptAt: Date()
        )
        try q.enqueueSingle(upload)
        try q.markSuccess(id: id)
        XCTAssertTrue(q.allDue(now: Date().addingTimeInterval(60)).isEmpty)
    }

    /// Verifies `markFailure` pushes the entry into the future so it is not
    /// returned by `allDue(now:)` at the failure time but is returned later.
    func testMarkFailureSchedulesBackoff() throws {
        let (q, _) = try tempQueue()
        let id = UUID()
        let upload = PendingUpload(
            id: id, date: Date(), slot: .front, localPath: "/tmp/x.jpg",
            attemptCount: 0, nextAttemptAt: Date()
        )
        try q.enqueueSingle(upload)
        let before = Date()
        try q.markFailure(id: id, now: before)
        XCTAssertTrue(q.allDue(now: before).isEmpty)
        XCTAssertEqual(q.allDue(now: before.addingTimeInterval(10)).count, 1)
    }

    /// Verifies the exponential backoff schedule for attempts 1..6 and that
    /// it caps at 3600 seconds.
    func testBackoffIntervalsEscalate() throws {
        XCTAssertEqual(PhotoUploadQueue.backoffSeconds(attempt: 1), 5)
        XCTAssertEqual(PhotoUploadQueue.backoffSeconds(attempt: 2), 30)
        XCTAssertEqual(PhotoUploadQueue.backoffSeconds(attempt: 3), 120)
        XCTAssertEqual(PhotoUploadQueue.backoffSeconds(attempt: 4), 600)
        XCTAssertEqual(PhotoUploadQueue.backoffSeconds(attempt: 5), 3600)
        XCTAssertEqual(PhotoUploadQueue.backoffSeconds(attempt: 6), 3600)
    }

    /// Verifies enqueuing a batch persists it and a fresh queue rehydrates it.
    func testEnqueueBatchPersists() throws {
        let (q, file) = try tempQueue()
        let batch = PendingBatchUpload(
            id: UUID(),
            date: Date(),
            items: [.init(slot: .front, localPath: "/tmp/f.jpg")],
            attemptCount: 0,
            nextAttemptAt: Date()
        )
        try q.enqueueBatch(batch)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let q2 = PhotoUploadQueue(fileURL: file)
        XCTAssertEqual(q2.allDue(now: Date().addingTimeInterval(60)).count, 1)
    }
}
