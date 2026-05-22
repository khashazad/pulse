/// Source-level regressions for ProgressPhotoStore's worker scheduling.
/// These protect queue semantics that are difficult to observe without a
/// full app-hosted auth/session stack.
import XCTest

final class ProgressPhotoStoreSourceTests: XCTestCase {

    /// Reads the ProgressPhotoStore source file from the checked-out repo.
    /// Outputs: source text.
    /// Exceptions: throws when the source file cannot be found or read.
    private func progressPhotoStoreSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent("DietTracker/State/ProgressPhotoStore.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Extracts the processOne method body from ProgressPhotoStore source.
    /// Outputs: source text for the worker upload handler.
    /// Exceptions: throws when the method boundaries cannot be found.
    private func processOneSource(from source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "private func processOne"))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: "\n    /// Recomputes"))
        return String(tail[..<end.lowerBound])
    }

    /// Extracts the upload scheduling method body from ProgressPhotoStore source.
    /// - Parameter source: String containing the full ProgressPhotoStore source.
    /// - Returns: String containing the upload method source.
    /// - Throws: XCTest unwrap failures when the method boundaries cannot be found.
    private func uploadSource(from source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "func upload(date: Date"))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: "\n    /// Evicts"))
        return String(tail[..<end.lowerBound])
    }

    /// Ensures new uploads can wake a worker sleeping on a later retry.
    /// - Returns: Void.
    /// - Throws: XCTest unwrap failures when source cannot be read or expected calls are missing.
    func testUploadCancelsSleepingWorkerBeforeKick() throws {
        let source = try progressPhotoStoreSource()
        let upload = try uploadSource(from: source)
        let cancel = try XCTUnwrap(upload.range(of: "workerTask?.cancel()"))
        let clear = try XCTUnwrap(upload.range(of: "workerTask = nil"))
        let kick = try XCTUnwrap(upload.range(of: "kickWorker()"))

        XCTAssertLessThan(cancel.lowerBound, clear.lowerBound)
        XCTAssertLessThan(clear.lowerBound, kick.lowerBound)
    }

    /// Ensures signed-out auth does not make the due queue spin forever.
    /// Outputs: none.
    /// Exceptions: throws when source cannot be read.
    func testMissingAuthBacksOffDueUpload() throws {
        let source = try progressPhotoStoreSource()
        let processOne = try processOneSource(from: source)

        XCTAssertTrue(processOne.contains("queue.markFailure(id: item.id)"))
        XCTAssertFalse(processOne.contains("guard let client = auth?.makeProgressPhotoClient() else { return }"))
    }
}
