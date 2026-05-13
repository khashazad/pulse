# Weight Tracking — iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `../specs/2026-05-13-weight-tracking-ios-design.md`
**Companion server plan:** `../../../../diet-tracker-server/docs/superpowers/plans/2026-05-13-weight-tracking-server.md`

**Goal:** New "Weight" tab with daily logging and a Trends sub-screen that shows weight over time, a rate-vs-kcal regression, and an analytics card with maintenance kcal + ETA. Rename existing "Log" tab to "Intake".

**Architecture:** Pure-value `WeightAnalytics` module does OLS regression on rolling 7-day windows. `WeightLogModel` / `WeightTrendsModel` follow the existing `@Observable` + `LoadState<T>` pattern (auth via `weak var auth: AuthSession?`). SwiftUI `Charts` for both plots.

**Tech Stack:** Swift 5.9, SwiftUI, iOS 17+, `Charts` framework, xcodegen for the project file, XCTest with `StubURLProtocol` for client tests.

**Repo:** `diet-tracker-ios`. Server-side endpoints (`/weight*`, `/calories_daily`, extended `/targets`) must be deployed before integration.

**Build note:** Source files in `DietTracker/` are auto-discovered by xcodegen (`sources: [path: DietTracker]`), so adding a `.swift` file just means running `source .envrc && xcodegen generate` before the next build. Tests likewise auto-discovered in `DietTrackerTests/`.

---

## File Map

Creates:
- `DietTracker/Models/WeightEntry.swift` — Codable struct + `WeightUnit` enum.
- `DietTracker/Models/CaloriesDailyRow.swift` — Codable struct for the new endpoint.
- `DietTracker/Networking/WeightFormatter.swift` — kg↔lb conversion + display helpers.
- `DietTracker/State/WeightAnalytics.swift` — pure regression module + result type.
- `DietTracker/State/WeightLogModel.swift` — log view model.
- `DietTracker/State/WeightTrendsModel.swift` — trends view model.
- `DietTracker/Views/Weight/WeightTabRootView.swift` — tab root with segmented control.
- `DietTracker/Views/Weight/WeightLogView.swift` — entries list + today card.
- `DietTracker/Views/Weight/WeightEntrySheet.swift` — modal editor.
- `DietTracker/Views/Weight/WeightTrendsView.swift` — charts + analytics card.
- `DietTrackerTests/WeightFormatterTests.swift`
- `DietTrackerTests/WeightAnalyticsTests.swift`
- `DietTrackerTests/WeightClientTests.swift`
- `DietTrackerTests/Fixtures/weight_entries.json`
- `DietTrackerTests/Fixtures/weight_entry.json`
- `DietTrackerTests/Fixtures/calories_daily.json`

Modifies:
- `DietTracker/Views/FloatingDock.swift` — `DockTab.log` → `.intake`, add `.weight` case.
- `DietTracker/Views/RootView.swift` — wire 4th tab and rename binding.
- `DietTracker/Networking/DietTrackerClient.swift` — add weight + calories_daily methods.
- `DietTracker/Models/MacroTargets.swift` — add `targetWeightLb: Double?`.
- `DietTracker/Views/SettingsView.swift` — add "Weight goal" + "Display unit" sections.
- `DietTracker/Views/LogView.swift` — update navigation title from "Log" to "Intake" (if a navigation title literal references "Log").

---

## Task 1: Rename `Log` dock tab to `Intake`

**Files:**
- Modify: `DietTracker/Views/FloatingDock.swift`
- Modify: `DietTracker/Views/RootView.swift`
- Modify: `DietTracker/Views/LogView.swift` (if any "Log" navigation title)

- [ ] **Step 1: Update `DockTab` enum + button label**

In `DietTracker/Views/FloatingDock.swift`:

Replace:

```swift
enum DockTab: Hashable {
    case log, meals, prep
}
```

with:

```swift
enum DockTab: Hashable {
    case intake, meals, prep
}
```

Replace:

```swift
tabButton(.log,   system: "circle.fill",  label: "Log")
```

with:

```swift
tabButton(.intake, system: "circle.fill", label: "Intake")
```

Update the preview at the bottom:

```swift
@Previewable @State var tab: DockTab = .intake
```

- [ ] **Step 2: Update `RootView.swift` to use `.intake`**

In `DietTracker/Views/RootView.swift`:

Replace:

```swift
@State private var tab: DockTab = .log
@State private var logPath = NavigationPath()
```

with:

```swift
@State private var tab: DockTab = .intake
@State private var intakePath = NavigationPath()
```

Replace the `case .log:` block in the `switch tab` body:

```swift
case .intake:
    NavigationStack(path: $intakePath) {
        LogView(onOpenDate: { picked in
            intakePath.append(picked)
        })
        .toolbar { settingsButton }
        .navigationDestination(for: Date.self) { date in
            DayMacroView(date: date)
                .toolbar { settingsButton }
        }
    }
```

Replace the `dockVisible` computed property:

```swift
private var dockVisible: Bool {
    switch tab {
    case .intake: intakePath.isEmpty
    case .meals:  mealsPath.isEmpty
    case .prep:   prepPath.isEmpty
    }
}
```

- [ ] **Step 3: Update the navigation title in `LogView.swift`**

Inspect `DietTracker/Views/LogView.swift` for `.navigationTitle("Log")` or similar. If present, change to `.navigationTitle("Intake")`. If `LogView` references a title via constants, change that too. If no title literal is present (depends on current code state), leave it.

Run: `grep -n '"Log"' DietTracker/Views/LogView.swift`

If results appear in `.navigationTitle(...)`, edit them to `"Intake"`. Otherwise skip.

- [ ] **Step 4: Regenerate the Xcode project and build**

Run:

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-ios
source .envrc && xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-ios
git add DietTracker/Views/FloatingDock.swift DietTracker/Views/RootView.swift DietTracker/Views/LogView.swift
git commit -m "feat(weight): rename Log tab to Intake to free 'Log' for Weight subnav"
```

---

## Task 2: Add `WeightEntry` + `CaloriesDailyRow` Codable models

**Files:**
- Create: `DietTracker/Models/WeightEntry.swift`
- Create: `DietTracker/Models/CaloriesDailyRow.swift`
- Create: `DietTrackerTests/Fixtures/weight_entries.json`
- Create: `DietTrackerTests/Fixtures/weight_entry.json`
- Create: `DietTrackerTests/Fixtures/calories_daily.json`

- [ ] **Step 1: Write the fixtures**

`DietTrackerTests/Fixtures/weight_entries.json`:

```json
[
  {
    "id": "11111111-1111-1111-1111-111111111111",
    "log_date": "2026-05-09",
    "weight_lb": 180.50,
    "source_unit": "lb",
    "created_at": "2026-05-09T07:12:00Z",
    "updated_at": "2026-05-09T07:12:00Z"
  },
  {
    "id": "22222222-2222-2222-2222-222222222222",
    "log_date": "2026-05-10",
    "weight_lb": 154.32,
    "source_unit": "kg",
    "created_at": "2026-05-10T07:12:00Z",
    "updated_at": "2026-05-10T07:12:00Z"
  }
]
```

`DietTrackerTests/Fixtures/weight_entry.json`:

```json
{
  "id": "33333333-3333-3333-3333-333333333333",
  "log_date": "2026-05-13",
  "weight_lb": 179.80,
  "source_unit": "lb",
  "created_at": "2026-05-13T07:12:00Z",
  "updated_at": "2026-05-13T07:12:00Z"
}
```

`DietTrackerTests/Fixtures/calories_daily.json`:

```json
[
  { "log_date": "2026-05-08", "calories": 1850 },
  { "log_date": "2026-05-09", "calories": 2100 },
  { "log_date": "2026-05-10", "calories": 1920 }
]
```

- [ ] **Step 2: Write a failing decoding test**

Append to `DietTrackerTests/DecodingTests.swift` (or create `DietTrackerTests/WeightDecodingTests.swift` if cleaner):

```swift
import XCTest
@testable import DietTracker

