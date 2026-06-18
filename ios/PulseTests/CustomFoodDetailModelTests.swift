// PulseTests/CustomFoodDetailModelTests.swift
import XCTest
@testable import Pulse

/// Drives CustomFoodDetailModel against a stubbed AuthSession and asserts the
/// rename/delete/log action states. Mirrors ViewModelLoadTests' setup.
final class CustomFoodDetailModelTests: XCTestCase {
    private let testService = "com.pulseapp.pulse.session.test"
    private var testAccount = ""
    private var activeStubs: [StubURLProtocol.Registration] = []
    private var retainedAuths: [AuthSession] = []

    override func setUp() { super.setUp(); testAccount = "cfd-\(UUID().uuidString)" }
    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }; activeStubs = []; retainedAuths = []
        _ = KeychainStore.delete(service: testService, account: testAccount); super.tearDown()
    }

    private static let id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func food(_ name: String = "Protein Shake") -> CustomFood {
        CustomFood(id: Self.id, name: name, basis: .perServing, servingSize: 1, servingSizeUnit: "scoop",
                   calories: 130, proteinG: 25, carbsG: 3, fatG: 1.5, foodId: nil, portionLabel: nil)
    }

    /// Builds a signed-in AuthSession whose client routes every request through `responder`.
    private func makeAuth(responder: @escaping (URLRequest) -> (Int, Data)) -> AuthSession {
        _ = KeychainStore.write(#"{"token":"tok","email":"k@e.com"}"#, service: testService, account: testAccount)
        let stub = StubURLProtocol.makeSession { req in
            let (code, data) = responder(req)
            return (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, data)
        }
        activeStubs.append(stub)
        let auth = AuthSession(baseURL: URL(string: "https://example.test")!,
                               keychainService: testService, keychainAccount: testAccount,
                               urlSession: stub.session)
        retainedAuths.append(auth)
        return auth
    }

    func test_rename_success_updatesFoodAndState() async {
        let updated = #"{"id":"22222222-2222-2222-2222-222222222222","name":"Shake 2","basis":"per_serving","serving_size":1.0,"serving_size_unit":"scoop","calories":130,"protein_g":25.0,"carbs_g":3.0,"fat_g":1.5}"#
        let auth = makeAuth { _ in (200, Data(updated.utf8)) }
        let model = CustomFoodDetailModel(food: food(), auth: auth)
        await model.rename(to: "Shake 2")
        XCTAssertEqual(model.food.name, "Shake 2")
        if case .saved = model.renameState {} else { XCTFail("expected saved, got \(model.renameState)") }
    }

    func test_rename_conflict_setsFriendlyMessage() async {
        let auth = makeAuth { _ in (409, Data()) }
        let model = CustomFoodDetailModel(food: food(), auth: auth)
        await model.rename(to: "Dup")
        if case .failed = model.renameState {} else { return XCTFail("expected failed") }
        XCTAssertTrue(model.renameErrorMessage.contains("already exists"), model.renameErrorMessage)
    }

    func test_delete_success_setsDeleted() async {
        let auth = makeAuth { _ in (204, Data()) }
        let model = CustomFoodDetailModel(food: food(), auth: auth)
        await model.delete()
        if case .deleted = model.deleteState {} else { XCTFail("expected deleted") }
    }

    func test_delete_conflict_setsReferencedMessage() async {
        let auth = makeAuth { _ in (409, Data()) }
        let model = CustomFoodDetailModel(food: food(), auth: auth)
        await model.delete()
        if case .failed = model.deleteState {} else { return XCTFail("expected failed") }
        XCTAssertTrue(model.deleteErrorMessage.contains("used by"), model.deleteErrorMessage)
    }

    // MARK: - log(_:) path

    /// Minimal nutrition stub; the log path only reads `item.macros`, not this.
    private func nutrition() -> FoodNutrition {
        FoodNutrition(basis: .perServing, servingSize: 1, servingSizeUnit: "scoop",
                      caloriesPerBasis: 130, proteinGPerBasis: 25, carbsGPerBasis: 3, fatGPerBasis: 1.5)
    }

    /// Builds a custom-food batch item for the log path.
    /// Inputs:
    ///   - customFoodId: the custom-food reference (nil exercises the guard).
    ///   - value: typed quantity value.
    ///   - macros: frozen macros posted on the entry.
    /// Outputs: a `BatchFoodItem` in typed-servings mode.
    private func item(customFoodId: UUID?, value: Double,
                      macros: MacroTotals = MacroTotals(calories: 260, proteinG: 50, carbsG: 6, fatG: 3)) -> BatchFoodItem {
        BatchFoodItem(id: UUID(), displayName: "Protein Shake", usdaFdcId: nil, usdaDescription: nil,
                      customFoodId: customFoodId, nutrition: nutrition(),
                      quantity: .typed(value: value, unit: .servings), containerId: nil, macros: macros)
    }

    func test_log_success_setsLoggedWithDailyTotals() async {
        let body = #"{"entries":[],"daily_totals":{"calories":260,"protein_g":50.0,"carbs_g":6.0,"fat_g":3.0}}"#
        let auth = makeAuth { _ in (201, Data(body.utf8)) }
        let model = CustomFoodDetailModel(food: food(), auth: auth)
        await model.log(item(customFoodId: Self.id, value: 2))
        guard case .logged(let totals) = model.logState else {
            return XCTFail("expected logged, got \(model.logState)")
        }
        XCTAssertEqual(totals, MacroTotals(calories: 260, proteinG: 50, carbsG: 6, fatG: 3))
    }

    func test_log_nilCustomFoodId_failsWithoutNetwork() async {
        let auth = makeAuth { _ in
            XCTFail("network should not be hit when customFoodId is nil")
            return (500, Data())
        }
        let model = CustomFoodDetailModel(food: food(), auth: auth)
        await model.log(item(customFoodId: nil, value: 2))
        if case .failed = model.logState {} else { XCTFail("expected failed, got \(model.logState)") }
    }

    func test_log_typedServings_quantityTextSingularVsPlural() async throws {
        let body = #"{"entries":[],"daily_totals":{"calories":0,"protein_g":0.0,"carbs_g":0.0,"fat_g":0.0}}"#

        let authPlural = makeAuth { _ in (201, Data(body.utf8)) }
        let modelPlural = CustomFoodDetailModel(food: food(), auth: authPlural)
        await modelPlural.log(item(customFoodId: Self.id, value: 2))
        XCTAssertEqual(try postedQuantityText(), "2 servings")

        let authSingular = makeAuth { _ in (201, Data(body.utf8)) }
        let modelSingular = CustomFoodDetailModel(food: food(), auth: authSingular)
        await modelSingular.log(item(customFoodId: Self.id, value: 1))
        XCTAssertEqual(try postedQuantityText(), "1 serving")
    }

    /// Parses `quantity_text` out of the most recently posted entries body.
    /// The body is `{"items":[<FoodEntryCreate>...]}`; we read items[0].
    /// Outputs: the posted `quantity_text` string.
    /// Throws: when no body was captured or the shape is unexpected.
    private func postedQuantityText() throws -> String {
        let data = try XCTUnwrap(activeStubs.last?.lastRequestBody, "no request body captured")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], "expected JSON object")
        let items = try XCTUnwrap(root["items"] as? [[String: Any]], "expected items array")
        let first = try XCTUnwrap(items.first, "empty items array")
        return try XCTUnwrap(first["quantity_text"] as? String, "missing quantity_text")
    }
}
