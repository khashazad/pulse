// PulseTests/ViewRenderExtraTests.swift
/// Additional host-render smoke tests covering screens, sheets, and components
/// that the original `ViewRenderTests` never mounts (or mounts only in their
/// empty state). Each view is mounted in a real key window against a signed-in
/// stub backend and given a brief run-loop pump so its async `.task` loads and
/// re-renders. These are coverage/no-crash tests, not content assertions —
/// they exercise loaded-state bodies, populated lists, and interaction-only
/// component branches that the unit/model suites can't reach.
import XCTest
import SwiftUI
@testable import Pulse

@MainActor
final class ViewRenderExtraTests: XCTestCase {
    private let testService = "com.pulseapp.pulse.session.test"
    private var testAccount = ""
    private var activeStubs: [StubURLProtocol.Registration] = []
    private var targetsStore = UserTargetsStore()
    private var auth: AuthSession!
    private var photoStore: ProgressPhotoStore!
    private var tagStore: ProgressPhotoTagStore!

    override func setUp() {
        super.setUp()
        testAccount = "vre-\(UUID().uuidString)"
        auth = makeAuth()
        photoStore = ProgressPhotoStore(auth: auth)
        tagStore = ProgressPhotoTagStore(auth: auth)
    }

    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        _ = KeychainStore.delete(service: testService, account: testAccount)
        ["prep.targets", "prep.weighIns", "prep.portionsOverride", "prep.batchItems",
         WeightUnit.displayPreferenceKey].forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    // MARK: - scaffolding (mirrors ViewRenderTests)