final class WeightDecodingTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")!
        return try Data(contentsOf: url)
    }

    func testDecodeWeightEntries() throws {
        let data = try fixture("weight_entries")
        let entries = try JSONDecoder.dietTrackerDefault().decode([WeightEntry].self, from: data)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].weightLb, 180.50, accuracy: 0.001)
        XCTAssertEqual(entries[0].sourceUnit, .lb)
        XCTAssertEqual(entries[1].sourceUnit, .kg)
    }

    func testDecodeCaloriesDaily() throws {
        let data = try fixture("calories_daily")
        let rows = try JSONDecoder.dietTrackerDefault().decode([CaloriesDailyRow].self, from: data)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1].calories, 2100)
    }
}
```

- [ ] **Step 3: Run the test, expect failures**

Run:

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-ios
source .envrc && xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:DietTrackerTests/WeightDecodingTests
```

Expected: compile errors because `WeightEntry` / `CaloriesDailyRow` don't exist.

- [ ] **Step 4: Create the models**

`DietTracker/Models/WeightEntry.swift`:

```swift
import Foundation

enum WeightUnit: String, Codable, CaseIterable, Hashable {
    case lb
    case kg
}

struct WeightEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    let weightLb: Double
    let sourceUnit: WeightUnit
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case date = "log_date"
        case weightLb = "weight_lb"
        case sourceUnit = "source_unit"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
```

`DietTracker/Models/CaloriesDailyRow.swift`:

```swift
import Foundation

struct CaloriesDailyRow: Codable, Hashable {
    let date: Date
    let calories: Int

    enum CodingKeys: String, CodingKey {
        case date = "log_date"
        case calories
    }
}
```

- [ ] **Step 5: Regenerate and run tests**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-ios
source .envrc && xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:DietTrackerTests/WeightDecodingTests
```

Expected: both tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-ios
git add DietTracker/Models/WeightEntry.swift DietTracker/Models/CaloriesDailyRow.swift \
  DietTrackerTests/Fixtures/weight_entries.json \
  DietTrackerTests/Fixtures/weight_entry.json \
  DietTrackerTests/Fixtures/calories_daily.json \
  DietTrackerTests/WeightDecodingTests.swift
git commit -m "feat(weight): codable models for entries and calories_daily"
```

---

## Task 3: `WeightFormatter` (kg↔lb conversion + display)

**Files:**
- Create: `DietTracker/Networking/WeightFormatter.swift`
- Create: `DietTrackerTests/WeightFormatterTests.swift`

- [ ] **Step 1: Write the failing tests**

`DietTrackerTests/WeightFormatterTests.swift`:

```swift
import XCTest
@testable import DietTracker

final class WeightFormatterTests: XCTestCase {

    func testKgToLbExact() {
        XCTAssertEqual(WeightFormatter.toLb(70.0, from: .kg), 154.32, accuracy: 0.005)
    }

    func testLbPassthrough() {
        XCTAssertEqual(WeightFormatter.toLb(180.5, from: .lb), 180.5, accuracy: 0.001)
    }

    func testRoundTrip() {
        let originalKg = 82.7
        let lb = WeightFormatter.toLb(originalKg, from: .kg)
        let backKg = WeightFormatter.fromLb(lb, to: .kg)
        XCTAssertEqual(originalKg, backKg, accuracy: 0.01)
    }

    func testDisplayLb() {
        XCTAssertEqual(WeightFormatter.display(lb: 180.5, in: .lb), "180.5 lb")
    }

    func testDisplayKg() {
        // 154.32 lb -> 70.00 kg -> "70.0 kg"
        XCTAssertEqual(WeightFormatter.display(lb: 154.32, in: .kg), "70.0 kg")
    }
}
```

- [ ] **Step 2: Run tests, expect compile failure**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-ios
source .envrc && xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:DietTrackerTests/WeightFormatterTests
```

Expected: compile failure (`WeightFormatter` not defined).

- [ ] **Step 3: Create `DietTracker/Networking/WeightFormatter.swift`**

```swift
import Foundation

enum WeightFormatter {
    static let kgToLb: Double = 2.20462262

    static func toLb(_ value: Double, from unit: WeightUnit) -> Double {
        switch unit {
        case .lb: return value
        case .kg: return value * kgToLb
        }
    }

    static func fromLb(_ lb: Double, to unit: WeightUnit) -> Double {
        switch unit {
        case .lb: return lb
        case .kg: return lb / kgToLb
        }
    }

    static func display(lb: Double, in unit: WeightUnit) -> String {
        let value = fromLb(lb, to: unit)
        return String(format: "%.1f %@", value, unit.rawValue)
    }
}
```

- [ ] **Step 4: Regenerate, run tests**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-ios
source .envrc && xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:DietTrackerTests/WeightFormatterTests
```

Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add DietTracker/Networking/WeightFormatter.swift DietTrackerTests/WeightFormatterTests.swift
git commit -m "feat(weight): WeightFormatter kg<->lb conversion + display"
```

---

## Task 4: Extend `MacroTargets` with `targetWeightLb`

**Files:**
- Modify: `DietTracker/Models/MacroTargets.swift`

- [ ] **Step 1: Replace `DietTracker/Models/MacroTargets.swift`**

```swift
import Foundation

struct MacroTargets: Codable, Equatable {
    let calories: Int
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
    let targetWeightLb: Double?

    enum CodingKeys: String, CodingKey {
        case calories
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case targetWeightLb = "target_weight_lb"
    }
}
```

- [ ] **Step 2: Find existing call sites that build `MacroTargets` explicitly**

Run:

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-ios
grep -rn "MacroTargets(" DietTracker DietTrackerTests
```

For each construction call without `targetWeightLb:`, add `targetWeightLb: nil` to match the new initializer. Examples likely live in tests (fixtures) and previews.

- [ ] **Step 3: Regenerate, run all tests**

```bash
source .envrc && xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

Expected: BUILD + tests succeed. The decoder is forgiving — pre-existing fixtures lacking `target_weight_lb` decode `targetWeightLb` as `nil`.

- [ ] **Step 4: Commit**

```bash
git add DietTracker/Models/MacroTargets.swift DietTracker DietTrackerTests
git commit -m "feat(weight): MacroTargets.targetWeightLb"
```

---

## Task 5: `DietTrackerClient` weight + calories_daily methods

**Files:**
- Modify: `DietTracker/Networking/DietTrackerClient.swift`
- Create: `DietTrackerTests/WeightClientTests.swift`

- [ ] **Step 1: Write the failing tests**

`DietTrackerTests/WeightClientTests.swift`:

```swift
import XCTest
@testable import DietTracker

final class WeightClientTests: XCTestCase {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func loadFixture(_ name: String) throws -> Data {
        Bundle(for: Self.self).url(forResource: name, withExtension: "json").flatMap {
            try? Data(contentsOf: $0)
        } ?? Data()
    }

    private func makeClient() -> DietTrackerClient {
        DietTrackerClient(
            baseURL: URL(string: "https://example.test")!,
            sessionToken: "session-k",
            session: makeSession()
        )
    }

    override func tearDown() {
        StubURLProtocol.responder = nil
        super.tearDown()
    }

