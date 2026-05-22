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
        let url = repoRoot.appendingPathComponent("Pulse/State/ProgressPhotoStore.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Extracts the processOne method body from ProgressPhotoStore source.
    /// Outputs: source text for the worker upload handler.
    /// Exceptions: throws when the method boundaries cannot be found.
    private func processOneSource(from source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "private func processOne"))
        let tail = source[start.lowerBound...]
        // Anchor on the next function signature so unrelated docstring
        // edits don't break this test.
        let end = try XCTUnwrap(tail.range(of: "private func recountPending"))
        return String(tail[..<end.lowerBound])
    }

    /// Extracts the upload scheduling method body from ProgressPhotoStore source.
    /// - Parameter source: String containing the full ProgressPhotoStore source.
    /// - Returns: String containing the upload method source.
    /// - Throws: XCTest unwrap failures when the method boundaries cannot be found.
    private func uploadSource(from source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "func upload(date: Date"))
        let tail = source[start.lowerBound...]
        // Anchor on the next function signature so unrelated docstring
        // edits don't break this test.
        let end = try XCTUnwrap(tail.range(of: "func delete("))
        return String(tail[..<end.lowerBound])
    }

    /// Locks in the worker-kick invariant: cancellation is gated on
    /// `workerSleeping` (so an in-flight POST is not aborted by a sibling
    /// upload), the unconditional `await workerTask?.value` line is NOT
    /// present (it deadlocks the caller and opens a worker-orphan race), and
    /// the conditional cancel precedes `kickWorker()`.
    /// - Returns: Void.
    /// - Throws: XCTest unwrap failures when source cannot be read or
    ///   expected calls are missing.
    func testUploadCancelsSleepingWorkerBeforeKick() throws {
        let source = try progressPhotoStoreSource()
        let upload = try uploadSource(from: source)
        let cancelGated = try XCTUnwrap(
            upload.range(of: "if workerSleeping { workerTask?.cancel() }")
        )
        let kick = try XCTUnwrap(upload.range(of: "kickWorker()"))

        XCTAssertLessThan(cancelGated.lowerBound, kick.lowerBound)
        XCTAssertFalse(
            upload.contains("await workerTask?.value"),
            "upload() must not block the caller on the prior worker; the cancel/kick pair plus server idempotency are sufficient."
        )
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
