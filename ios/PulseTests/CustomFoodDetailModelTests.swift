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
                   calories: 130, proteinG: 25, carbsG: 3, fatG: 1.5)
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
}