    func testListWeightSendsRange() async throws {
        let json = try loadFixture("weight_entries")
        var captured: URLRequest?
        StubURLProtocol.responder = { req in
            captured = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }
        let from = DateOnly.formatter.date(from: "2026-05-01")!
        let to = DateOnly.formatter.date(from: "2026-05-13")!
        let entries = try await makeClient().listWeightEntries(from: from, to: to)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(captured?.url?.path, "/weight")
        let query = captured?.url?.query ?? ""
        XCTAssertTrue(query.contains("from=2026-05-01"))
        XCTAssertTrue(query.contains("to=2026-05-13"))
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")
    }

    func testUpsertWeightPostsLbBody() async throws {
        let json = try loadFixture("weight_entry")
        var captured: URLRequest?
        var body: Data?
        StubURLProtocol.responder = { req in
            captured = req
            body = req.bodyStreamData()
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }
        let date = DateOnly.formatter.date(from: "2026-05-13")!
        _ = try await makeClient().upsertWeight(date: date, weight: 180.5, unit: .lb)
        XCTAssertEqual(captured?.httpMethod, "PUT")
        XCTAssertEqual(captured?.url?.path, "/weight/2026-05-13")
        let parsed = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]
        XCTAssertEqual(parsed?["unit"] as? String, "lb")
        XCTAssertEqual(parsed?["weight"] as? Double, 180.5)
    }

    func testUpsertWeightPostsKgBody() async throws {
        let json = try loadFixture("weight_entry")
        var body: Data?
        StubURLProtocol.responder = { req in
            body = req.bodyStreamData()
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }
        let date = DateOnly.formatter.date(from: "2026-05-13")!
        _ = try await makeClient().upsertWeight(date: date, weight: 82, unit: .kg)
        let parsed = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]
        XCTAssertEqual(parsed?["unit"] as? String, "kg")
    }

    func testDeleteWeightSendsDelete() async throws {
        var captured: URLRequest?
        StubURLProtocol.responder = { req in
            captured = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let date = DateOnly.formatter.date(from: "2026-05-13")!
        try await makeClient().deleteWeight(date: date)
        XCTAssertEqual(captured?.httpMethod, "DELETE")
        XCTAssertEqual(captured?.url?.path, "/weight/2026-05-13")
    }

    func testFetchCaloriesDaily() async throws {
        let json = try loadFixture("calories_daily")
        StubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }
        let from = DateOnly.formatter.date(from: "2026-05-01")!
        let to = DateOnly.formatter.date(from: "2026-05-13")!
        let rows = try await makeClient().fetchCaloriesDaily(from: from, to: to)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1].calories, 2100)
    }

    func testGetWeight404MapsToNotFound() async throws {
        StubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let date = DateOnly.formatter.date(from: "2026-05-13")!
        do {
            _ = try await makeClient().getWeight(date: date)
            XCTFail("expected throw")
        } catch DietTrackerError.notFound {
            // expected
        }
    }
}
```

- [ ] **Step 2: Run tests, expect compile failures**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-ios
source .envrc && xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:DietTrackerTests/WeightClientTests
```

Expected: compile failure on missing client methods.

- [ ] **Step 3: Add the methods to `DietTracker/Networking/DietTrackerClient.swift`**

Inside the `actor DietTrackerClient` body, after the existing container methods (just before `// MARK: - auth endpoints`), insert:

```swift
    // MARK: - weight

    func listWeightEntries(from: Date, to: Date) async throws -> [WeightEntry] {
        let url = try makeURL(
            path: "/weight",
            query: [
                URLQueryItem(name: "from", value: DateOnly.string(from: from)),
                URLQueryItem(name: "to", value: DateOnly.string(from: to)),
            ]
        )
        return try await fetch(url: url)
    }

    func getWeight(date: Date) async throws -> WeightEntry {
        let url = try makeURL(path: "/weight/\(DateOnly.string(from: date))", query: [])
        return try await fetch(url: url)
    }

    func upsertWeight(date: Date, weight: Double, unit: WeightUnit) async throws -> WeightEntry {
        let url = try makeURL(path: "/weight/\(DateOnly.string(from: date))", query: [])
        let body: [String: Any] = ["weight": weight, "unit": unit.rawValue]
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        return try await sendJSON(url: url, method: "PUT", body: data)
    }

    func deleteWeight(date: Date) async throws {
        let url = try makeURL(path: "/weight/\(DateOnly.string(from: date))", query: [])
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        applyAuth(&req)
        try await sendNoBody(request: req)
    }

    func fetchCaloriesDaily(from: Date, to: Date) async throws -> [CaloriesDailyRow] {
        let url = try makeURL(
            path: "/calories_daily",
            query: [
                URLQueryItem(name: "from", value: DateOnly.string(from: from)),
                URLQueryItem(name: "to", value: DateOnly.string(from: to)),
            ]
        )
        return try await fetch(url: url)
    }
```

- [ ] **Step 4: Regenerate, run tests**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-ios
source .envrc && xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:DietTrackerTests/WeightClientTests
```

Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add DietTracker/Networking/DietTrackerClient.swift DietTrackerTests/WeightClientTests.swift
git commit -m "feat(weight): client methods for /weight and /calories_daily"
```

---

## Task 6: `WeightAnalytics` pure module + tests

**Files:**
- Create: `DietTracker/State/WeightAnalytics.swift`
- Create: `DietTrackerTests/WeightAnalyticsTests.swift`

- [ ] **Step 1: Write the failing tests**

`DietTrackerTests/WeightAnalyticsTests.swift`:

```swift
import XCTest
@testable import DietTracker

final class WeightAnalyticsTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)
    private let today: Date = {
        let cal = Calendar(identifier: .gregorian)
        return cal.date(from: DateComponents(year: 2026, month: 5, day: 13))!
    }()

    private func dayOffset(_ n: Int) -> Date {
        cal.date(byAdding: .day, value: n, to: today)!
    }

    private func entry(_ offset: Int, lb: Double) -> WeightEntry {
        WeightEntry(
            id: UUID(),
            date: dayOffset(offset),
            weightLb: lb,
            sourceUnit: .lb,
            createdAt: today,
            updatedAt: today
        )
    }

    private func kcal(_ offset: Int, _ c: Int) -> CaloriesDailyRow {
        CaloriesDailyRow(date: dayOffset(offset), calories: c)
    }

    func testInsufficientData() {
        let result = WeightAnalytics.compute(
            entries: [entry(-2, lb: 180), entry(-1, lb: 179.5)],
            kcal: [kcal(-2, 2000), kcal(-1, 2000)],
            targetWeightLb: 170,
            today: today
        )
        XCTAssertNil(result.regression)
        XCTAssertLessThan(result.validWindowCount, 14)
    }

    func testRegressionRecoversMaintenance() {
        // Build 30 days of data where:
        //  - calories alternate between 1800 and 2400 to give variance,
        //  - weight loss rate roughly = (kcal - 2500) / (3500 * 7) lb/day per kcal/day
        //
        // We pre-compute synthetic weights so that maintenance ≈ 2500.
        var entries: [WeightEntry] = []
        var kcalRows: [CaloriesDailyRow] = []
        var weight = 200.0
        for d in stride(from: -29, through: 0, by: 1) {
            let c = (d % 2 == 0) ? 1800 : 2400
            kcalRows.append(kcal(d, c))
            // rate per day: (c - 2500) / 3500 (lb/day)
            let ratePerDay = Double(c - 2500) / 3500.0
            weight += ratePerDay
            entries.append(entry(d, lb: weight))
        }
        let result = WeightAnalytics.compute(
            entries: entries,
            kcal: kcalRows,
            targetWeightLb: 180,
            today: today
        )
        XCTAssertNotNil(result.regression)
        XCTAssertNotNil(result.maintenanceKcal)
        XCTAssertEqual(result.maintenanceKcal ?? 0, 2500, accuracy: 250)
    }

    func testStableTrendETA() {
        var entries: [WeightEntry] = []
        for d in stride(from: -29, through: 0, by: 1) {
            entries.append(entry(d, lb: 180.0))
        }
        let result = WeightAnalytics.compute(
            entries: entries,
            kcal: (-29...0).map { kcal($0, 2000) },
            targetWeightLb: 170,
            today: today
        )
        XCTAssertEqual(result.etaToTarget, .stable)
    }

    func testTrendingAwayETA() {
        // Weight is rising; target is below current weight -> .never
        var entries: [WeightEntry] = []
        for d in stride(from: -29, through: 0, by: 1) {
            entries.append(entry(d, lb: 180.0 + Double(30 + d) * 0.1))
        }
        let result = WeightAnalytics.compute(
            entries: entries,
            kcal: (-29...0).map { kcal($0, 3000) },
            targetWeightLb: 170,
            today: today
        )
        XCTAssertEqual(result.etaToTarget, .never)
    }

    func testNoTargetNoETA() {
        var entries: [WeightEntry] = []
        for d in stride(from: -29, through: 0, by: 1) {
            entries.append(entry(d, lb: 180.0 - Double(30 + d) * 0.05))
        }
        let result = WeightAnalytics.compute(
            entries: entries,
            kcal: (-29...0).map { kcal($0, 1800) },
            targetWeightLb: nil,
            today: today
        )
        XCTAssertNil(result.etaToTarget)
    }

    func testValidWindowRequiresFiveOfSeven() {
        // 20 days. Within any 7-day window, weight observations are <=4.
        var entries: [WeightEntry] = []
        for d in stride(from: -19, through: 0, by: 2) {  // every other day -> max 4 in 7
            entries.append(entry(d, lb: 180.0))
        }
        let result = WeightAnalytics.compute(
            entries: entries,
            kcal: (-19...0).map { kcal($0, 2000) },
            targetWeightLb: 170,
            today: today
        )
        XCTAssertEqual(result.validWindowCount, 0)
    }
}
```