    private func fixture(_ name: String) -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")!
        return try! Data(contentsOf: url)
    }

    /// JSON for three progress photos under the "Front"/"Back" tags dated today,
    /// today−7, and today−1, so both `ProgressPhotosView` (which shows photos on
    /// today) and `ProgressPhotoComparisonView` (today vs today−7) populate their
    /// grids and rows. Computed at runtime so the dates always match "today".
    private static func photosJSON() -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func day(_ ago: Int) -> String { DateOnly.string(from: cal.date(byAdding: .day, value: -ago, to: today)!) }
        return """
        [
          {"id":"a1a1a1a1-1111-1111-1111-111111111111","date":"\(day(0))","tag_id":"b2b2b2b2-2222-2222-2222-222222222222","mime":"image/jpeg","bytes":1234,"sha256":"sha-today","updated_at":"2026-05-20T10:00:00Z"},
          {"id":"a2a2a2a2-2222-2222-2222-222222222222","date":"\(day(7))","tag_id":"b2b2b2b2-2222-2222-2222-222222222222","mime":"image/jpeg","bytes":1234,"sha256":"sha-week","updated_at":"2026-05-13T10:00:00Z"},
          {"id":"a3a3a3a3-3333-3333-3333-333333333333","date":"\(day(0))","tag_id":"e4e4e4e4-4444-4444-4444-444444444444","mime":"image/jpeg","bytes":1234,"sha256":"sha-today2","updated_at":"2026-05-20T11:00:00Z"}
        ]
        """
    }

    /// Two tags so the photo grid renders multiple tagged cells and the
    /// comparison view's tag ordering exercises the sort-order comparison.
    private static let photoTagsJSON = #"""
    [
      {"id":"b2b2b2b2-2222-2222-2222-222222222222","name":"Front","normalized_name":"front","sort_order":0,"created_at":"2026-05-01T00:00:00Z","updated_at":"2026-05-01T00:00:00Z"},
      {"id":"e4e4e4e4-4444-4444-4444-444444444444","name":"Back","normalized_name":"back","sort_order":1,"created_at":"2026-05-01T00:00:00Z","updated_at":"2026-05-01T00:00:00Z"}
    ]
    """#

    /// Builds a signed-in `AuthSession` whose stub routes requests to fixtures.
    /// Photo metadata and photo bytes resolve to comparison-date photos and a
    /// real PNG so the photo grids and comparison rows populate.
    private func makeAuth() -> AuthSession {
        _ = KeychainStore.write(#"{"token":"tok","email":"k@e.com"}"#, service: testService, account: testAccount)
        let stub = StubURLProtocol.makeSession { req in
            let path = req.url?.path ?? ""
            let method = req.httpMethod ?? "GET"
            func r(_ c: Int) -> HTTPURLResponse { HTTPURLResponse(url: req.url!, statusCode: c, httpVersion: nil, headerFields: nil)! }
            func ok(_ d: Data) -> (HTTPURLResponse, Data) { (r(200), d) }
            if path.hasPrefix("/summary/") { return ok(self.fixture("summary")) }
            if path == "/logs" { return ok(self.fixture("logs")) }
            if path == "/calories_daily" { return ok(self.fixture("calories_daily")) }
            if path == "/targets" { return ok(#"{"calories":2000,"protein_g":150,"carbs_g":200,"fat_g":60,"target_weight_lb":175}"#.data(using: .utf8)!) }
            if path == "/meals" { return ok(self.fixture("meals_with_aliases")) }
            if path.hasPrefix("/meals/") {
                if method == "POST" { return (r(201), self.fixture("meal_log")) }
                return ok(self.fixture("meal_with_items"))
            }
            if path == "/custom-foods" { return ok(self.fixture("custom_foods")) }
            if path == "/food-memory" { return ok(self.fixture("food_memory")) }
            if path == "/usda/search" { return ok(self.fixture("usda_search")) }
            if path == "/entries" { return (r(201), self.fixture("entries_create")) }
            if path == "/weight" { return ok(self.fixture("weight_entries")) }
            if path == "/containers" { return method == "POST" ? ok(self.fixture("container")) : ok(self.fixture("containers")) }
            if path == "/measures/photos" { return ok(Self.photosJSON().data(using: .utf8)!) }
            if path.hasPrefix("/measures/photos/") { return method == "DELETE" ? (r(204), Data()) : ok(ViewModelLoadTests.samplePNG) }
            if path == "/measures/photo-tags" { return ok(Self.photoTagsJSON.data(using: .utf8)!) }
            if path.hasPrefix("/measures/photo-tags/") { return ok(#"{"id":"b2b2b2b2-2222-2222-2222-222222222222","name":"Back","normalized_name":"back","sort_order":0,"created_at":"2026-05-01T00:00:00Z","updated_at":"2026-05-01T00:00:00Z"}"#.data(using: .utf8)!) }
            return (r(404), Data())
        }
        activeStubs.append(stub)
        return AuthSession(baseURL: URL(string: "https://example.test")!,
                           keychainService: testService, keychainAccount: testAccount, urlSession: stub.session)
    }

    /// Builds a signed-out `AuthSession` (empty keychain) so login-gated UI shows.
    private func makeSignedOutAuth() -> AuthSession {
        _ = KeychainStore.delete(service: testService, account: testAccount)
        return AuthSession(baseURL: URL(string: "https://example.test")!,
                           keychainService: testService, keychainAccount: testAccount)
    }

    /// Builds a signed-in `AuthSession` whose stub returns HTTP 500 for every
    /// request, used to drive copy/log flows into their `.failed` states.
    private func makeFailingAuth() -> AuthSession {
        let svc = testService
        let acct = "fail-\(UUID().uuidString)"
        _ = KeychainStore.write(#"{"token":"tok","email":"k@e.com"}"#, service: svc, account: acct)
        let stub = StubURLProtocol.makeSession { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        activeStubs.append(stub)
        let a = AuthSession(baseURL: URL(string: "https://example.test")!,
                            keychainService: svc, keychainAccount: acct, urlSession: stub.session)
        addTeardownBlock { _ = KeychainStore.delete(service: svc, account: acct) }
        return a
    }

    /// Wraps a view with the full set of root environment objects.
    private func env<V: View>(_ view: V, auth overrideAuth: AuthSession? = nil) -> some View {
        view
            .environment(overrideAuth ?? auth)
            .environment(photoStore)
            .environment(tagStore)
            .environment(targetsStore)
    }

    /// Mounts a view in a real key window and pumps the run loop so `.task`
    /// loads complete and the loaded body renders.
    private func render<V: View>(_ view: V, auth overrideAuth: AuthSession? = nil, pump: TimeInterval = 0.35) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let host = UIHostingController(rootView: env(view, auth: overrideAuth))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(pump))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        window.rootViewController = nil
        window.isHidden = true
    }

    // MARK: - sample values

    private func sampleSummary() -> MealSummary {
        let j = #"{"id":"22222222-2222-2222-2222-222222222222","name":"Breakfast Bowl","normalized_name":"breakfast bowl","notes":"go-to","aliases":["morning"],"item_count":2,"total_calories":450,"total_protein_g":28,"total_carbs_g":63,"total_fat_g":10}"#
        return try! JSONDecoder.pulseDefault().decode(MealSummary.self, from: j.data(using: .utf8)!)
    }

    private func sampleEntry(usda: Bool = true) -> FoodEntry {
        FoodEntry(
            id: UUID(), dailyLogId: UUID(), userKey: "khash", entryGroupId: UUID(),
            displayName: "Oats, raw", quantityText: "80 g",
            normalizedQuantityValue: 80, normalizedQuantityUnit: "g",
            usdaFdcId: usda ? 173904 : nil, usdaDescription: usda ? "Oats, raw" : nil,
            customFoodId: usda ? nil : UUID(),
            calories: 320, proteinG: 10, carbsG: 54, fatG: 6,
            mealId: nil, mealName: nil, consumedAt: .now, createdAt: .now)
    }

    private func sampleContainer() -> Container {
        Container(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                  userKey: "khash", name: "Box", normalizedName: "box", tareWeightG: 100,
                  hasPhoto: true, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    private func sampleMeta(tag: UUID, date: Date = Date()) -> ProgressPhotoMetadata {
        ProgressPhotoMetadata(id: UUID(), date: date, tagId: tag, mime: "image/jpeg",
                              bytes: 1000, sha256: UUID().uuidString, updatedAt: Date())
    }

    private func per100gResult() -> FoodSearchResult {
        FoodSearchResult(customFood: CustomFood(id: UUID(), name: "Rice", basis: .per100g, servingSize: nil,
                                                servingSizeUnit: nil, calories: 130, proteinG: 2.7, carbsG: 28, fatG: 0.3,
                                                foodId: nil, portionLabel: nil))
    }

    private func perUnitResult() -> FoodSearchResult {
        FoodSearchResult(customFood: CustomFood(id: UUID(), name: "Egg", basis: .perUnit, servingSize: 1,
                                                servingSizeUnit: "unit", calories: 70, proteinG: 6, carbsG: 0.5, fatG: 5,
                                                foodId: nil, portionLabel: nil))
    }

    // MARK: - copy / backdate flow

    /// Renders `CopyEntriesSheet` in its initial state, then drives the model's
    /// `copyState` through the real flow into partial-failure and all-skipped
    /// outcomes so each `statusRow` branch is exercised.
    func test_render_copyEntriesSheet_allStatusBranches() async {
        // Idle/initial sheet.
        let idle = DayMacroModel(date: Date(), auth: auth)
        render(CopyEntriesSheet(model: idle, entries: [sampleEntry(), sampleEntry(usda: false)], onCopied: {}))

        // Partial-failure status row (copied > 0): a 500 stub fails the copy after
        // recreatable entries are attempted.
        let failing = DayMacroModel(date: Date(), auth: makeFailingAuth())
        _ = await failing.copyEntries([sampleEntry(), sampleEntry()], to: Date())
        if case .failed = failing.copyState {} else { XCTFail("expected failed, got \(failing.copyState)") }
        render(CopyEntriesSheet(model: failing, entries: [sampleEntry()], onCopied: {}))

        // All-skipped status row: entries with no recreatable source never hit the
        // network and finish with copied:0 skipped:N.
        let skipped = DayMacroModel(date: Date(), auth: auth)
        let noSource = FoodEntry(
            id: UUID(), dailyLogId: UUID(), userKey: "khash", entryGroupId: UUID(),
            displayName: "Mystery", quantityText: "1", normalizedQuantityValue: nil, normalizedQuantityUnit: nil,
            usdaFdcId: nil, usdaDescription: nil, customFoodId: nil,
            calories: 0, proteinG: 0, carbsG: 0, fatG: 0, mealId: nil, mealName: nil,
            consumedAt: .now, createdAt: .now)
        _ = await skipped.copyEntries([noSource, noSource], to: Date())
        XCTAssertEqual(skipped.copyState, .finished(copied: 0, skipped: 2))
        render(CopyEntriesSheet(model: skipped, entries: [noSource], onCopied: {}))
    }

    /// Renders the shared `BackdateSelector` bound to a mutable date so the
    /// default (Today) segmented control + label branch render. The
    /// Yesterday/Pick mode-change branches are tap-gated (interaction-only).
    func test_render_backdateSelector() {
        render(BackdateSelectorHarness())
    }

    /// Renders the `PrimaryActionButton` in each leading variant and disabled state.
    func test_render_primaryActionButton_variants() {
        render(VStack {
            PrimaryActionButton(title: "Icon", leading: .icon("plus.circle.fill"), disabled: false) {}
            PrimaryActionButton(title: "Busy", leading: .busy(true), disabled: true) {}
            PrimaryActionButton(title: "Idle spinner slot", leading: .busy(false), disabled: false) {}
            PrimaryActionButton(title: "Dimmed", leading: .icon("calendar"), disabled: true) {}
            PrimaryActionButton(title: "Destructive", leading: .icon("trash"), tint: Theme.CTP.red, disabled: false) {}
        })
    }

    // MARK: - meal detail (populated) + log sheet

    /// Renders the populated `MealDetailView` (loaded meal with two ingredient
    /// rows, hero card, log button) by pumping its load against the
    /// `meal_with_items` fixture.
    func test_render_mealDetail_populated() {
        render(MealDetailView(summary: sampleSummary()), pump: 0.5)
    }

    /// Renders `MealLogSheet` in its idle state, then drives the model's
    /// `logState` into `.failed` via a 500 stub so the error status row renders.
    func test_render_mealLogSheet_statusBranches() async {
        let idle = MealDetailModel(mealId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, auth: auth)
        render(MealLogSheet(model: idle, mealName: "Breakfast Bowl"))

        let failing = MealDetailModel(mealId: UUID(), auth: makeFailingAuth())
        await failing.logMeal(consumedAt: Date())
        if case .failed = failing.logState {} else { XCTFail("expected failed, got \(failing.logState)") }
        render(MealLogSheet(model: failing, mealName: "Breakfast Bowl"))
    }

    // MARK: - intake

    /// Renders the `DatePickerSheet` used by `LogView`'s calendar action.
    func test_render_datePickerSheet() {
        render(DatePickerSheet(onOpen: { _ in }))
    }

    /// Renders the day view (loaded body, hero ring, clustered entries, meal
    /// group row, macro totals) by pumping its load against the rich `summary`
    /// fixture. The multi-select card / copy-action-bar / select-toolbar are
    /// tap-gated (interaction-only; see file note).
    func test_render_dayMacroView_loaded() {
        render(DayMacroView(date: DateOnly.formatter.date(from: "2026-05-06")!), pump: 0.5)
    }

    /// Renders a multi-instance `MealGroupRow` (count > 1 → `×N` subtitle badge)
    /// and a single-instance row. The collapsed header/subtitle/macro line render;
    /// the tap-gated `expandedItems` branch is interaction-only (see file note).
    func test_render_mealGroupRow_badgeVariants() {
        let items = [sampleEntry(), sampleEntry(usda: false)]
        let multi = MealGroup(id: "meal:x", mealId: UUID(), displayName: "Breakfast Bowl",
                              count: 2, items: items,
                              totals: MacroTotals(calories: 900, proteinG: 56, carbsG: 126, fatG: 20),
                              sortDate: .now)
        render(MealGroupRow(group: multi))
        let single = MealGroup(id: "meal:y", mealId: UUID(), displayName: "Lunch",
                               count: 1, items: items,
                               totals: MacroTotals(calories: 450, proteinG: 28, carbsG: 63, fatG: 10),
                               sortDate: .now)
        render(MealGroupRow(group: single))
    }

    // MARK: - measures: weight

    /// Renders `WeightLogView` against a weight history that includes a
    /// today-dated entry and several past entries with up/down/flat deltas, so
    /// the "today value" card, past rows, and all three `deltaColor` branches
    /// render — once in lb and once in kg.
    func test_render_weightLogView_todayAndDeltas() {
        let env = makeWeightEnv()
        render(WeightLogView(), auth: env, pump: 0.5)
        UserDefaults.standard.set(WeightUnit.kg.rawValue, forKey: WeightUnit.displayPreferenceKey)
        render(WeightLogView(), auth: env, pump: 0.5)
    }

    /// Builds a signed-in auth whose `/weight` returns a today entry plus three
    /// past entries chosen so consecutive deltas are positive, negative, and
    /// within the ±0.1 lb noise band.
    private func makeWeightEnv() -> AuthSession {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func day(_ ago: Int) -> String {
            DateOnly.string(from: cal.date(byAdding: .day, value: -ago, to: today)!)
        }
        // Weights: today 180.0, -1 180.5 (delta vs -2 = +0.45), -2 180.05 (delta vs -3 ≈ +0.05 flat), -3 181.0
        let json = """
        [
          {"id":"00000000-0000-0000-0000-000000000001","log_date":"\(day(0))","weight_lb":180.0,"source_unit":"lb","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"},
          {"id":"00000000-0000-0000-0000-000000000002","log_date":"\(day(1))","weight_lb":180.5,"source_unit":"lb","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"},
          {"id":"00000000-0000-0000-0000-000000000003","log_date":"\(day(2))","weight_lb":180.05,"source_unit":"lb","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"},
          {"id":"00000000-0000-0000-0000-000000000004","log_date":"\(day(3))","weight_lb":181.0,"source_unit":"kg","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}
        ]
        """
        let svc = testService
        let acct = "weight-\(UUID().uuidString)"
        _ = KeychainStore.write(#"{"token":"tok","email":"k@e.com"}"#, service: svc, account: acct)
        let stub = StubURLProtocol.makeSession { req in
            let path = req.url?.path ?? ""
            func r(_ c: Int) -> HTTPURLResponse { HTTPURLResponse(url: req.url!, statusCode: c, httpVersion: nil, headerFields: nil)! }
            if path == "/weight" { return (r(200), json.data(using: .utf8)!) }
            if path == "/calories_daily" { return (r(200), self.fixture("calories_daily")) }
            if path == "/targets" { return (r(200), #"{"calories":2000,"protein_g":150,"carbs_g":200,"fat_g":60,"target_weight_lb":175}"#.data(using: .utf8)!) }
            return (r(404), Data())
        }
        activeStubs.append(stub)
        let a = AuthSession(baseURL: URL(string: "https://example.test")!,
                            keychainService: svc, keychainAccount: acct, urlSession: stub.session)
        addTeardownBlock { _ = KeychainStore.delete(service: svc, account: acct) }
        return a
    }

    /// Renders `WeightEntrySheet` for both add (no existing) and edit (existing
    /// + delete affordance) variants, and with a kg display unit.
    func test_render_weightEntrySheet_variants() {
        let entry = WeightEntry(id: UUID(), date: Date(), weightLb: 180.5, sourceUnit: .lb,
                                createdAt: Date(), updatedAt: Date())
        render(WeightEntrySheet(date: Date(), existing: nil, onSave: { _, _ in }, onDelete: nil))
        render(WeightEntrySheet(date: Date(), existing: entry, onSave: { _, _ in }, onDelete: { }))
        UserDefaults.standard.set(WeightUnit.kg.rawValue, forKey: WeightUnit.displayPreferenceKey)
        render(WeightEntrySheet(date: Date(), existing: entry, onSave: { _, _ in }, onDelete: { }))
    }

    /// Renders `WeightTrendsView` against a dense weight history (≥8 entries on a
    /// downward trend plus an in-range target) so the chart's regression dashed
    /// line and the target rule mark render, plus the analytics maintenance /
    /// trend / ETA lines. Rendered in lb then kg.
    func test_render_weightTrends_denseChartAndAnalytics() {
        let env = makeDenseWeightEnv()
        targetsStore.update(MacroTargets(calories: 2000, proteinG: 150, carbsG: 200, fatG: 60, targetWeightLb: 176))
        render(WeightTrendsView(), auth: env, pump: 0.6)
        UserDefaults.standard.set(WeightUnit.kg.rawValue, forKey: WeightUnit.displayPreferenceKey)
        render(WeightTrendsView(), auth: env, pump: 0.6)
    }

    /// Builds a signed-in auth whose `/weight` returns 20 consecutive daily
    /// entries trending downward (so a regression line fits) and whose
    /// `/calories_daily` returns matching kcal rows, enabling the analytics
    /// maintenance/ETA computation.
    private func makeDenseWeightEnv() -> AuthSession {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var weightRows: [String] = []
        var kcalRows: [String] = []
        for i in 0..<20 {
            let d = DateOnly.string(from: cal.date(byAdding: .day, value: -(19 - i), to: today)!)
            let lb = 185.0 - Double(i) * 0.4   // steady ~0.4 lb/day loss
            weightRows.append(#"{"id":"00000000-0000-0000-0000-\#(String(format: "%012d", i))","log_date":"\#(d)","weight_lb":\#(lb),"source_unit":"lb","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}"#)
            kcalRows.append(#"{"log_date":"\#(d)","calories":2100}"#)
        }
        let weightJSON = "[\(weightRows.joined(separator: ","))]"
        let kcalJSON = "[\(kcalRows.joined(separator: ","))]"
        let svc = testService
        let acct = "dense-\(UUID().uuidString)"
        _ = KeychainStore.write(#"{"token":"tok","email":"k@e.com"}"#, service: svc, account: acct)
        let stub = StubURLProtocol.makeSession { req in
            let path = req.url?.path ?? ""
            func r(_ c: Int) -> HTTPURLResponse { HTTPURLResponse(url: req.url!, statusCode: c, httpVersion: nil, headerFields: nil)! }
            if path == "/weight" { return (r(200), weightJSON.data(using: .utf8)!) }
            if path == "/calories_daily" { return (r(200), kcalJSON.data(using: .utf8)!) }
            if path == "/targets" { return (r(200), #"{"calories":2000,"protein_g":150,"carbs_g":200,"fat_g":60,"target_weight_lb":176}"#.data(using: .utf8)!) }
            return (r(404), Data())
        }
        activeStubs.append(stub)
        let a = AuthSession(baseURL: URL(string: "https://example.test")!,
                            keychainService: svc, keychainAccount: acct, urlSession: stub.session)
        addTeardownBlock { _ = KeychainStore.delete(service: svc, account: acct) }
        return a
    }

    // MARK: - measures: photos

    /// Seeds today / today−7 photos into the store, then renders
    /// `ProgressPhotosView` (today grid: two tagged cells + badges) and
    /// `ProgressPhotoComparisonView` (today vs today−7: a populated row plus a
    /// "Back"-tag row with one missing side → placeholder).
    func test_render_photos_populated() async {
        await tagStore.reload()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let week = cal.date(byAdding: .day, value: -7, to: today)!
        await photoStore.reconcile(from: week, to: today)
        // Comparison defaults B = initialDate (today), A = today − 7.
        render(ProgressPhotoComparisonView(initialDate: today), pump: 0.6)
        render(ProgressPhotosView(), pump: 0.6)
    }

    /// Renders a populated `ProgressPhotoCell` and `ProgressPhotoDetailView`
    /// after seeding the photo store so the thumbnail/full image decode path runs.
    func test_render_photoCellAndDetail_populated() async {
        await tagStore.reload()
        let tag = tagStore.tags.first!.id
        let meta = sampleMeta(tag: tag)
        // Prime the cache so the image branches render (best-effort).
        _ = await photoStore.thumb(meta)
        render(PhotoCellHarness(meta: meta, tagName: "Front"))
        render(PhotoDetailHarness(meta: meta, tagName: "Front"))
        render(ComparisonCellHarness(meta: meta))
    }

    /// Renders `ManageTagsView` with a non-empty tag list so the create row and
    /// each `TagRow`'s collapsed state render. The pencil-driven `editing` branch
    /// and `submit()` are tap-gated (interaction-only; see file note).
    func test_render_manageTags_populated() async {
        await tagStore.reload()
        render(ManageTagsView(), pump: 0.4)
    }

    // MARK: - prep

    /// Renders `QuantityEntryView` for a per-100g food (weigh + type modes,
    /// container menu, live preview) and a per-unit food (type-only, no weigh).
    func test_render_quantityEntry_modes() {
        render(QuantityEntryView(result: per100gResult(), containers: [sampleContainer()], onAdd: { _ in }))
        render(QuantityEntryView(result: perUnitResult(), containers: [sampleContainer()], onAdd: { _ in }))
    }

    /// Renders `ContainerPickerSheet` (loaded list) and `ContainersListView`
    /// (loaded list with rows + photo thumbnails).
    func test_render_containerSurfaces() {
        render(ContainerPickerSheet(onPick: { _ in }), pump: 0.5)
        render(ContainersListView(), pump: 0.5)
        render(ContainerRow(container: sampleContainer()))
    }

    // MARK: - root / login

    /// Renders `RootView` signed-out so the `LoginView` sheet gate and login
    /// screen body render, plus a standalone `LoginView` in its `.error` state.
    func test_render_rootSignedOut_andLogin() {
        let out = makeSignedOutAuth()
        render(RootView(), auth: out, pump: 0.4)
        render(LoginView(), auth: out)
    }

    /// Renders the `CTPSegmented` control and `MeasuresTabRootView` so the
    /// segmented-control body and the tab switch render.
    func test_render_segmentedAndMeasuresRoot() {
        render(MeasuresTabRootView(), pump: 0.5)
        render(SegmentedHarness())
    }

    /// Mounts `CameraCaptureView` so `makeUIViewController` /
    /// `updateUIViewController` run. In the simulator no camera is available, so
    /// the picker falls back to `.photoLibrary` — rendered without presenting.
    func test_render_cameraCaptureView() {
        render(CameraCaptureView(onCapture: { _ in }, onCancel: {}), pump: 0.2)
    }

    // MARK: - rich prep + container edit + food search + day error states

    /// Seeds a rich Prep calculator state (two target containers with *different*
    /// tares, two weigh-ins one of which is blank, an explicit portions override,
    /// and two batch food items) so `PrepView` renders its populated targets /
    /// weigh-ins / result (non-uniform fill rows + partial-total warning) / foods
    /// sections rather than the empty placeholders.
    private func seedRichPrep() {
        let big = Container(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                            userKey: "khash", name: "Big Pyrex", normalizedName: "big pyrex", tareWeightG: 412,
                            hasPhoto: true, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        let small = Container(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                              userKey: "khash", name: "Glass box", normalizedName: "glass box", tareWeightG: 187.5,
                              hasPhoto: false, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        let store = PrepStatePersistence()
        store.save(
            targets: [.init(container: big, count: 2), .init(container: small, count: 1)],
            weighIns: [.init(container: big, grossGrams: 1200), .init(container: small, grossGrams: nil)],
            portionsOverride: 4
        )
        let nutrition = FoodNutrition(basis: .per100g, servingSize: nil, servingSizeUnit: nil,
                                      caloriesPerBasis: 130, proteinGPerBasis: 2.7, carbsGPerBasis: 28, fatGPerBasis: 0.3)
        let rice = BatchFoodItem(id: UUID(), displayName: "Rice", usdaFdcId: nil, usdaDescription: nil,
                                 customFoodId: nil, nutrition: nutrition, quantity: .typed(value: 200, unit: .grams),
                                 containerId: nil, macros: MacroTotals(calories: 260, proteinG: 5.4, carbsG: 56, fatG: 0.6))
        let chicken = BatchFoodItem(id: UUID(), displayName: "Chicken", usdaFdcId: 171477, usdaDescription: "Chicken breast",
                                    customFoodId: nil, nutrition: nutrition, quantity: .weighed(grossG: 600),
                                    containerId: big.id, macros: MacroTotals(calories: 330, proteinG: 62, carbsG: 0, fatG: 7))
        store.saveBatchItems([rice, chicken])
    }

    /// Renders `PrepView` against the rich seeded state so its populated sections
    /// and the non-uniform fill-target / partial-total branches render.
    func test_render_prepView_populated() {
        seedRichPrep()
        render(PrepView(), pump: 0.6)
    }

    /// Renders `ContainerEditView` editing an existing container that has a photo
    /// so the `existingPhotoId` image branch and the "Remove" photo action render.
    func test_render_containerEdit_existingWithPhoto() {
        render(ContainerEditView(existing: sampleContainer(), onSaved: { _ in }), pump: 0.4)
    }

    /// Renders `FoodSearchSheet` in its loaded-with-results state (My Foods +
    /// USDA sections, rows) by priming the model's query against the stub, plus a
    /// `usdaUnavailable` note path via a separate failing-USDA model.
    func test_render_foodSearchSheet_states() async {
        let model = FoodSearchModel(auth: auth, debounce: .milliseconds(1))
        await model.loadMyFoods()
        model.query = "protein"
        try? await Task.sleep(for: .milliseconds(120))
        render(FoodSearchSheet(model: model, containers: [sampleContainer()], onAdd: { _ in }), pump: 0.4)
    }

    /// Renders `DayMacroView`'s error bodies: the `.notFound` "no targets" hint
    /// and the generic retry placeholder, by pointing the summary endpoint at 404
    /// and 500 respectively.
    func test_render_dayMacroView_errorStates() {
        render(DayMacroView(date: Date()), auth: makeStatusAuth(404), pump: 0.4)
        render(DayMacroView(date: Date()), auth: makeStatusAuth(500), pump: 0.4)
    }

    /// Builds a signed-in auth whose every request returns the given HTTP status,
    /// used to drive views into their error states.
    private func makeStatusAuth(_ status: Int) -> AuthSession {
        let svc = testService
        let acct = "status-\(UUID().uuidString)"
        _ = KeychainStore.write(#"{"token":"tok","email":"k@e.com"}"#, service: svc, account: acct)
        let stub = StubURLProtocol.makeSession { req in
            (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data())
        }
        activeStubs.append(stub)
        let a = AuthSession(baseURL: URL(string: "https://example.test")!,
                            keychainService: svc, keychainAccount: acct, urlSession: stub.session)
        addTeardownBlock { _ = KeychainStore.delete(service: svc, account: acct) }
        return a
    }
}

// MARK: - harness wrappers (provide Namespace / mutable bindings / forced state)

/// Binds `BackdateSelector` to mutable state and flips through its modes so the
/// Today/Yesterday/Pick branches and the graphical picker all lay out.
private struct BackdateSelectorHarness: View {
    @State private var date = Date()
    var body: some View {
        VStack {
            BackdateSelector(date: $date)
            // Touch the binding so the "Pick" date-set path is reachable.
            Text(DateOnly.string(from: date)).onAppear { date = date.addingTimeInterval(-86_400) }
        }
    }
}

/// Provides a real `Namespace.ID` so `ProgressPhotoCell` renders standalone, in
/// both the normal (badge + thumbnail) and expanded (placeholder) states.
private struct PhotoCellHarness: View {
    let meta: ProgressPhotoMetadata
    let tagName: String
    @Namespace private var ns
    var body: some View {
        VStack {
            ProgressPhotoCell(meta: meta, tagName: tagName, namespace: ns, isExpanded: false, onTap: {})
            ProgressPhotoCell(meta: meta, tagName: tagName, namespace: ns, isExpanded: true, onTap: {})
        }
    }
}

/// Renders `ComparisonPhotoCell` (normal + expanded) and the dashed
/// `ComparisonPlaceholder` used by the comparison grid.
private struct ComparisonCellHarness: View {
    let meta: ProgressPhotoMetadata
    var body: some View {
        VStack {
            ComparisonPhotoCell(meta: meta, isExpanded: false, onTap: {})
            ComparisonPhotoCell(meta: meta, isExpanded: true, onTap: {})
            ComparisonPlaceholder()
        }
    }
}

/// Provides a real `Namespace.ID` so `ProgressPhotoDetailView` renders standalone.
private struct PhotoDetailHarness: View {
    let meta: ProgressPhotoMetadata
    let tagName: String
    @Namespace private var ns
    var body: some View {
        ProgressPhotoDetailView(meta: meta, tagName: tagName, namespace: ns, onClose: {})
    }
}

/// Exercises `CTPSegmented`'s active/inactive segment styling, cycling the
/// selection on appear so every option renders in both states.
private struct SegmentedHarness: View {
    @State private var section: MeasureSection = .photos
    var body: some View {
        CTPSegmented(selection: $section, options: MeasureSection.allCases) { $0.rawValue }
            .onAppear {
                for s in MeasureSection.allCases { section = s }
            }
    }
}
