import XCTest
@testable import Pulse

/// Verifies TagProgressionModel filters to its tag and sorts newest-first.
@MainActor
final class TagProgressionModelTests: XCTestCase {
    private let testService = "com.pulseapp.pulse.session.test"
    private var activeStubs: [StubURLProtocol.Registration] = []
    /// Retained because models hold `weak var auth`; without a strong ref the
    /// session deallocates and `makeProgressPhotoClient()` returns nil.
    private var retainedAuths: [AuthSession] = []
    private var keychainAccounts: [String] = []

    /// Loads a JSON fixture from the test bundle.
    /// - Parameter name: fixture file name without the `.json` extension.
    /// - Returns: the fixture's raw bytes.
    /// - Throws: when the resource is missing or unreadable.
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    /// Builds a signed-in AuthSession whose client returns the multi-tag photo
    /// fixture (200) for any `/measures/photos` GET, retained for the test.
    /// - Returns: the signed-in session.
    /// - Throws: when the fixture cannot be loaded.
    private func makeAuth() throws -> AuthSession {
        let photos = try fixture("progress_photos_multitag")
        let stub = StubURLProtocol.makeSession { req in
            let body: Data = req.url?.path == "/measures/photos" ? photos : Data()
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        activeStubs.append(stub)
        let account = "tpm-\(UUID().uuidString)"
        keychainAccounts.append(account)
        let auth = AuthSession.signedInStub(
            session: stub.session,
            keychainService: testService,
            keychainAccount: account
        )
        retainedAuths.append(auth)
        return auth
    }

    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        retainedAuths = []
        keychainAccounts = []
    }

    /// A tag struct for the "front" tag id used in the fixture.
    private func frontTag() -> ProgressPhotoTag {
        ProgressPhotoTag(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "front",
            normalizedName: "front",
            sortOrder: 0,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testFiltersToTagAndSortsNewestFirst() async throws {
        let auth = try makeAuth()
        let store = ProgressPhotoStore(
            auth: auth,
            queueFileURL: URL.temporaryDirectory.appendingPathComponent("q-\(UUID()).json"),
            cacheDirectory: URL.temporaryDirectory.appendingPathComponent("c-\(UUID())")
        )
        let model = TagProgressionModel(tag: frontTag(), auth: auth, store: store)

        await model.load()

        // Only the two "front" photos survive the filter, newest-first.
        XCTAssertEqual(model.photos.map(\.sha256), ["front-newer", "front-older"])
    }
}