- [ ] **Step 2: Run, expect compile failure**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-ios
source .envrc && xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:DietTrackerTests/WeightAnalyticsTests
```

Expected: compile failure on missing `WeightAnalytics`.

- [ ] **Step 3: Create `DietTracker/State/WeightAnalytics.swift`**

```swift
import Foundation

struct WindowedPoint: Hashable {
    let endDate: Date
    let avgKcal: Double
    let lbPerDay: Double
}

struct WeightRegression: Hashable {
    let slope: Double     // lb/day per kcal/day
    let intercept: Double // lb/day
    let rSquared: Double
}

enum WeightETA: Hashable {
    case date(Date)
    case stable
    case never
}

struct WeightAnalyticsResult: Hashable {
    let scatter: [WindowedPoint]
    let regression: WeightRegression?
    let maintenanceKcal: Int?
    let trendLbPerWeek: Double?
    let etaToTarget: WeightETA?
    let validWindowCount: Int
}

enum WeightAnalytics {

    static let windowDays = 7
    static let minWeightObsInWindow = 5
    static let minKcalObsInWindow = 5
    static let minValidWindows = 14
    static let trendWindowDays = 28
    static let minTrendWeightObs = 7
    static let stableLbPerWeekThreshold = 0.05
    static let atTargetLbThreshold = 0.5
    static let slopeEpsilon = 1e-7

    static func compute(
        entries: [WeightEntry],
        kcal: [CaloriesDailyRow],
        targetWeightLb: Double?,
        today: Date = .now
    ) -> WeightAnalyticsResult {
        let cal = Calendar(identifier: .gregorian)
        guard !entries.isEmpty || !kcal.isEmpty else {
            return WeightAnalyticsResult(
                scatter: [], regression: nil, maintenanceKcal: nil,
                trendLbPerWeek: nil, etaToTarget: nil, validWindowCount: 0
            )
        }

        let weightByDay: [Date: Double] = Dictionary(
            uniqueKeysWithValues: entries.map { (cal.startOfDay(for: $0.date), $0.weightLb) }
        )
        let kcalByDay: [Date: Double] = Dictionary(
            uniqueKeysWithValues: kcal.map { (cal.startOfDay(for: $0.date), Double($0.calories)) }
        )

        let endDay = cal.startOfDay(for: today)
        let firstObserved = (entries.map(\.date) + kcal.map(\.date))
            .min().map { cal.startOfDay(for: $0) } ?? endDay
        let totalDays = max(1, daysBetween(firstObserved, endDay, calendar: cal) + 1)

        var scatter: [WindowedPoint] = []
        for offset in stride(from: 0, to: totalDays, by: 1) {
            let windowEnd = cal.date(byAdding: .day, value: offset - (totalDays - 1), to: endDay)!
            let windowStart = cal.date(byAdding: .day, value: -(windowDays - 1), to: windowEnd)!
            if windowStart < firstObserved { continue }

            var weightDays: [(Int, Double)] = []
            var kcalValues: [Double] = []
            for w in 0..<windowDays {
                let d = cal.date(byAdding: .day, value: w, to: windowStart)!
                if let lb = weightByDay[d] { weightDays.append((w, lb)) }
                if let c = kcalByDay[d] { kcalValues.append(c) }
            }
            guard weightDays.count >= minWeightObsInWindow,
                  kcalValues.count >= minKcalObsInWindow else { continue }

            let xs = weightDays.map { Double($0.0) }
            let ys = weightDays.map { $0.1 }
            guard let (slope, _, _) = ols(xs: xs, ys: ys) else { continue }
            let avgKcal = kcalValues.reduce(0, +) / Double(kcalValues.count)
            scatter.append(WindowedPoint(endDate: windowEnd, avgKcal: avgKcal, lbPerDay: slope))
        }

        var regression: WeightRegression? = nil
        var maintenanceKcal: Int? = nil
        if scatter.count >= minValidWindows {
            let xs = scatter.map(\.avgKcal)
            let ys = scatter.map(\.lbPerDay)
            if let (m, b, r2) = ols(xs: xs, ys: ys) {
                regression = WeightRegression(slope: m, intercept: b, rSquared: r2)
                if abs(m) >= slopeEpsilon {
                    let maintenance = -b / m
                    if maintenance.isFinite {
                        maintenanceKcal = Int(maintenance.rounded())
                    }
                }
            }
        }

        let trendLbPerWeek = trendLbPerWeek(
            entries: entries, today: endDay, calendar: cal
        )

        let eta = computeETA(
            entries: entries,
            trendLbPerWeek: trendLbPerWeek,
            targetWeightLb: targetWeightLb,
            today: endDay,
            calendar: cal
        )

        return WeightAnalyticsResult(
            scatter: scatter,
            regression: regression,
            maintenanceKcal: maintenanceKcal,
            trendLbPerWeek: trendLbPerWeek,
            etaToTarget: eta,
            validWindowCount: scatter.count
        )
    }

    // MARK: - helpers

