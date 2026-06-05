// PulseTests/ModelLogicCoverageTests.swift
/// Integration-style logic tests for view-model branches the success/failure
/// suites don't reach: UserTargetsStore.save, MealDetailModel log
/// success + stale-data retention, WeightLogModel.todayEntry and the
/// upsert-from-empty path, and AuthSession's exchange transport/server error
/// branches. All use a scoped `StubURLProtocol` session and a dedicated test
/// keychain slot, cleaned up in tearDown.
import XCTest
@testable import Pulse

final class ModelLogicCoverageTests: XCTestCase {
    private let testService = "com.pulseapp.pulse.session.test"
    private var testAccount = ""
    private var activeStubs: [StubURLProtocol.Registration] = []
    private var retainedAuths: [AuthSession] = []

    override func setUp() {
        super.setUp()
        testAccount = "mlc-\(UUID().uuidString)"
    }

    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        retainedAuths = []
        _ = KeychainStore.delete(service: testService, account: testAccount)
        super.tearDown()
    }

    /// Builds a signed-in `AuthSession` wired to the given responder.
    /// - Parameter responder: synthesizes an HTTP response for each request.
    /// - Returns: a retained, signed-in `AuthSession`.
    private func signedInAuth(responder: @escaping StubURLProtocol.Responder) -> AuthSession {
        _ = KeychainStore.write(#"{"token":"tok","email":"k@e.com"}"#, service: testService, account: testAccount)
        let stub = StubURLProtocol.makeSession(responder: responder)
        activeStubs.append(stub)
        let a = AuthSession(baseURL: URL(string: "https://example.test")!,
                            keychainService: testService, keychainAccount: testAccount, urlSession: stub.session)
        retainedAuths.append(a)
        return a
    }

    private func http(_ req: URLRequest, _ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    private let targetsJSON = #"{"calories":2000,"protein_g":150,"carbs_g":200,"fat_g":60,"target_weight_lb":175}"#

    // MARK: - UserTargetsStore.save

    /// Verifies `save` PUTs the given targets once — with all five snake_case
    /// fields in the body — and publishes the server-echoed value on success.
    /// The stub echoes calories=1801 to prove the cache holds the echo.
    func test_save_putsAllFieldsAndUpdatesCache() async throws {
        let auth = signedInAuth { req in
            XCTAssertEqual(req.httpMethod, "PUT")
            XCTAssertEqual(req.url?.path, "/targets")
            let body = #"{"calories":1801,"protein_g":160,"carbs_g":150,"fat_g":55,"target_weight_lb":168}"#
            return (self.http(req, 200), body.data(using: .utf8)!)
        }
        let store = UserTargetsStore()
        let targets = MacroTargets(calories: 1800, proteinG: 160, carbsG: 150,
                                   fatG: 55, targetWeightLb: 168)
        let echoed = try await store.save(targets, client: auth.makeClient()!)
        XCTAssertEqual(echoed.calories, 1801, "save must return the server echo")
        XCTAssertEqual(store.targets?.calories, 1801,
                       "cache must hold the server-echoed value, not the input")
        XCTAssertEqual(store.targets?.proteinG, 160)

        let sent = try JSONSerialization.jsonObject(
            with: activeStubs.last?.lastRequestBody ?? Data()) as? [String: Any]
        XCTAssertEqual(sent?["calories"] as? Int, 1800)
        XCTAssertEqual(sent?["protein_g"] as? Double, 160)
        XCTAssertEqual(sent?["carbs_g"] as? Double, 150)
        XCTAssertEqual(sent?["fat_g"] as? Double, 55)
        XCTAssertEqual(sent?["target_weight_lb"] as? Double, 168)
    }

    /// Verifies `save` rethrows on server failure and leaves the cache
    /// untouched so the caller can show an error and retry.
    func test_save_failureRethrowsAndKeepsCache() async {
        let auth = signedInAuth { req in (self.http(req, 500), Data()) }
        let store = UserTargetsStore()
        store.update(MacroTargets(calories: 1, proteinG: 1, carbsG: 1,
                                  fatG: 1, targetWeightLb: 100))
        do {
            try await store.save(
                MacroTargets(calories: 2, proteinG: 2, carbsG: 2, fatG: 2, targetWeightLb: 200),
                client: auth.makeClient()!)
            XCTFail("expected save to throw on HTTP 500")
        } catch {
            // expected
        }
        XCTAssertEqual(store.targets?.calories, 1, "cache must survive a failed save")
    }

    // MARK: - MealDetailModel log success + stale retention

    /// Verifies `logMeal` success transitions `logState` to `.logged` carrying the
    /// response daily totals, and `resetLogState` returns it to idle.
    func test_mealDetail_logMealSuccessThenReset() async {
        let auth = signedInAuth { req in
            (self.http(req, 201), self.fixture("meal_log"))
        }
        let model = MealDetailModel(mealId: UUID(), auth: auth)
        await model.logMeal(consumedAt: Date())
        guard case .logged(let totals) = model.logState else {
            return XCTFail("expected .logged, got \(model.logState)")
        }
        XCTAssertEqual(totals.calories, 234)
        model.resetLogState()
        XCTAssertEqual(model.logState, .idle)
    }

    /// Verifies a failed reload after a successful load keeps the already-loaded
    /// meal on screen (stale-data retention) rather than flipping to `.failed`.
    func test_mealDetail_failedReloadKeepsLoadedMeal() async {
        var failNext = false
        let auth = signedInAuth { req in
            if failNext { return (self.http(req, 500), Data()) }
            return (self.http(req, 200), self.fixture("meal_with_items"))
        }
        let model = MealDetailModel(mealId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, auth: auth)
        await model.load()
        guard case .loaded(let first) = model.state else { return XCTFail("first load: \(model.state)") }
        XCTAssertEqual(first.name, "Breakfast Bowl")
        // Second load fails; the loaded meal must remain.
        failNext = true
        await model.load()
        guard case .loaded(let still) = model.state else {
            return XCTFail("stale meal must survive a failed reload, got \(model.state)")
        }
        XCTAssertEqual(still.name, "Breakfast Bowl")
    }

    // MARK: - WeightLogModel branches

    /// Verifies `todayEntry` returns the entry whose date is today and `upsert`
    /// from an empty (non-loaded) state seeds a single-element loaded list.
    func test_weightLog_upsertFromEmptySeedsAndTodayEntry() async {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let logDate = DateOnly.string(from: today)
        let auth = signedInAuth { req in
            if req.url?.path == "/weight" && req.httpMethod == "GET" {
                return (self.http(req, 200), "[]".data(using: .utf8)!)
            }
            // upsert PUT/POST returns a today-dated entry.
            let body = """
            {"id":"00000000-0000-0000-0000-0000000000aa","log_date":"\(logDate)","weight_lb":182.4,
             "source_unit":"lb","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}
            """
            return (self.http(req, 200), body.data(using: .utf8)!)
        }
        let model = WeightLogModel(auth: auth)
        await model.load()
        guard case .loaded(let empty) = model.state else { return XCTFail("load: \(model.state)") }
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(model.todayEntry, "no entry today yet")
        // Upsert into the empty state takes the `else` branch → loaded([updated]).
        await model.upsert(date: today, weight: 182.4, unit: .lb)
        guard case .loaded(let after) = model.state else { return XCTFail("upsert: \(model.state)") }
        XCTAssertEqual(after.count, 1)
        XCTAssertNotNil(model.todayEntry, "the freshly-upserted today entry should resolve")
        XCTAssertEqual(model.todayEntry?.weightLb, 182.4)
    }

    // MARK: - AuthSession exchange error branches

    /// Verifies a non-2xx, non-4xx server response during code exchange surfaces a
    /// `.server` error and leaves the user signed out.
    func test_authExchange_serverErrorSurfacesAndStaysSignedOut() async {
        _ = KeychainStore.delete(service: testService, account: testAccount)
        let stub = StubURLProtocol.makeSession { req in (self.http(req, 503), Data()) }
        activeStubs.append(stub)
        let auth = AuthSession(baseURL: URL(string: "https://example.test")!,
                               keychainService: testService, keychainAccount: testAccount, urlSession: stub.session)
        await auth.completeSignIn(url: URL(string: "diettracker://auth?code=c")!, codeVerifier: "v")
        if case .error(let e) = auth.state {
            XCTAssertEqual(e, .server(status: 503))
        } else {
            XCTFail("expected .error(.server), got \(auth.state)")
        }
        XCTAssertFalse(auth.isSignedIn)
    }

    /// Verifies a 200 exchange response with an undecodable body surfaces a
    /// decoding/exchange error rather than signing the user in.
    func test_authExchange_undecodableBodyFailsSignIn() async {
        _ = KeychainStore.delete(service: testService, account: testAccount)
        let stub = StubURLProtocol.makeSession { req in (self.http(req, 200), "{}".data(using: .utf8)!) }
        activeStubs.append(stub)
        let auth = AuthSession(baseURL: URL(string: "https://example.test")!,
                               keychainService: testService, keychainAccount: testAccount, urlSession: stub.session)
        await auth.completeSignIn(url: URL(string: "diettracker://auth?code=c")!, codeVerifier: "v")
        XCTAssertFalse(auth.isSignedIn)
        if case .error = auth.state {} else { XCTFail("expected an error state, got \(auth.state)") }
    }

    /// Loads a JSON fixture from the test bundle.
    private func fixture(_ name: String) -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")!
        return try! Data(contentsOf: url)
    }

    // MARK: - 401 → handleUnauthorized routing

    /// Builds a signed-in auth whose every request returns HTTP 401, used to
    /// drive the models' `unauthorized` catch branches (`handleUnauthorized()`).
    private func unauthorizedAuth() -> AuthSession {
        _ = KeychainStore.write(#"{"token":"tok","email":"k@e.com"}"#, service: testService, account: testAccount)
        let stub = StubURLProtocol.makeSession { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        activeStubs.append(stub)
        let a = AuthSession(baseURL: URL(string: "https://example.test")!,
                            keychainService: testService, keychainAccount: testAccount, urlSession: stub.session)
        retainedAuths.append(a)
        return a
    }

    /// Verifies a 401 from a period-intake load routes through
    /// `AuthSession.handleUnauthorized` (signing the session out) and surfaces
    /// `.failed(.unauthorized)`.
    func test_periodModel_401SignsOut() async {
        let auth = unauthorizedAuth()
        XCTAssertTrue(auth.isSignedIn)
        let m = PeriodIntakeModel(range: .month, auth: auth)
        await m.load()
        if case .failed(.unauthorized) = m.state {} else { XCTFail("got \(m.state)") }
        XCTAssertFalse(auth.isSignedIn, "401 must clear the session")
    }

    /// Verifies a 401 from a meals-list load routes through `handleUnauthorized`.
    func test_mealsModel_401SignsOut() async {
        let auth = unauthorizedAuth()
        let m = MealsModel(auth: auth)
        await m.load()
        if case .failed(.unauthorized) = m.state {} else { XCTFail("got \(m.state)") }
        XCTAssertFalse(auth.isSignedIn)
    }

    /// Verifies a 401 from a meal-detail load routes through `handleUnauthorized`.
    func test_mealDetail_401SignsOut() async {
        let auth = unauthorizedAuth()
        let m = MealDetailModel(mealId: UUID(), auth: auth)
        await m.load()
        if case .failed(.unauthorized) = m.state {} else { XCTFail("got \(m.state)") }
        XCTAssertFalse(auth.isSignedIn)
    }

    /// Verifies a 401 during a meal-log attempt routes through `handleUnauthorized`.
    func test_mealLog_401SignsOut() async {
        let auth = unauthorizedAuth()
        let m = MealDetailModel(mealId: UUID(), auth: auth)
        await m.logMeal(consumedAt: Date())
        if case .failed(.unauthorized) = m.logState {} else { XCTFail("got \(m.logState)") }
        XCTAssertFalse(auth.isSignedIn)
    }

    /// Verifies a 401 from the containers-list load routes through `handleUnauthorized`.
    func test_containersModel_401SignsOut() async {
        let auth = unauthorizedAuth()
        let m = ContainersListModel(auth: auth)
        await m.load()
        if case .failed(.unauthorized) = m.state {} else { XCTFail("got \(m.state)") }
        XCTAssertFalse(auth.isSignedIn)
    }

    /// Verifies 401s across the weight-log load / upsert / delete all route
    /// through `handleUnauthorized`.
    func test_weightLog_401SignsOut() async {
        let auth = unauthorizedAuth()
        let m = WeightLogModel(auth: auth)
        await m.load()
        if case .failed(.unauthorized) = m.state {} else { XCTFail("load: \(m.state)") }
        await m.upsert(date: Date(), weight: 180, unit: .lb)
        await m.delete(date: Date())
        XCTAssertFalse(auth.isSignedIn)
    }

    /// Verifies a 401 from the weight-trends load routes through `handleUnauthorized`.
    func test_weightTrends_401SignsOut() async {
        let auth = unauthorizedAuth()
        let m = WeightTrendsModel(auth: auth, targetsStore: UserTargetsStore())
        await m.load()
        if case .failed(.unauthorized) = m.analytics {} else { XCTFail("got \(m.analytics)") }
        XCTAssertFalse(auth.isSignedIn)
    }

    /// Verifies a 401 from a day-macro load routes through `handleUnauthorized`.
    func test_dayMacro_401SignsOut() async {
        let auth = unauthorizedAuth()
        let m = DayMacroModel(date: Date(), auth: auth)
        await m.load()
        if case .failed(.unauthorized) = m.state {} else { XCTFail("got \(m.state)") }
        XCTAssertFalse(auth.isSignedIn)
    }

    /// Verifies a 401 during `FoodSearchModel.loadMyFoods` routes through
    /// `handleUnauthorized` (its unauthorized catch branch).
    @MainActor
    func test_foodSearch_loadMyFoods401SignsOut() async {
        let auth = unauthorizedAuth()
        let m = FoodSearchModel(auth: auth, debounce: .milliseconds(1))
        await m.loadMyFoods()
        XCTAssertFalse(auth.isSignedIn, "a 401 while loading my-foods must clear the session")
    }
}
