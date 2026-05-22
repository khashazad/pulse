/// Unit tests for `PhotoUploadQueue`, the on-disk retry queue used by the
/// progress-photo upload pipeline.
/// Covers enqueue + persist semantics, success-removal, failure-with-backoff
/// scheduling, the escalating backoff schedule, and that a fresh queue
/// instance rehydrates pending items from disk.
import XCTest
@testable import Pulse

final class PhotoUploadQueueTests: XCTestCase {

    private var createdDirs: [URL] = []

    private func tempQueue() throws -> (PhotoUploadQueue, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("queuetest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        createdDirs.append(dir)
        let file = dir.appendingPathComponent("pending_uploads.json")
        return (PhotoUploadQueue(fileURL: file), file)
    }

    override func tearDown() {
        for dir in createdDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        createdDirs = []
        super.tearDown()
    }

    func testEnqueueSinglePersists() throws {
        let (q, file) = try tempQueue()
        let upload = PendingUpload(
            id: UUID(),
            date: Date(),
            tagId: UUID(),
            localPath: "/tmp/x.jpg",
            attemptCount: 0,
            nextAttemptAt: Date()
        )
        try q.enqueueSingle(upload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let q2 = PhotoUploadQueue(fileURL: file)
        XCTAssertEqual(q2.allDue(now: Date().addingTimeInterval(60)).count, 1)
    }

    func testMarkSuccessRemovesEntry() throws {
        let (q, _) = try tempQueue()
        let id = UUID()
        let upload = PendingUpload(
            id: id, date: Date(), tagId: UUID(), localPath: "/tmp/x.jpg",
            attemptCount: 0, nextAttemptAt: Date()
        )
        try q.enqueueSingle(upload)
        try q.markSuccess(id: id)
        XCTAssertTrue(q.allDue(now: Date().addingTimeInterval(60)).isEmpty)
    }

    func testMarkFailureSchedulesBackoff() throws {
        let (q, _) = try tempQueue()
        let id = UUID()
        let upload = PendingUpload(
            id: id, date: Date(), tagId: UUID(), localPath: "/tmp/x.jpg",
            attemptCount: 0, nextAttemptAt: Date()
        )
        try q.enqueueSingle(upload)
        let before = Date()
        try q.markFailure(id: id, now: before)
        XCTAssertTrue(q.allDue(now: before).isEmpty)
        XCTAssertEqual(q.allDue(now: before.addingTimeInterval(10)).count, 1)
    }

    func testBackoffIntervalsEscalate() throws {
        XCTAssertEqual(PhotoUploadQueue.backoffSeconds(attempt: 1), 5)
        XCTAssertEqual(PhotoUploadQueue.backoffSeconds(attempt: 2), 30)
        XCTAssertEqual(PhotoUploadQueue.backoffSeconds(attempt: 3), 120)
        XCTAssertEqual(PhotoUploadQueue.backoffSeconds(attempt: 4), 600)
        XCTAssertEqual(PhotoUploadQueue.backoffSeconds(attempt: 5), 3600)
        XCTAssertEqual(PhotoUploadQueue.backoffSeconds(attempt: 6), 3600)
    }
}