    private static func ols(xs: [Double], ys: [Double]) -> (slope: Double, intercept: Double, r2: Double)? {
        guard xs.count == ys.count, xs.count >= 2 else { return nil }
        let n = Double(xs.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for i in 0..<xs.count {
            let dx = xs[i] - meanX
            let dy = ys[i] - meanY
            sxx += dx * dx
            sxy += dx * dy
            syy += dy * dy
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        let intercept = meanY - slope * meanX
        let r2 = syy > 0 ? (sxy * sxy) / (sxx * syy) : 1.0
        return (slope, intercept, r2)
    }

    private static func trendLbPerWeek(
        entries: [WeightEntry],
        today: Date,
        calendar cal: Calendar
    ) -> Double? {
        let cutoff = cal.date(byAdding: .day, value: -(trendWindowDays - 1), to: today)!
        let pts = entries
            .filter { cal.startOfDay(for: $0.date) >= cutoff }
            .map { (entry: WeightEntry) -> (Double, Double) in
                let day = cal.startOfDay(for: entry.date)
                let offset = Double(daysBetween(cutoff, day, calendar: cal))
                return (offset, entry.weightLb)
            }
        guard pts.count >= minTrendWeightObs,
              let (slope, _, _) = ols(xs: pts.map(\.0), ys: pts.map(\.1)) else { return nil }
        return slope * 7.0
    }

    private static func computeETA(
        entries: [WeightEntry],
        trendLbPerWeek: Double?,
        targetWeightLb: Double?,
        today: Date,
        calendar cal: Calendar
    ) -> WeightETA? {
        guard let target = targetWeightLb, let trend = trendLbPerWeek else { return nil }
        if abs(trend) < stableLbPerWeekThreshold { return .stable }

        let cutoff = cal.date(byAdding: .day, value: -6, to: today)!
        let recent = entries.filter { cal.startOfDay(for: $0.date) >= cutoff }
        let latestMean: Double
        if !recent.isEmpty {
            latestMean = recent.map(\.weightLb).reduce(0, +) / Double(recent.count)
        } else if let last = entries.max(by: { $0.date < $1.date }) {
            latestMean = last.weightLb
        } else {
            return nil
        }

        let direction = target - latestMean
        if abs(direction) < atTargetLbThreshold { return .stable }
        let sameSign = (direction > 0 && trend > 0) || (direction < 0 && trend < 0)
        if !sameSign { return .never }

        let lbPerDay = trend / 7.0
        let daysOut = direction / lbPerDay
        let eta = cal.date(byAdding: .day, value: Int(daysOut.rounded()), to: today)!
        return .date(eta)
    }

    private static func daysBetween(_ a: Date, _ b: Date, calendar cal: Calendar) -> Int {
        cal.dateComponents([.day], from: a, to: b).day ?? 0
    }
}
```

- [ ] **Step 4: Run analytics tests**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-ios
source .envrc && xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:DietTrackerTests/WeightAnalyticsTests
```

Expected: 6 tests pass. The maintenance estimate test allows ±250 kcal slack.

- [ ] **Step 5: Commit**

```bash
git add DietTracker/State/WeightAnalytics.swift DietTrackerTests/WeightAnalyticsTests.swift
git commit -m "feat(weight): WeightAnalytics OLS regression module"
```

---

## Task 7: `WeightLogModel` view model

**Files:**
- Create: `DietTracker/State/WeightLogModel.swift`

- [ ] **Step 1: Create `DietTracker/State/WeightLogModel.swift`**

```swift
import Foundation
import Observation

@Observable
final class WeightLogModel {
    private(set) var state: LoadState<[WeightEntry]> = .idle
    private weak var auth: AuthSession?

    init(auth: AuthSession) {
        self.auth = auth
    }

    var todayEntry: WeightEntry? {
        guard case let .loaded(entries) = state else { return nil }
        let today = Calendar.current.startOfDay(for: Date())
        return entries.first { Calendar.current.startOfDay(for: $0.date) == today }
    }

    func load(today: Date = Date()) async {
        guard let client = auth?.makeClient() else {
            state = .failed(.notSignedIn)
            return
        }
        state = .loading
        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -89, to: today) ?? today
        do {
            let entries = try await client.listWeightEntries(from: from, to: today)
            state = .loaded(entries.sorted { $0.date > $1.date })
        } catch let error as DietTrackerError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }

    func upsert(date: Date, weight: Double, unit: WeightUnit) async {
        guard let client = auth?.makeClient() else { return }
        do {
            let updated = try await client.upsertWeight(date: date, weight: weight, unit: unit)
            if case var .loaded(entries) = state {
                entries.removeAll {
                    Calendar.current.startOfDay(for: $0.date) ==
                    Calendar.current.startOfDay(for: updated.date)
                }
                entries.append(updated)
                entries.sort { $0.date > $1.date }
                state = .loaded(entries)
            } else {
                state = .loaded([updated])
            }
        } catch let error as DietTrackerError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }

    func delete(date: Date) async {
        guard let client = auth?.makeClient() else { return }
        do {
            try await client.deleteWeight(date: date)
            if case var .loaded(entries) = state {
                entries.removeAll {
                    Calendar.current.startOfDay(for: $0.date) ==
                    Calendar.current.startOfDay(for: date)
                }
                state = .loaded(entries)
            }
        } catch let error as DietTrackerError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }
}
```

- [ ] **Step 2: Regenerate, build**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-ios
source .envrc && xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add DietTracker/State/WeightLogModel.swift
git commit -m "feat(weight): WeightLogModel observable view model"
```

---

## Task 8: `WeightTrendsModel` view model

**Files:**
- Create: `DietTracker/State/WeightTrendsModel.swift`

- [ ] **Step 1: Create `DietTracker/State/WeightTrendsModel.swift`**

```swift
import Foundation
import Observation

enum TrendsRange: String, CaseIterable, Hashable {
    case d30, d90, y1, all

    var days: Int {
        switch self {
        case .d30: return 30
        case .d90: return 90
        case .y1:  return 365
        case .all: return 365 // hard cap; server allows max 366
        }
    }
}

@Observable
final class WeightTrendsModel {
    private(set) var entries: [WeightEntry] = []
    private(set) var kcal: [CaloriesDailyRow] = []
    private(set) var analytics: LoadState<WeightAnalyticsResult> = .idle
    var range: TrendsRange = .d90
    var targetWeightLb: Double?

    private weak var auth: AuthSession?

    init(auth: AuthSession) {
        self.auth = auth
    }

    func load(today: Date = Date()) async {
        guard let client = auth?.makeClient() else {
            analytics = .failed(.notSignedIn)
            return
        }
        analytics = .loading
        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -(range.days - 1), to: today) ?? today

        async let entriesTask = client.listWeightEntries(from: from, to: today)
        async let kcalTask = client.fetchCaloriesDaily(from: from, to: today)
        async let targetsTask = client.fetchTargets()

        do {
            self.entries = try await entriesTask
            self.kcal = try await kcalTask
            self.targetWeightLb = (try? await targetsTask)?.targetWeightLb
            let result = WeightAnalytics.compute(
                entries: entries,
                kcal: kcal,
                targetWeightLb: targetWeightLb,
                today: today
            )
            analytics = .loaded(result)
        } catch let error as DietTrackerError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            analytics = .failed(error)
        } catch {
            analytics = .failed(.server(status: -1))
        }
    }
}
```

- [ ] **Step 2: Add a `fetchTargets()` helper to `DietTrackerClient`**

If `DietTrackerClient` doesn't already expose `/targets`, add it. Locate the `// MARK: - auth endpoints` block and insert before it:

```swift
    func fetchTargets() async throws -> MacroTargets {
        let url = try makeURL(path: "/targets", query: [])
        return try await fetch(url: url)
    }
```

Check first whether a similar method already exists; if it does, reuse the existing name in `WeightTrendsModel.load`.

Run:

```bash
grep -n "/targets" DietTracker/Networking/DietTrackerClient.swift
```

