// PulseTests/GroupFoodSheetModelTests.swift
import XCTest
@testable import Pulse

/// Tests `GroupFoodSheetModel`: label pre-fill via `PortionLabel.derive`, default
/// selection, name-change re-derivation (preserving user edits), and `save()`'s
/// success / 409 / empty-name branches. The success/409 paths route `POST /foods`
/// through a stub `URLSession`; the empty-name path must not touch the network.
final class GroupFoodSheetModelTests: XCTestCase {
    private let testService = "com.pulseapp.pulse.session.test"
    private var activeStubs: [StubURLProtocol.Registration] = []
    /// Retains AuthSessions for the test's lifetime (the model holds no strong
    /// ref of its own beyond `auth`, but keeping these alive keeps `makeClient()`
    /// returning a live client over the stub session).
    private var retainedAuths: [AuthSession] = []
    private var keychainAccounts: [String] = []

    /// Builds a custom food with the given name + id; macros are placeholders.
    /// Inputs:
    ///   - name: the food's display name.
    ///   - id: the food's UUID string.
    /// Outputs: a `CustomFood` value for use as a portion.
    private func food(_ name: String, _ id: String) -> CustomFood {
        CustomFood(id: UUID(uuidString: id)!, name: name, basis: .perUnit,
                   servingSize: 1, servingSizeUnit: "x", calories: 1,
                   proteinG: 0, carbsG: 0, fatG: 0, foodId: nil, portionLabel: nil)
    }

    /// A canonical Food JSON body (used for the 201 success response).
    /// Inputs:
    ///   - id: the created Food's id.
    /// Outputs: the encoded `/foods` 201 response body.
    private func foodResponseJSON(id: String) -> Data {
        """
        { "id": "\(id)", "name": "Apple", "notes": null,
          "default_portion_id": "aaaa1111-0000-0000-0000-000000000001",
          "aliases": [], "portions": [] }
        """.data(using: .utf8)!
    }

    /// Builds a signed-in `AuthSession` routing requests through `responder`,
    /// retaining it for the test's lifetime. Returns the session plus the
    /// `Registration` so a test can read the captured request body afterward
    /// (the responder closure can't read `httpBodyStream` reliably).
    /// Inputs:
    ///   - responder: maps the request to a status + body.
    /// Outputs: the signed-in session and its stub registration.
    private func makeAuth(
        responder: @escaping (URLRequest) -> (Int, Data)
    ) -> (AuthSession, StubURLProtocol.Registration) {
        let stub = StubURLProtocol.makeSession { req in
            let (status, body) = responder(req)
            return (HTTPURLResponse(url: req.url!, statusCode: status,
                                    httpVersion: nil, headerFields: nil)!, body)
        }
        activeStubs.append(stub)
        let account = "gfs-\(UUID().uuidString)"
        keychainAccounts.append(account)
        let auth = AuthSession.signedInStub(
            session: stub.session,
            keychainService: testService,
            keychainAccount: account
        )
        retainedAuths.append(auth)
        return (auth, stub)
    }

    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        retainedAuths = []
        keychainAccounts.forEach { _ = KeychainStore.delete(service: testService, account: $0) }
        keychainAccounts = []
        super.tearDown()
    }

    // MARK: - init

    func test_init_prefillsLabelsAndDefault() {
        let medium = food("medium apple", "aaaa1111-0000-0000-0000-000000000001")
        let large = food("large apple", "aaaa1111-0000-0000-0000-000000000002")
        let model = GroupFoodSheetModel(foods: [medium, large], auth: nil)

        XCTAssertEqual(model.name, "Apple")
        XCTAssertEqual(model.portions.map(\.label), ["medium", "large"])
        XCTAssertEqual(model.defaultPortionId, medium.id)
    }

    // MARK: - name re-derivation

    func test_nameChange_rederivesUneditedButPreservesEdited() {
        let small = food("small banana", "bbbb1111-0000-0000-0000-000000000001")
        let big = food("big banana", "bbbb1111-0000-0000-0000-000000000002")
        let model = GroupFoodSheetModel(foods: [small, big], auth: nil)
        XCTAssertEqual(model.portions.map(\.label), ["small", "big"])

        // User edits the first label; it must stop tracking the name.
        model.setLabel("tiny", for: small.id)

        // Changing the name re-derives the second (unedited) label but leaves
        // the user-edited first label alone.
        model.name = "Banana"
        XCTAssertEqual(model.portions.first(where: { $0.id == small.id })?.label, "tiny")
        XCTAssertEqual(model.portions.first(where: { $0.id == big.id })?.label, "big")
    }

    // MARK: - save success

    func test_save_success_setsCreatedAndPostsBody() async throws {
        let medium = food("medium apple", "aaaa1111-0000-0000-0000-000000000001")
        let large = food("large apple", "aaaa1111-0000-0000-0000-000000000002")
        let createdId = "cccc1111-0000-0000-0000-000000000009"

        let (auth, stub) = makeAuth { _ in
            (201, self.foodResponseJSON(id: createdId))
        }

        let model = GroupFoodSheetModel(foods: [medium, large], auth: auth)
        await model.save()

        XCTAssertNotNil(model.created)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(model.created?.id, UUID(uuidString: createdId))

        let bodyData = try XCTUnwrap(stub.lastRequestBody)
        let capturedBody = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        XCTAssertEqual(capturedBody?["name"] as? String, "Apple")
        let portionIds = capturedBody?["portion_ids"] as? [String]
        XCTAssertEqual(portionIds?.map { $0.lowercased() },
                       [medium.id, large.id].map { $0.uuidString.lowercased() })
    }

    // MARK: - save 409

    func test_save_conflict_setsNameClashMessage() async {
        let medium = food("medium apple", "aaaa1111-0000-0000-0000-000000000001")
        let (auth, _) = makeAuth { _ in (409, Data()) }

        let model = GroupFoodSheetModel(foods: [medium], auth: auth)
        await model.save()

        XCTAssertNil(model.created)
        XCTAssertEqual(model.errorMessage, "A food with that name already exists.")
        XCTAssertFalse(model.isSaving)
    }

    // MARK: - save empty name

    func test_save_emptyName_setsErrorWithoutNetwork() async {
        let medium = food("medium apple", "aaaa1111-0000-0000-0000-000000000001")
        var hitNetwork = false
        let (auth, _) = makeAuth { _ in hitNetwork = true; return (201, Data()) }

        let model = GroupFoodSheetModel(foods: [medium], auth: auth)
        model.name = "   "
        await model.save()

        XCTAssertNil(model.created)
        XCTAssertEqual(model.errorMessage, "Name can't be empty.")
        XCTAssertFalse(hitNetwork)
    }
}
