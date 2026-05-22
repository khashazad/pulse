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

    /// Ensures new uploads can wake a worker sleeping on a later retry.
    /// Outputs: none.
    /// Exceptions: throws when source cannot be read.
    func testUploadCancelsSleepingWorkerBeforeKick() throws {
        let source = try progressPhotoStoreSource()

        XCTAssertTrue(source.contains("workerTask?.cancel()"))
        XCTAssertTrue(source.contains("workerTask = nil"))
        XCTAssertTrue(source.contains("kickWorker()"))
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