- [ ] **Step 3: Regenerate, build**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-ios
source .envrc && xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add DietTracker/State/WeightTrendsModel.swift DietTracker/Networking/DietTrackerClient.swift
git commit -m "feat(weight): WeightTrendsModel orchestrating analytics fetch"
```

---

## Task 9: Display-unit preference

**Files:**
- Create or modify: `DietTracker/State/AppSettings.swift` (or equivalent if a different name)

- [ ] **Step 1: Add a `displayUnit` `@AppStorage` key**

The simplest path: read the preference via SwiftUI's `@AppStorage` directly in views that need it, using the key `weight_display_unit`. To keep the value typed, add an enum extension to `WeightUnit` for the storage default and a tiny helper:

Append to `DietTracker/Models/WeightEntry.swift` (already where `WeightUnit` lives):

```swift
extension WeightUnit {
    static let displayPreferenceKey = "weight_display_unit"
    static var defaultDisplayUnit: WeightUnit { .lb }
}
```

That's all that's needed. Views use:

```swift
@AppStorage(WeightUnit.displayPreferenceKey) private var displayUnitRaw: String = WeightUnit.defaultDisplayUnit.rawValue
var displayUnit: WeightUnit { WeightUnit(rawValue: displayUnitRaw) ?? .lb }
```

- [ ] **Step 2: Build**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-ios
source .envrc && xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add DietTracker/Models/WeightEntry.swift
git commit -m "feat(weight): @AppStorage key for display unit preference"
```

---

## Task 10: `WeightEntrySheet` modal editor

**Files:**
- Create: `DietTracker/Views/Weight/WeightEntrySheet.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

struct WeightEntrySheet: View {
    let date: Date
    let existing: WeightEntry?
    let onSave: (Double, WeightUnit) async -> Void
    let onDelete: (() async -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var input: String = ""
    @State private var unit: WeightUnit = .lb
    @AppStorage(WeightUnit.displayPreferenceKey)
    private var displayUnitRaw: String = WeightUnit.defaultDisplayUnit.rawValue

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.primary.ignoresSafeArea()
                VStack(spacing: 24) {
                    Text(date.formatted(date: .complete, time: .omitted))
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.FG.secondary)

                    TextField("Weight", text: $input)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.FG.primary)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.BG.secondary))

                    Picker("Unit", selection: $unit) {
                        Text("lb").tag(WeightUnit.lb)
                        Text("kg").tag(WeightUnit.kg)
                    }
                    .pickerStyle(.segmented)

                    Spacer()

                    Button {
                        Task {
                            guard let value = parsed else { return }
                            await onSave(value, unit)
                            dismiss()
                        }
                    } label: {
                        Text("Save")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Capsule().fill(Theme.CTP.mauve))
                            .foregroundStyle(.black)
                    }
                    .disabled(!isValid)

                    if let onDelete {
                        Button(role: .destructive) {
                            Task {
                                await onDelete()
                                dismiss()
                            }
                        } label: {
                            Text("Delete weigh-in")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.CTP.peach)
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle(existing == nil ? "Add weight" : "Edit weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.CTP.mauve)
                }
            }
        }
        .onAppear {
            if let existing {
                input = String(format: "%.1f",
                    WeightFormatter.fromLb(existing.weightLb, to: existing.sourceUnit))
                unit = existing.sourceUnit
            } else if let pref = WeightUnit(rawValue: displayUnitRaw) {
                unit = pref
            }
        }
    }

    private var parsed: Double? { Double(input.replacingOccurrences(of: ",", with: ".")) }

    private var isValid: Bool {
        guard let value = parsed else { return false }
        return value > 0 && value < 2000
    }
}
```

- [ ] **Step 2: Build**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-ios
source .envrc && xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add DietTracker/Views/Weight/WeightEntrySheet.swift
git commit -m "feat(weight): WeightEntrySheet modal editor"
```

---

## Task 11: `WeightLogView`

**Files:**
- Create: `DietTracker/Views/Weight/WeightLogView.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

struct WeightLogView: View {
    @Environment(AuthSession.self) private var auth
    @State private var model: WeightLogModel?
    @State private var sheetState: SheetState?

    @AppStorage(WeightUnit.displayPreferenceKey)
    private var displayUnitRaw: String = WeightUnit.defaultDisplayUnit.rawValue

