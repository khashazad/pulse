// PulseTests/ViewRenderTests.swift
/// Host-render smoke tests: each screen is mounted in a `UIHostingController`,
/// laid out, and given a brief run-loop pump so its async `.task` loads complete
/// and re-render (exercising loaded-state bodies and nested component views).
/// These assert the views render without crashing against a signed-in stub
/// backend; they are coverage/no-crash tests, not content assertions.
import XCTest
import SwiftUI
@testable import Pulse

@MainActor
final class ViewRenderTests: XCTestCase {
    private let testService = "com.pulseapp.pulse.session.test"
    private var testAccount = ""
    private var activeStubs: [StubURLProtocol.Registration] = []
    private var targetsStore = UserTargetsStore()
    private var auth: AuthSession!
    private var photoStore: ProgressPhotoStore!
    private var tagStore: ProgressPhotoTagStore!

    override func setUp() {
        super.setUp()
        testAccount = "vr-\(UUID().uuidString)"
        auth = makeAuth()
        photoStore = ProgressPhotoStore(auth: auth)
        tagStore = ProgressPhotoTagStore(auth: auth)
    }

    override func tearDown() {
        activeStubs.forEach { $0.invalidate() }
        activeStubs = []
        _ = KeychainStore.delete(service: testService, account: testAccount)
        ["prep.targets", "prep.weighIns", "prep.portionsOverride", "prep.batchItems"]
            .forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    /// Seeds persisted Prep state (matching a container id in `containers.json`) so
    /// rendering `PrepView` exercises its populated weigh-in / result / foods branches.
    private func seedPrep() {
        let c = Container(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                          userKey: "khash", name: "Box", normalizedName: "box", tareWeightG: 100,
                          hasPhoto: false, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        let store = PrepStatePersistence()
        store.save(targets: [.init(container: c, count: 2)],
                   weighIns: [.init(container: c, grossGrams: 640)],
                   portionsOverride: 4)
        let item = BatchFoodItem(
            id: UUID(), displayName: "Rice", usdaFdcId: nil, usdaDescription: nil, customFoodId: nil,
            nutrition: FoodNutrition(basis: .per100g, servingSize: nil, servingSizeUnit: nil,
                                     caloriesPerBasis: 130, proteinGPerBasis: 2.7, carbsGPerBasis: 28, fatGPerBasis: 0.3),
            quantity: .typed(value: 200, unit: .grams), containerId: nil,
            macros: MacroTotals(calories: 260, proteinG: 5.4, carbsG: 56, fatG: 0.6))
        store.saveBatchItems([item])
    }

    private func sampleMeta() -> ProgressPhotoMetadata {
        ProgressPhotoMetadata(id: UUID(), date: Date(), tagId: UUID(), mime: "image/jpeg",
                              bytes: 1000, sha256: "abc123", updatedAt: Date())
    }

    private func fixture(_ name: String) -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")!
        return try! Data(contentsOf: url)
    }

    /// Builds a signed-in AuthSession whose client routes requests to fixtures by path.
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
            if path.hasPrefix("/meals/") { return ok(#"{"id":"22222222-2222-2222-2222-222222222222","user_key":"khash","name":"Wrap","normalized_name":"wrap","notes":null,"created_at":"2026-05-10T12:00:00Z","updated_at":"2026-05-10T12:00:00Z","items":[]}"#.data(using: .utf8)!) }
            if path == "/foods" { return ok(self.fixture("foods")) }
            if path == "/custom-foods" { return ok(self.fixture("custom_foods")) }
            if path == "/food-memory" { return ok(self.fixture("food_memory")) }
            if path == "/usda/search" { return ok(self.fixture("usda_search")) }
            if path == "/weight" { return ok(self.fixture("weight_entries")) }
            if path == "/containers" { return method == "POST" ? ok(self.fixture("container")) : ok(self.fixture("containers")) }
            if path == "/measures/photos" { return ok(self.fixture("progress_photos")) }
            if path.hasPrefix("/measures/photos/") { return method == "DELETE" ? (r(204), Data()) : ok(ViewModelLoadTests.samplePNG) }
            if path == "/measures/photo-tags" { return ok(self.fixture("photo_tags")) }
            if path.hasPrefix("/measures/photo-tags/") { return ok(#"{"id":"b2b2b2b2-2222-2222-2222-222222222222","name":"Back","normalized_name":"back","sort_order":0,"created_at":"2026-05-01T00:00:00Z","updated_at":"2026-05-01T00:00:00Z"}"#.data(using: .utf8)!) }
            return (r(404), Data())
        }
        activeStubs.append(stub)
        let a = AuthSession(baseURL: URL(string: "https://example.test")!,
                            keychainService: testService, keychainAccount: testAccount, urlSession: stub.session)
        return a
    }

    /// Wraps a view with the full set of root environment objects.
    private func env<V: View>(_ view: V) -> some View {
        view
            .environment(auth)
            .environment(photoStore)
            .environment(tagStore)
            .environment(targetsStore)
    }

    /// Mounts a view in a real key window (SwiftUI only evaluates `body` when
    /// attached to a visible window), pumps the run loop so async `.task` loads
    /// complete and re-render, then lays out again.
    private func render<V: View>(_ view: V, pump: TimeInterval = 0.35) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let host = UIHostingController(rootView: env(view))
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

    private func sampleSummary() -> MealSummary {
        let j = #"{"id":"11111111-1111-1111-1111-111111111111","name":"Wrap","normalized_name":"wrap","notes":null,"aliases":[],"item_count":0,"total_calories":0,"total_protein_g":0,"total_carbs_g":0,"total_fat_g":0}"#
        return try! JSONDecoder.pulseDefault().decode(MealSummary.self, from: j.data(using: .utf8)!)
    }
    private func sampleContainer() -> Container {
        Container(id: UUID(), userKey: "khash", name: "Box", normalizedName: "box", tareWeightG: 100,
                  hasPhoto: false, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }
    private func sampleResult() -> FoodSearchResult {
        FoodSearchResult(customFood: CustomFood(id: UUID(), name: "Rice", basis: .per100g, servingSize: nil,
                                                servingSizeUnit: nil, calories: 130, proteinG: 2.7, carbsG: 28, fatG: 0.3,
                                                foodId: nil, portionLabel: nil))
    }

    // MARK: - renders (grouped so one crash doesn't lose the others)

    func test_render_root() {
        render(RootView())
    }

    func test_render_intake() {
        render(WeekView())
        render(MonthView())
        render(YearView())
        render(DayMacroView(date: Date()))
        render(LogView(onOpenDate: { _ in }))
    }

    func test_render_meals() {
        render(FoodTabView(
            mealsModel: MealsModel(auth: auth),
            foodsModel: FoodsModel(auth: auth),
            onOpenMeal: { _ in },
            onOpenFood: { _ in },
            onOpenPortion: { _ in },
            auth: auth
        ))
        render(MealDetailView(summary: sampleSummary()))
    }

    func test_render_prep() {
        seedPrep()
        render(PrepView())
        render(ContainerEditView(existing: nil, onSaved: { _ in }))
        render(ContainerEditView(existing: sampleContainer(), onSaved: { _ in }))
        render(ContainerPickerSheet(onPick: { _ in }))
        render(ContainersListView())
        let fsModel = FoodSearchModel(auth: auth, debounce: .milliseconds(1))
        fsModel.query = "rice"
        render(FoodSearchSheet(model: fsModel, containers: [sampleContainer()], onAdd: { _ in }), pump: 0.5)
        render(QuantityEntryView(result: sampleResult(), containers: [sampleContainer()], onAdd: { _ in }))
    }

    func test_render_measures() {
        render(MeasuresTabRootView())
        render(WeightLogView())
        render(WeightTrendsView())
        render(WeightEntrySheet(date: Date(), onSave: { _, _, _ in }, onDelete: { _ in }))
        render(ProgressPhotosView())
        render(ProgressPhotoComparisonView(initialDate: Date()))
        render(ManageTagsView())
        render(PhotoCellWrapper(meta: sampleMeta()))
        render(PhotoDetailWrapper(meta: sampleMeta()))
        let sampleTag = ProgressPhotoTag(
            id: UUID(),
            name: "front",
            normalizedName: "front",
            sortOrder: 0,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        render(ProgressGalleryView())
        let older = ProgressPhotoMetadata(
            id: UUID(),
            date: DateOnly.formatter.date(from: "2026-05-01")!,
            tagId: sampleTag.id,
            mime: "image/jpeg",
            bytes: 1_024,
            sha256: "older",
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let newer = ProgressPhotoMetadata(
            id: UUID(),
            date: DateOnly.formatter.date(from: "2026-05-15")!,
            tagId: sampleTag.id,
            mime: "image/jpeg",
            bytes: 1_024,
            sha256: "newer",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        render(PhotoPairComparisonView(older: older, newer: newer, initialTag: sampleTag))
    }

    func test_render_settings() {
        render(SettingsView())
    }

    func test_render_camera() {
        render(PhotoCaptureSession(date: Date()))
    }

    func test_render_components() {
        render(MacroRing(consumed: 1500, target: 2000))
        render(MacroDistributionBar(proteinG: 30, carbsG: 50, fatG: 20))
        render(AverageMacrosTable(avgKcal: 1800, avgProteinG: 120, avgCarbsG: 180, avgFatG: 55))
        render(MacroTotalsRow(
            totals: MacroTotals(calories: 1500, proteinG: 100, carbsG: 150, fatG: 50),
            targets: MacroTargets(calories: 2000, proteinG: 150, carbsG: 200, fatG: 60, targetWeightLb: nil)))
    }
}

/// Renders `ProgressPhotoCell` standalone for the render smoke tests.
private struct PhotoCellWrapper: View {
    let meta: ProgressPhotoMetadata
    var body: some View {
        ProgressPhotoCell(meta: meta, tagName: "Front", onTap: {})
    }
}

/// Renders `ProgressPhotoDetailView` standalone for the render smoke tests.
private struct PhotoDetailWrapper: View {
    let meta: ProgressPhotoMetadata
    var body: some View {
        ProgressPhotoDetailView(meta: meta, tagName: "Front", onClose: {})
    }
}
