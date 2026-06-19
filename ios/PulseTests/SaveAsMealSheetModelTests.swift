// PulseTests/SaveAsMealSheetModelTests.swift
import XCTest
@testable import Pulse

/// Tests `SaveAsMealSheetModel.save()`: success sets `created` + posts the body,
/// 409 sets the name-clash message, and empty name fails without touching the
/// network. Mirrors `GroupFoodSheetModelTests`' auth-stub harness.
final class SaveAsMealSheetModelTests: XCTestCase {
    private let testService = "com.pulseapp.pulse.session.test"
    private var activeStubs: [StubURLProtocol.Registration] = []
    private var retainedAuths: [AuthSession] = []
    private var keychainAccounts: [String] = []

    /// Builds a meal item with the given display name; other fields are
    /// placeholders sufficient for body/macro assertions.
    /// Inputs:
    ///   - name: the item's display name.
    /// Outputs: a `NewMealItem` value.
    private func item(_ name: String) -> NewMealItem {
        NewMealItem(id: UUID(), displayName: name, quantityText: "1 serving",
                    normalizedQuantityValue: 1, normalizedQuantityUnit: "serving",
                    usdaFdcId: nil, usdaDescription: nil, customFoodId: UUID(),
                    calories: 100, proteinG: 5, carbsG: 10, fatG: 2)
    }

    /// A canonical `MealResponse` JSON body (used for the 201 success response).
    /// Inputs:
    ///   - id: the created meal's id.
    /// Outputs: the encoded `/meals` 201 response body.
    private func mealJSON(id: String) -> Data {
        """
        { "id": "\(id)", "user_key": "khash", "name": "Lunch",
          "normalized_name": "lunch", "notes": null, "aliases": [],
          "created_at": "2026-06-18T00:00:00Z", "updated_at": "2026-06-18T00:00:00Z",
          "items": [] }
        """.data(using: .utf8)!
    }

    /// Builds a signed-in `AuthSession` routing requests through `responder`,
    /// retaining it for the test's lifetime. Returns the session plus the
    /// `Registration` so a test can read the captured request body afterward.
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
        let account = "sams-\(UUID().uuidString)"
        keychainAccounts.append(account)
        let auth = AuthSession.signedInStub(
            session: stub.session, keychainService: testService, keychainAccount: account)
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

    func test_save_success_setsCreatedAndPostsItems() async throws {
        let createdId = "55555555-5555-5555-5555-555555555555"
        let (auth, stub) = makeAuth { _ in (201, self.mealJSON(id: createdId)) }
        let model = SaveAsMealSheetModel(items: [item("Chicken"), item("Rice")],
                                         suggestedName: "Lunch", auth: auth)
        await model.save()

        XCTAssertEqual(model.created?.id, UUID(uuidString: createdId))
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isSaving)

        let body = try XCTUnwrap(stub.lastRequestBody)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["name"] as? String, "Lunch")
        XCTAssertEqual((obj["items"] as? [[String: Any]])?.count, 2)
    }

    func test_save_conflict_setsNameClashMessage() async {
        let (auth, _) = makeAuth { _ in (409, Data()) }
        let model = SaveAsMealSheetModel(items: [item("Chicken")], suggestedName: "Lunch", auth: auth)
        await model.save()
        XCTAssertNil(model.created)
        XCTAssertEqual(model.errorMessage, "A meal with that name already exists.")
    }

    func test_save_emptyName_failsWithoutNetwork() async {
        var hitNetwork = false
        let (auth, _) = makeAuth { _ in hitNetwork = true; return (201, Data()) }
        let model = SaveAsMealSheetModel(items: [item("Chicken")], suggestedName: "  ", auth: auth)
        await model.save()
        XCTAssertNil(model.created)
        XCTAssertEqual(model.errorMessage, "Name can't be empty.")
        XCTAssertFalse(hitNetwork)
    }
}