    enum SheetState: Identifiable {
        case add(Date)
        case edit(WeightEntry)
        var id: String {
            switch self {
            case .add(let d): return "add-\(d)"
            case .edit(let e): return "edit-\(e.id)"
            }
        }
    }

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            Group {
                switch model?.state ?? .idle {
                case .idle, .loading:
                    ProgressView().tint(Theme.CTP.mauve)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let entries):
                    loadedBody(entries)
                case .failed(let err):
                    EmptyStateView(
                        icon: "exclamationmark.triangle",
                        title: "Couldn't load",
                        description: err.userMessage,
                        action: { Task { await model?.load() } },
                        actionLabel: "Retry"
                    )
                }
            }
        }
        .task {
            if model == nil { model = WeightLogModel(auth: auth) }
            await model?.load()
        }
        .refreshable { await model?.load() }
        .sheet(item: $sheetState) { state in
            switch state {
            case .add(let date):
                WeightEntrySheet(
                    date: date,
                    existing: nil,
                    onSave: { value, unit in await model?.upsert(date: date, weight: value, unit: unit) },
                    onDelete: nil
                )
            case .edit(let entry):
                WeightEntrySheet(
                    date: entry.date,
                    existing: entry,
                    onSave: { value, unit in await model?.upsert(date: entry.date, weight: value, unit: unit) },
                    onDelete: { await model?.delete(date: entry.date) }
                )
            }
        }
    }

    @ViewBuilder
    private func loadedBody(_ entries: [WeightEntry]) -> some View {
        let displayUnit = WeightUnit(rawValue: displayUnitRaw) ?? .lb
        ScrollView {
            VStack(spacing: Theme.Layout.sectionSpacing) {
                todayCard(entries: entries, unit: displayUnit)
                pastList(entries: entries, unit: displayUnit)
                Spacer(minLength: Theme.Layout.dockClearance)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    private func todayCard(entries: [WeightEntry], unit: WeightUnit) -> some View {
        let today = Calendar.current.startOfDay(for: Date())
        let entry = entries.first {
            Calendar.current.startOfDay(for: $0.date) == today
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Today")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Theme.FG.secondary)
            if let entry {
                HStack {
                    Text(WeightFormatter.display(lb: entry.weightLb, in: unit))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.FG.primary)
                    Spacer()
                    Text(entry.updatedAt, style: .relative)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.FG.tertiary)
                }
            } else {
                Button {
                    sheetState = .add(today)
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("Add today's weight")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.CTP.mauve)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .ctpCard()
        .onTapGesture {
            if let entry = entries.first(where: {
                Calendar.current.startOfDay(for: $0.date) == today
            }) {
                sheetState = .edit(entry)
            }
        }
    }

    private func pastList(entries: [WeightEntry], unit: WeightUnit) -> some View {
        let today = Calendar.current.startOfDay(for: Date())
        let past = entries.filter { Calendar.current.startOfDay(for: $0.date) != today }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Past")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Theme.FG.secondary)
            if past.isEmpty {
                Text("No past weigh-ins.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.FG.tertiary)
            } else {
                ForEach(past) { entry in
                    Button {
                        sheetState = .edit(entry)
                    } label: {
                        HStack {
                            Text(entry.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.FG.primary)
                            Spacer()
                            Text(WeightFormatter.display(lb: entry.weightLb, in: unit))
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.FG.primary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.FG.tertiary)
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    Divider().background(Theme.BG.tertiary)
                }
            }
        }
        .padding(16)
        .ctpCard()
    }
}
```

- [ ] **Step 2: Build**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-ios
source .envrc && xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: BUILD SUCCEEDED. All of `Theme.Layout.sectionSpacing`, `Theme.Layout.dockClearance`, `.ctpCard()`, `EmptyStateView`, and `DietTrackerError.userMessage` are already in the project (see `YearView.swift` for canonical usage).

- [ ] **Step 3: Commit**

```bash
git add DietTracker/Views/Weight/WeightLogView.swift
git commit -m "feat(weight): WeightLogView with today card and past list"
```

---

## Task 12: `WeightTrendsView` (charts + analytics card)

**Files:**
- Create: `DietTracker/Views/Weight/WeightTrendsView.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI
import Charts

struct WeightTrendsView: View {
    @Environment(AuthSession.self) private var auth
    @State private var model: WeightTrendsModel?

    @AppStorage(WeightUnit.displayPreferenceKey)
    private var displayUnitRaw: String = WeightUnit.defaultDisplayUnit.rawValue

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            Group {
                switch model?.analytics ?? .idle {
                case .idle, .loading:
                    ProgressView().tint(Theme.CTP.mauve)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let result):
                    loadedBody(result)
                case .failed(let err):
                    EmptyStateView(
                        icon: "exclamationmark.triangle",
                        title: "Couldn't load",
                        description: err.userMessage,
                        action: { Task { await model?.load() } },
                        actionLabel: "Retry"
                    )
                }
            }
        }
        .task {
            if model == nil { model = WeightTrendsModel(auth: auth) }
            await model?.load()
        }
        .refreshable { await model?.load() }
    }

    @ViewBuilder
    private func loadedBody(_ result: WeightAnalyticsResult) -> some View {
        let displayUnit = WeightUnit(rawValue: displayUnitRaw) ?? .lb
        ScrollView {
            VStack(spacing: Theme.Layout.sectionSpacing) {
                weightOverTimeCard(entries: model?.entries ?? [], target: model?.targetWeightLb, unit: displayUnit)
                rateVsKcalCard(result: result, unit: displayUnit)
                analyticsCard(result: result, unit: displayUnit)
                Spacer(minLength: Theme.Layout.dockClearance)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    private func weightOverTimeCard(entries: [WeightEntry], target: Double?, unit: WeightUnit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Weight over time")
                .font(.system(size: 11, weight: .semibold)).tracking(0.8).textCase(.uppercase)
                .foregroundStyle(Theme.FG.secondary)
            if entries.isEmpty {
                Text("Log a few weigh-ins to see your trend here.")
                    .font(.system(size: 13)).foregroundStyle(Theme.FG.tertiary)
                    .frame(height: 160)
            } else {
                Chart {
                    ForEach(entries) { entry in
                        let displayValue = WeightFormatter.fromLb(entry.weightLb, to: unit)
                        LineMark(x: .value("Date", entry.date),
                                 y: .value("Weight", displayValue))
                            .foregroundStyle(Theme.CTP.blue)
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Date", entry.date),
                                  y: .value("Weight", displayValue))
                            .foregroundStyle(Theme.CTP.blue)
                    }
                    if let target {
                        RuleMark(y: .value("Target", WeightFormatter.fromLb(target, to: unit)))
                            .foregroundStyle(Theme.CTP.green)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .annotation(position: .top, alignment: .trailing) {
                                Text("target")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.CTP.green)
                            }
                    }
                }
                .frame(height: 200)
            }
        }
        .padding(16).ctpCard()
    }

    private func rateVsKcalCard(result: WeightAnalyticsResult, unit: WeightUnit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rate vs calories")
                .font(.system(size: 11, weight: .semibold)).tracking(0.8).textCase(.uppercase)
                .foregroundStyle(Theme.FG.secondary)
            if result.regression == nil {
                Text("Collecting data — \(result.validWindowCount)/\(WeightAnalytics.minValidWindows) valid weeks")
                    .font(.system(size: 13)).foregroundStyle(Theme.FG.tertiary)
                    .frame(height: 160, alignment: .leading)
            } else {
                Chart {
                    ForEach(Array(result.scatter.enumerated()), id: \.offset) { _, p in
                        PointMark(x: .value("kcal", p.avgKcal),
                                  y: .value("lb/wk", p.lbPerDay * 7))
                            .foregroundStyle(Theme.CTP.lavender)
                    }
                    if let reg = result.regression, !result.scatter.isEmpty {
                        let minX = result.scatter.map(\.avgKcal).min() ?? 0
                        let maxX = result.scatter.map(\.avgKcal).max() ?? 0
                        LineMark(x: .value("kcal", minX),
                                 y: .value("lb/wk", (reg.slope * minX + reg.intercept) * 7))
                            .foregroundStyle(Theme.CTP.mauve)
                        LineMark(x: .value("kcal", maxX),
                                 y: .value("lb/wk", (reg.slope * maxX + reg.intercept) * 7))
                            .foregroundStyle(Theme.CTP.mauve)
                    }
                    if let kcal = result.maintenanceKcal {
                        RuleMark(x: .value("Maintenance", Double(kcal)))
                            .foregroundStyle(Theme.CTP.green)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    RuleMark(y: .value("Zero", 0.0))
                        .foregroundStyle(Theme.FG.tertiary.opacity(0.4))
                }
                .frame(height: 200)
            }
        }
        .padding(16).ctpCard()
    }

    private func analyticsCard(result: WeightAnalyticsResult, unit: WeightUnit) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Analytics")
                .font(.system(size: 11, weight: .semibold)).tracking(0.8).textCase(.uppercase)
                .foregroundStyle(Theme.FG.secondary)
            if let m = result.maintenanceKcal {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("≈").foregroundStyle(Theme.FG.tertiary)
                    Text(m.formatted())
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.FG.primary)
                    Text("kcal/day").foregroundStyle(Theme.FG.tertiary)
                    Spacer()
                    if let r2 = result.regression?.rSquared {
                        confidenceChip(r2: r2)
                    }
                }
                Text("Maintenance").font(.system(size: 12)).foregroundStyle(Theme.FG.tertiary)
            } else {
                Text("Need \(WeightAnalytics.minValidWindows - result.validWindowCount) more valid weeks for maintenance estimate.")
                    .font(.system(size: 13)).foregroundStyle(Theme.FG.tertiary)
            }
            if let lbPerWeek = result.trendLbPerWeek {
                let sign = lbPerWeek > 0 ? "+" : ""
                Text("Trend: \(sign)\(String(format: "%.1f", lbPerWeek)) lb/week (last 28 days)")
                    .font(.system(size: 13)).foregroundStyle(Theme.FG.secondary)
            }
            etaLine(result: result, unit: unit)
        }
        .padding(16).ctpCard()
    }

    @ViewBuilder
    private func etaLine(result: WeightAnalyticsResult, unit: WeightUnit) -> some View {
        if model?.targetWeightLb == nil {
            Text("Set a target weight in Settings to see ETA.")
                .font(.system(size: 13)).foregroundStyle(Theme.FG.tertiary)
        } else if let eta = result.etaToTarget {
            switch eta {
            case .stable:
                Text("≈ stable, no ETA").font(.system(size: 13)).foregroundStyle(Theme.FG.secondary)
            case .never:
                Text("Trending away from target")
                    .font(.system(size: 13)).foregroundStyle(Theme.CTP.peach)
            case .date(let d):
                Text("ETA to target: \(d.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 13)).foregroundStyle(Theme.FG.primary)
            }
        }
    }

    private func confidenceChip(r2: Double) -> some View {
        let (label, color): (String, Color) = {
            switch r2 {
            case 0.5...: return ("R²=\(String(format: "%.2f", r2))", Theme.CTP.green)
            case 0.1..<0.5: return ("R²=\(String(format: "%.2f", r2))", Theme.CTP.peach)
            default: return ("low confidence", Theme.FG.tertiary)
            }
        }()
        return Text(label)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }
}
```

- [ ] **Step 2: Build**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-ios
source .envrc && xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add DietTracker/Views/Weight/WeightTrendsView.swift
git commit -m "feat(weight): WeightTrendsView with two charts + analytics card"
```

