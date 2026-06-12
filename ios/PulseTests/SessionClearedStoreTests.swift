/// Sign-out cleanup tests: verifies the `onSessionCleared` wiring (mirroring
/// `PulseApp`) empties every per-session store — targets, progress photos,
/// photo tags — and cancels the photo upload worker, so no prior-session data
/// or retry loop survives sign-out. Complements `ModelUnauthorizedTests`,
/// which covers the 401 → signed-out transition itself.
import XCTest
import UIKit
@testable import Pulse

@MainActor
final class SessionClearedStoreTests: XCTestCase {
    private let testService = "com.pulseapp.pulse.session.test"
    private var testAccount = ""
    private var activeStubs: [StubURLProtocol.Registration] = []

    /// Allocates a unique keychain account per test run.
    /// - Returns: Nothing.
    override func setUp() {
        super.setUp()
        testAccount = "clear-\(UUID().uuidString)"
    }

    /// Invalidates stub sessions and removes the test keychain entry.
    /// - Returns: Nothing.
    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        _ = KeychainStore.delete(service: testService, account: testAccount)
        super.tearDown()
    }

    /// Loads a JSON fixture from the test bundle.
    /// - Parameter name: fixture file name without extension.
    /// - Returns: fixture bytes.
    private func fixture(_ name: String) -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")!
        return try! Data(contentsOf: url)
    }

    /// Builds a signed-in `AuthSession` whose stub backend serves photo/tag
    /// fixtures, accepts logout, and fails photo POSTs with 500 so the upload
    /// worker enters its retry/backoff loop and stays alive.
    /// - Returns: a signed-in `AuthSession` backed by the stub session.
    private func makeAuth() -> AuthSession {
        _ = KeychainStore.write(
            #"{"token":"tok","email":"k@e.com"}"#,
            service: testService, account: testAccount
        )
        let stub = StubURLProtocol.makeSession { req in
            let path = req.url?.path ?? ""
            let method = req.httpMethod ?? "GET"
            func resp(_ code: Int) -> HTTPURLResponse {
                HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            }
            if path == "/measures/photos" {
                // POST fails so the queued upload backs off and keeps the worker alive.
                return method == "POST" ? (resp(500), Data()) : (resp(200), self.fixture("progress_photos"))
            }
            if path == "/measures/photo-tags" { return (resp(200), self.fixture("photo_tags")) }
            if path == "/auth/logout" { return (resp(200), Data()) }
            return (resp(404), Data())
        }
        activeStubs.append(stub)
        return AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount,
            urlSession: stub.session
        )
    }

    /// Polls `condition` every 20 ms until it holds or `timeout` elapses,
    /// failing the test on timeout.
    /// - Parameters:
    ///   - timeout: maximum seconds to wait (default 3).
    ///   - message: failure message used when the deadline passes.
    ///   - condition: predicate evaluated on the main actor each poll.
    /// - Returns: Void.
    /// - Throws: rethrows `Task.sleep` errors (test cancellation).
    private func waitUntil(
        timeout: TimeInterval = 3,
        message: String = "condition not met before timeout",
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail(message) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Populates UserTargetsStore, ProgressPhotoStore (metadata + an in-flight
    /// failing upload), and ProgressPhotoTagStore, then signs out with the
    /// stores wired to `onSessionCleared` exactly as `PulseApp` wires them.
    /// Asserts every store is emptied and the upload worker is cancelled.
    /// - Returns: Void.
    /// - Throws: setup/decoding errors; `waitUntil` sleep errors.
    func testSignOutClearsStoresAndCancelsWorker() async throws {
        let auth = makeAuth()
        let targets = UserTargetsStore()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("session-clear-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let photoStore = ProgressPhotoStore(
            auth: auth,
            queueFileURL: tmp.appendingPathComponent("pending_uploads.json"),
            cacheDirectory: tmp.appendingPathComponent("cache", isDirectory: true)
        )
        let tagStore = ProgressPhotoTagStore(auth: auth)

        // Wire session-clear exactly as PulseApp.init does.
        auth.onSessionCleared = { [weak targets, weak photoStore, weak tagStore] in
            targets?.clear()
            Task { @MainActor in
                photoStore?.clear()
                tagStore?.clear()
            }
        }

        // Populate all three stores.
        let targetsJSON = #"{"calories":2000,"protein_g":150,"carbs_g":200,"fat_g":60,"target_weight_lb":175}"#
        targets.update(try JSONDecoder.pulseDefault().decode(MacroTargets.self, from: targetsJSON.data(using: .utf8)!))
        await photoStore.reconcile(from: Date(timeIntervalSince1970: 1_747_000_000), to: Date())
        await tagStore.reload()
        await photoStore.upload(
            date: Date(),
            tagId: UUID(uuidString: "b2b2b2b2-2222-2222-2222-222222222222")!,
            imageData: Data([0x01, 0x02, 0x03, 0x04])
        )

        XCTAssertNotNil(targets.targets)
        XCTAssertFalse(photoStore.photos.isEmpty, "reconcile should have loaded fixture metadata")
        XCTAssertFalse(tagStore.tags.isEmpty, "reload should have loaded fixture tags")
        try await waitUntil(message: "upload worker never became active with pending work") {
            photoStore.hasActiveWorker && photoStore.pendingCount > 0
        }

        await auth.signOut()

        // clear() is dispatched onto the main actor by the wiring; poll for it.
        try await waitUntil(message: "stores were not cleared after sign-out") {
            targets.targets == nil
                && photoStore.photos.isEmpty
                && tagStore.tags.isEmpty
                && !photoStore.hasActiveWorker
                && photoStore.pendingCount == 0
        }
        XCTAssertNil(targets.targets)
        XCTAssertTrue(photoStore.photos.isEmpty)
        XCTAssertTrue(tagStore.tags.isEmpty)
        XCTAssertFalse(photoStore.hasActiveWorker, "sign-out must cancel the upload worker")
        XCTAssertEqual(photoStore.pendingCount, 0)
        XCTAssertFalse(auth.isSignedIn)
    }
}
