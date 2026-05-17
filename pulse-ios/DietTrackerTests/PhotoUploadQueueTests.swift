import XCTest
@testable import DietTracker

final class PhotoUploadQueueTests: XCTestCase {

    private func tempQueue() throws -> (PhotoUploadQueue, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("queuetest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("pending_uploads.json")
        return (PhotoUploadQueue(fileURL: file), file)
    }

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

    func testBackoffIntervalsEscalate() throws {
        XCTAssertEqual(PhotoUploadQueue.backoffSeconds(attempt: 1), 5)
        XCTAssertEqual(PhotoUploadQueue.backoffSeconds(attempt: 2), 30)
        XCTAssertEqual(PhotoUploadQueue.backoffSeconds(attempt: 3), 120)
        XCTAssertEqual(PhotoUploadQueue.backoffSeconds(attempt: 4), 600)
        XCTAssertEqual(PhotoUploadQueue.backoffSeconds(attempt: 5), 3600)
        XCTAssertEqual(PhotoUploadQueue.backoffSeconds(attempt: 6), 3600)
    }

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