---

## Task 13: `WeightTabRootView` + wire into RootView

**Files:**
- Create: `DietTracker/Views/Weight/WeightTabRootView.swift`
- Modify: `DietTracker/Views/RootView.swift`

- [ ] **Step 1: Create `WeightTabRootView.swift`**

```swift
import SwiftUI

enum WeightSection: String, CaseIterable, Hashable {
    case log = "Log"
    case trends = "Trends"
}

struct WeightTabRootView: View {
    @State private var section: WeightSection = .log

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(WeightSection.allCases, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Group {
                switch section {
                case .log:    WeightLogView()
                case .trends: WeightTrendsView()
                }
            }
        }
        .navigationTitle("Weight")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.BG.primary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}
```

- [ ] **Step 2: Add the `.weight` case to `DockTab` + dock button**

Modify `DietTracker/Views/FloatingDock.swift`:

```swift
enum DockTab: Hashable {
    case intake, meals, prep, weight
}
```

In the `HStack` inside `body`, after the prep button, add:

```swift
tabButton(.weight, system: "scalemass", label: "Weight")
```

- [ ] **Step 3: Wire into `RootView.swift`**

In `DietTracker/Views/RootView.swift`:

Add a state path for weight:

```swift
@State private var weightPath = NavigationPath()
```

Add the case to the `switch tab` body, after `.prep`:

```swift
case .weight:
    NavigationStack(path: $weightPath) {
        WeightTabRootView()
            .toolbar { settingsButton }
    }
```

Update `dockVisible`:

```swift
private var dockVisible: Bool {
    switch tab {
    case .intake: intakePath.isEmpty
    case .meals:  mealsPath.isEmpty
    case .prep:   prepPath.isEmpty
    case .weight: weightPath.isEmpty
    }
}
```

- [ ] **Step 4: Build + run on simulator (manual sanity)**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-ios
source .envrc && xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: BUILD SUCCEEDED. Boot the app in the simulator and tap the Weight tab — should land on the empty Log section with "Add today's weight" CTA.

- [ ] **Step 5: Commit**

```bash
git add DietTracker/Views/Weight/WeightTabRootView.swift \
  DietTracker/Views/FloatingDock.swift \
  DietTracker/Views/RootView.swift
git commit -m "feat(weight): wire Weight tab into FloatingDock and RootView"
```

---

## Task 14: Settings — Weight goal + display unit

**Files:**
- Modify: `DietTracker/Views/SettingsView.swift`

- [ ] **Step 1: Add the sections**

Inspect `DietTracker/Views/SettingsView.swift` and add two sections following the existing visual pattern (the existing structure shows the convention for `Form` / `Section` headers and bindings):

```swift
// Add inside the Form body (after existing sections)

Section("Weight goal") {
    HStack {
        Text("Target weight")
        Spacer()
        TextField("e.g. 170", text: $targetWeightInput)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .frame(width: 100)
        Picker("Unit", selection: $targetUnit) {
            Text("lb").tag(WeightUnit.lb)
            Text("kg").tag(WeightUnit.kg)
        }
        .pickerStyle(.segmented)
        .frame(width: 90)
    }
    Button("Save target") { Task { await saveTarget() } }
        .disabled(!isTargetValid)
}

Section("Display unit") {
    Picker("Display unit", selection: $displayUnitRaw) {
        Text("lb").tag(WeightUnit.lb.rawValue)
        Text("kg").tag(WeightUnit.kg.rawValue)
    }
    .pickerStyle(.segmented)
}
```

In the view's body, add the necessary state and helpers:

```swift
@State private var targetWeightInput: String = ""
@State private var targetUnit: WeightUnit = .lb
@AppStorage(WeightUnit.displayPreferenceKey)
private var displayUnitRaw: String = WeightUnit.defaultDisplayUnit.rawValue

private var isTargetValid: Bool {
    guard let v = Double(targetWeightInput.replacingOccurrences(of: ",", with: ".")) else { return false }
    return v > 0 && v < 2000
}

private func saveTarget() async {
    guard let v = Double(targetWeightInput.replacingOccurrences(of: ",", with: ".")) else { return }
    let lb = WeightFormatter.toLb(v, from: targetUnit)
    guard let client = auth.makeClient() else { return }
    do {
        let current = try await client.fetchTargets()
        let updated = MacroTargets(
            calories: current.calories,
            proteinG: current.proteinG,
            carbsG: current.carbsG,
            fatG: current.fatG,
            targetWeightLb: lb
        )
        _ = try await client.upsertTargets(updated)
    } catch {
        // Silent failure on save: user can retry. Matches the existing macro-target save behavior.
    }
}

.task {
    guard let client = auth.makeClient() else { return }
    if let current = try? await client.fetchTargets() {
        if let lb = current.targetWeightLb {
            targetWeightInput = String(format: "%.1f", WeightFormatter.fromLb(lb, to: targetUnit))
        }
    }
}
```

(Adjust types of `auth` — bound via `@Environment(AuthSession.self)` if not already present.)

- [ ] **Step 2: Add `upsertTargets` to `DietTrackerClient` if not present**

Run:

```bash
grep -n "upsertTargets\|PUT.*\\/targets" DietTracker/Networking/DietTrackerClient.swift
```

If absent, add inside the actor (near `fetchTargets`):

```swift
    func upsertTargets(_ targets: MacroTargets) async throws -> MacroTargets {
        let url = try makeURL(path: "/targets", query: [])
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try encoder.encode(targets)
        return try await sendJSON(url: url, method: "PUT", body: body)
    }
```

Note: `MacroTargets` already has explicit `CodingKeys` mapping camelCase ↔ snake_case, so `keyEncodingStrategy` is moot but safe.

- [ ] **Step 3: Regenerate, build**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-ios
source .envrc && xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add DietTracker/Views/SettingsView.swift DietTracker/Networking/DietTrackerClient.swift
git commit -m "feat(weight): settings sections for target weight and display unit"
```

---

## Task 15: Full test pass + manual smoke

- [ ] **Step 1: Run the full test suite**

```bash
cd /Users/khxsh/Documents/repos/projects/diet/diet-tracker-ios
source .envrc && xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

Expected: every existing test plus the new `WeightDecodingTests`, `WeightFormatterTests`, `WeightAnalyticsTests`, `WeightClientTests` pass.

- [ ] **Step 2: Manual smoke**

Boot the simulator. Verify:
- Dock shows four tabs: Intake, Meals, Prep, Weight.
- Weight → Log: "Add today's weight" works; saving creates an entry; entry appears in Past list the next day (or after re-opening).
- Weight → Trends: with < 14 days of data, shows "Collecting data — N/14". Otherwise both charts render.
- Settings → Weight goal: setting a target and re-opening Trends shows the target rule line and ETA.
- Settings → Display unit: toggling kg/lb updates chart axis label values + list rows.

- [ ] **Step 3: No commit needed for the smoke run.**

---

## Done

The Weight tab is live end-to-end:
- Intake tab renamed, no collision with Weight's `Log` segment.
- Daily upsert + range CRUD against the new server endpoints.
- Two charts and the analytics card render with the documented states.
- Tests cover decoding, conversion, client surface, and regression math.

Server work tracked in the companion plan; this iOS plan assumes those endpoints are deployed.
