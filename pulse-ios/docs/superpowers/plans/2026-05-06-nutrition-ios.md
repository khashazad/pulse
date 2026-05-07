# Nutrition iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Native SwiftUI iOS app named "Nutrition" that displays today's and historical food intake from `nutrition-server` (read-only viewer, single user `khash`).

**Architecture:** SwiftUI iOS 17+ single target. Three layers — `NutritionClient` actor (URLSession + X-API-Key), `@Observable` view-models per screen with `LoadState<T>`, SwiftUI views with a custom floating dock overlaying `RootView`. Server is sole source of truth (no local cache). Settings (URL + API key) stored in UserDefaults + Keychain.

**Tech Stack:** Swift 5.9+, SwiftUI, iOS 17 minimum, XCTest for unit tests, `xcodegen` for project generation, URLSession, Keychain Services API.

**Repo:** `/Users/khxsh/Documents/repos/projects/nutrition-ios` (already git-init'd, design committed).

**Sibling repo:** `/Users/khxsh/Documents/repos/projects/nutrition-server` — running on Railway, serves the API.

---

## File Structure

```
nutrition-ios/
├── project.yml                              # xcodegen config
├── Nutrition.xcodeproj/                     # generated
├── Nutrition/                               # app target sources
│   ├── NutritionApp.swift                   # @main
│   ├── Info.plist                           # minimal (most config in project.yml)
│   ├── Config/
│   │   ├── Constants.swift                  # USER_KEY = "khash"
│   │   └── KeychainStore.swift              # static read/write API key
│   ├── Networking/
│   │   ├── NutritionClient.swift            # actor; fetches summary, logs
│   │   ├── NutritionError.swift             # enum
│   │   └── DateOnlyCoding.swift             # YYYY-MM-DD JSONDecoder helper
│   ├── Models/
│   │   ├── MacroTotals.swift                # mirrors server MacroTotals
│   │   ├── MacroTargets.swift               # mirrors server MacroTargets
│   │   ├── FoodEntry.swift                  # mirrors FoodEntryResponse
│   │   ├── DailySummary.swift               # mirrors DailySummaryResponse
│   │   └── DailyLog.swift                   # mirrors DailyLogSummary + LogsListResponse
│   ├── State/
│   │   ├── LoadState.swift                  # enum
│   │   ├── AppSettings.swift                # @Observable
│   │   ├── DayMacroModel.swift              # @Observable
│   │   └── WeekModel.swift                  # @Observable
│   └── Views/
│       ├── RootView.swift                   # tab + nav + dock overlay
│       ├── FloatingDock.swift               # custom pill-shaped dock
│       ├── DayMacroView.swift               # used by Today tab + DayDetail
│       ├── WeekView.swift                   # bar chart + averages
│       ├── SettingsView.swift               # URL + API key form
│       ├── DatePickerSheet.swift            # calendar modal
│       └── Components/
│           ├── MacroRing.swift              # kcal vs target ring
│           ├── MacroTotalsRow.swift         # P/C/F totals
│           ├── EntryRow.swift               # one food entry with dots
│           ├── DailyKcalBars.swift          # 7-day bar chart
│           └── AverageMacrosTable.swift     # avg macros table
└── NutritionTests/
    ├── Fixtures/
    │   ├── summary.json
    │   └── logs.json
    └── DecodingTests.swift
```

---

## Task 1: Project scaffold (xcodegen)

**Files:**
- Create: `project.yml`
- Create: `Nutrition/Info.plist`
- Run: `xcodegen generate` → produces `Nutrition.xcodeproj`

- [ ] **Step 1: Install xcodegen if missing**

```bash
which xcodegen >/dev/null || brew install xcodegen
xcodegen --version
```

Expected: a version number (e.g. `Version: 2.43.0`).

- [ ] **Step 2: Write `project.yml`**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/project.yml`

```yaml
name: Nutrition
options:
  bundleIdPrefix: com.khxsh
  deploymentTarget:
    iOS: "17.0"
  createIntermediateGroups: true

settings:
  base:
    SWIFT_VERSION: "5.9"
    DEVELOPMENT_TEAM: ""
    CODE_SIGN_STYLE: Automatic
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"

targets:
  Nutrition:
    type: application
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: Nutrition
        excludes:
          - "Info.plist"
    resources: []
    info:
      path: Nutrition/Info.plist
      properties:
        CFBundleDisplayName: Nutrition
        UILaunchScreen: {}
        UIApplicationSceneManifest:
          UIApplicationSupportsMultipleScenes: false
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
        ITSAppUsesNonExemptEncryption: false
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.khxsh.nutrition
        TARGETED_DEVICE_FAMILY: "1"  # iPhone only

  NutritionTests:
    type: bundle.unit-test
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: NutritionTests
    dependencies:
      - target: Nutrition
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.khxsh.nutrition.tests
        BUNDLE_LOADER: "$(TEST_HOST)"
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/Nutrition.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Nutrition"
```

- [ ] **Step 3: Create minimal `Info.plist` and source folders**

```bash
cd /Users/khxsh/Documents/repos/projects/nutrition-ios
mkdir -p Nutrition/{Config,Networking,Models,State,Views/Components} NutritionTests/Fixtures
```

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/Info.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
```

(xcodegen merges the `info.properties` from `project.yml` into this at generate time.)

- [ ] **Step 4: Add a placeholder source so xcodegen accepts the target**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/NutritionApp.swift`

```swift
import SwiftUI

@main
struct NutritionApp: App {
    var body: some Scene {
        WindowGroup {
            Text("scaffold")
        }
    }
}
```

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/NutritionTests/PlaceholderTests.swift`

```swift
import XCTest

final class PlaceholderTests: XCTestCase {
    func testPlaceholder() { XCTAssertTrue(true) }
}
```

- [ ] **Step 5: Generate the Xcode project**

```bash
cd /Users/khxsh/Documents/repos/projects/nutrition-ios
xcodegen generate
ls Nutrition.xcodeproj
```

Expected: `Nutrition.xcodeproj` exists, contains `project.pbxproj`.

- [ ] **Step 6: Verify it builds (use installed simulator)**

```bash
cd /Users/khxsh/Documents/repos/projects/nutrition-ios
xcodebuild -project Nutrition.xcodeproj -scheme Nutrition \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3.1' \
  -quiet build
```

Expected: `BUILD SUCCEEDED`. If iPhone 15 Pro isn't available, run `xcrun simctl list devices available` and pick any iPhone listed.

- [ ] **Step 7: Verify tests build & run**

```bash
xcodebuild -project Nutrition.xcodeproj -scheme Nutrition \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3.1' \
  test -quiet
```

Expected: `TEST SUCCEEDED` with 1 passing test.

- [ ] **Step 8: Add `Nutrition.xcodeproj` to .gitignore generation list, commit scaffold**

Update `.gitignore` — add `Nutrition.xcodeproj/` (we regenerate from `project.yml`):

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/.gitignore` — append:

```
# xcodegen — regenerate from project.yml
Nutrition.xcodeproj/
```

Then:

```bash
git add .gitignore project.yml Nutrition/ NutritionTests/
git commit -m "scaffold: xcodegen project, placeholder app + test"
```

---

## Task 2: Constants

**Files:**
- Create: `Nutrition/Config/Constants.swift`

- [ ] **Step 1: Write the constants file**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/Config/Constants.swift`

```swift
import Foundation

enum Constants {
    static let userKey = "khash"

    enum Defaults {
        static let baseURL = "nutrition.baseURL"
    }

    enum Keychain {
        static let service = "com.khxsh.nutrition.apikey"
        static let account = "default"
    }
}
```

- [ ] **Step 2: Regenerate, verify build**

```bash
xcodegen generate
xcodebuild -project Nutrition.xcodeproj -scheme Nutrition \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3.1' -quiet build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Nutrition/Config/Constants.swift
git commit -m "feat: constants for user key and storage locations"
```

---

## Task 3: KeychainStore

**Files:**
- Create: `Nutrition/Config/KeychainStore.swift`

- [ ] **Step 1: Write the Keychain wrapper**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/Config/KeychainStore.swift`

```swift
import Foundation
import Security

enum KeychainStore {
    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: Constants.Keychain.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    static func write(_ value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: Constants.Keychain.account,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: Constants.Keychain.account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

- [ ] **Step 2: Regenerate, verify build**

```bash
xcodegen generate
xcodebuild -project Nutrition.xcodeproj -scheme Nutrition \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3.1' -quiet build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Nutrition/Config/KeychainStore.swift
git commit -m "feat: keychain wrapper for API key"
```

---

## Task 4: Domain models

**Files:**
- Create: `Nutrition/Models/MacroTotals.swift`
- Create: `Nutrition/Models/MacroTargets.swift`
- Create: `Nutrition/Models/FoodEntry.swift`
- Create: `Nutrition/Models/DailySummary.swift`
- Create: `Nutrition/Models/DailyLog.swift`
- Create: `Nutrition/Networking/DateOnlyCoding.swift`
- Create: `NutritionTests/Fixtures/summary.json`
- Create: `NutritionTests/Fixtures/logs.json`
- Create: `NutritionTests/DecodingTests.swift`

Server response shapes (from `nutrition-server/src/nutrition_server/models/`):
- `MacroTotals`: `{calories: int, protein_g: float, carbs_g: float, fat_g: float}`
- `MacroTargets`: same fields, all positive
- `FoodEntryResponse`: id (UUID), daily_log_id (UUID), user_key (str), entry_group_id (UUID), display_name (str), quantity_text (str), normalized_quantity_value (float?), normalized_quantity_unit (str?), usda_fdc_id (int?), usda_description (str?), custom_food_id (UUID?), calories (int), protein_g (float), carbs_g (float), fat_g (float), consumed_at (datetime ISO-8601), created_at (datetime ISO-8601)
- `DailySummaryResponse`: `{date: YYYY-MM-DD, target: MacroTargets, consumed: MacroTotals, remaining: MacroTotals, entries: [FoodEntryResponse]}`
- `DailyLogSummary`: `{date: YYYY-MM-DD, total_calories: int, total_protein_g: float, total_carbs_g: float, total_fat_g: float, entry_count: int}`
- `LogsListResponse`: `{logs: [DailyLogSummary]}`

- [ ] **Step 1: Write fixture `summary.json`**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/NutritionTests/Fixtures/summary.json`

```json
{
  "date": "2026-05-06",
  "target": {
    "calories": 2200,
    "protein_g": 150.0,
    "carbs_g": 250.0,
    "fat_g": 70.0
  },
  "consumed": {
    "calories": 740,
    "protein_g": 67.0,
    "carbs_g": 55.0,
    "fat_g": 25.0
  },
  "remaining": {
    "calories": 1460,
    "protein_g": 83.0,
    "carbs_g": 195.0,
    "fat_g": 45.0
  },
  "entries": [
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "daily_log_id": "22222222-2222-2222-2222-222222222222",
      "user_key": "khash",
      "entry_group_id": "33333333-3333-3333-3333-333333333333",
      "display_name": "Oats, raw",
      "quantity_text": "80 g",
      "normalized_quantity_value": 80.0,
      "normalized_quantity_unit": "g",
      "usda_fdc_id": 173904,
      "usda_description": "Oats, raw",
      "custom_food_id": null,
      "calories": 320,
      "protein_g": 10.0,
      "carbs_g": 54.0,
      "fat_g": 6.0,
      "consumed_at": "2026-05-06T08:30:00+00:00",
      "created_at": "2026-05-06T08:31:00+00:00"
    },
    {
      "id": "44444444-4444-4444-4444-444444444444",
      "daily_log_id": "22222222-2222-2222-2222-222222222222",
      "user_key": "khash",
      "entry_group_id": "55555555-5555-5555-5555-555555555555",
      "display_name": "Eggs",
      "quantity_text": "2 large",
      "normalized_quantity_value": 100.0,
      "normalized_quantity_unit": "g",
      "usda_fdc_id": 748967,
      "usda_description": "Egg, whole, raw, large",
      "custom_food_id": null,
      "calories": 180,
      "protein_g": 12.0,
      "carbs_g": 1.0,
      "fat_g": 14.0,
      "consumed_at": "2026-05-06T08:35:00+00:00",
      "created_at": "2026-05-06T08:36:00+00:00"
    },
    {
      "id": "66666666-6666-6666-6666-666666666666",
      "daily_log_id": "22222222-2222-2222-2222-222222222222",
      "user_key": "khash",
      "entry_group_id": "77777777-7777-7777-7777-777777777777",
      "display_name": "Chicken breast",
      "quantity_text": "150 g",
      "normalized_quantity_value": 150.0,
      "normalized_quantity_unit": "g",
      "usda_fdc_id": null,
      "usda_description": null,
      "custom_food_id": "88888888-8888-8888-8888-888888888888",
      "calories": 240,
      "protein_g": 45.0,
      "carbs_g": 0.0,
      "fat_g": 5.0,
      "consumed_at": "2026-05-06T13:00:00+00:00",
      "created_at": "2026-05-06T13:01:00+00:00"
    }
  ]
}
```

- [ ] **Step 2: Write fixture `logs.json`**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/NutritionTests/Fixtures/logs.json`

```json
{
  "logs": [
    { "date": "2026-05-06", "total_calories": 740, "total_protein_g": 67.0, "total_carbs_g": 55.0, "total_fat_g": 25.0, "entry_count": 3 },
    { "date": "2026-05-05", "total_calories": 1980, "total_protein_g": 120.0, "total_carbs_g": 180.0, "total_fat_g": 70.0, "entry_count": 5 },
    { "date": "2026-05-04", "total_calories": 2460, "total_protein_g": 145.0, "total_carbs_g": 280.0, "total_fat_g": 90.0, "entry_count": 6 },
    { "date": "2026-05-03", "total_calories": 2210, "total_protein_g": 130.0, "total_carbs_g": 240.0, "total_fat_g": 75.0, "entry_count": 4 },
    { "date": "2026-05-02", "total_calories": 1890, "total_protein_g": 110.0, "total_carbs_g": 195.0, "total_fat_g": 65.0, "entry_count": 5 },
    { "date": "2026-05-01", "total_calories": 2050, "total_protein_g": 125.0, "total_carbs_g": 220.0, "total_fat_g": 68.0, "entry_count": 4 },
    { "date": "2026-04-30", "total_calories": 2300, "total_protein_g": 140.0, "total_carbs_g": 260.0, "total_fat_g": 72.0, "entry_count": 5 }
  ]
}
```

- [ ] **Step 3: Add fixtures to test target as resources**

Update `project.yml` `NutritionTests` section to include the fixtures as resources. Replace the entire `NutritionTests:` block in `/Users/khxsh/Documents/repos/projects/nutrition-ios/project.yml` with:

```yaml
  NutritionTests:
    type: bundle.unit-test
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: NutritionTests
        excludes:
          - "Fixtures"
    resources:
      - path: NutritionTests/Fixtures
    dependencies:
      - target: Nutrition
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.khxsh.nutrition.tests
        BUNDLE_LOADER: "$(TEST_HOST)"
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/Nutrition.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Nutrition"
```

- [ ] **Step 4: Write `DateOnlyCoding.swift`**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/Networking/DateOnlyCoding.swift`

```swift
import Foundation

enum DateOnly {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func decode(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let date = formatter.date(from: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected YYYY-MM-DD, got '\(raw)'"
            )
        }
        return date
    }

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}

extension JSONDecoder {
    static func nutritionDefault() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            // Try date-only first
            if let date = DateOnly.formatter.date(from: raw) {
                return date
            }
            // Fall back to ISO-8601 with fractional seconds tolerance
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: raw) { return date }
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date format: '\(raw)'"
            )
        }
        return d
    }
}
```

- [ ] **Step 5: Write `MacroTotals.swift` and `MacroTargets.swift`**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/Models/MacroTotals.swift`

```swift
import Foundation

struct MacroTotals: Codable, Equatable {
    let calories: Int
    let proteinG: Double
    let carbsG: Double
    let fatG: Double

    enum CodingKeys: String, CodingKey {
        case calories
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
    }
}
```

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/Models/MacroTargets.swift`

```swift
import Foundation

struct MacroTargets: Codable, Equatable {
    let calories: Int
    let proteinG: Double
    let carbsG: Double
    let fatG: Double

    enum CodingKeys: String, CodingKey {
        case calories
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
    }
}
```

- [ ] **Step 6: Write `FoodEntry.swift`**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/Models/FoodEntry.swift`

```swift
import Foundation

struct FoodEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let dailyLogId: UUID
    let userKey: String
    let entryGroupId: UUID
    let displayName: String
    let quantityText: String
    let normalizedQuantityValue: Double?
    let normalizedQuantityUnit: String?
    let usdaFdcId: Int?
    let usdaDescription: String?
    let customFoodId: UUID?
    let calories: Int
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
    let consumedAt: Date
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case dailyLogId = "daily_log_id"
        case userKey = "user_key"
        case entryGroupId = "entry_group_id"
        case displayName = "display_name"
        case quantityText = "quantity_text"
        case normalizedQuantityValue = "normalized_quantity_value"
        case normalizedQuantityUnit = "normalized_quantity_unit"
        case usdaFdcId = "usda_fdc_id"
        case usdaDescription = "usda_description"
        case customFoodId = "custom_food_id"
        case calories
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case consumedAt = "consumed_at"
        case createdAt = "created_at"
    }
}
```

- [ ] **Step 7: Write `DailySummary.swift`**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/Models/DailySummary.swift`

```swift
import Foundation

struct DailySummary: Codable, Equatable {
    let date: Date              // YYYY-MM-DD
    let target: MacroTargets
    let consumed: MacroTotals
    let remaining: MacroTotals
    let entries: [FoodEntry]
}
```

- [ ] **Step 8: Write `DailyLog.swift`**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/Models/DailyLog.swift`

```swift
import Foundation

struct DailyLog: Codable, Identifiable, Equatable {
    var id: Date { date }
    let date: Date              // YYYY-MM-DD
    let totalCalories: Int
    let totalProteinG: Double
    let totalCarbsG: Double
    let totalFatG: Double
    let entryCount: Int

    enum CodingKeys: String, CodingKey {
        case date
        case totalCalories = "total_calories"
        case totalProteinG = "total_protein_g"
        case totalCarbsG = "total_carbs_g"
        case totalFatG = "total_fat_g"
        case entryCount = "entry_count"
    }
}

struct LogsList: Codable, Equatable {
    let logs: [DailyLog]
}
```

- [ ] **Step 9: Write the failing decoding tests**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/NutritionTests/DecodingTests.swift`

```swift
import XCTest
@testable import Nutrition

final class DecodingTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            XCTFail("Fixture \(name).json not found in test bundle")
            throw NSError(domain: "fixture", code: 0)
        }
        return try Data(contentsOf: url)
    }

    func testDecodeDailySummary() throws {
        let data = try loadFixture("summary")
        let summary = try JSONDecoder.nutritionDefault().decode(DailySummary.self, from: data)

        XCTAssertEqual(summary.target.calories, 2200)
        XCTAssertEqual(summary.consumed.calories, 740)
        XCTAssertEqual(summary.remaining.calories, 1460)
        XCTAssertEqual(summary.entries.count, 3)

        let oats = summary.entries[0]
        XCTAssertEqual(oats.displayName, "Oats, raw")
        XCTAssertEqual(oats.calories, 320)
        XCTAssertEqual(oats.proteinG, 10.0)
        XCTAssertEqual(oats.usdaFdcId, 173904)
        XCTAssertNil(oats.customFoodId)

        let chicken = summary.entries[2]
        XCTAssertNil(chicken.usdaFdcId)
        XCTAssertEqual(chicken.customFoodId?.uuidString, "88888888-8888-8888-8888-888888888888")
    }

    func testDecodeLogsList() throws {
        let data = try loadFixture("logs")
        let list = try JSONDecoder.nutritionDefault().decode(LogsList.self, from: data)

        XCTAssertEqual(list.logs.count, 7)
        XCTAssertEqual(list.logs[0].totalCalories, 740)
        XCTAssertEqual(list.logs[0].entryCount, 3)
        XCTAssertEqual(list.logs[6].totalCalories, 2300)
    }

    func testSummaryDateIsParsedAsCalendarDate() throws {
        let data = try loadFixture("summary")
        let summary = try JSONDecoder.nutritionDefault().decode(DailySummary.self, from: data)
        let str = DateOnly.string(from: summary.date)
        XCTAssertEqual(str, "2026-05-06")
    }
}
```

- [ ] **Step 10: Regenerate, run tests — they should pass**

```bash
cd /Users/khxsh/Documents/repos/projects/nutrition-ios
xcodegen generate
xcodebuild -project Nutrition.xcodeproj -scheme Nutrition \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3.1' \
  test -quiet 2>&1 | grep -E "(Test Suite|TEST|FAIL|error:)" | head -20
```

Expected: 3 decoding tests pass + the placeholder test. `TEST SUCCEEDED`.

If a test fails: read the assertion message and fix the model/decoder. Do not modify the fixture (it represents the server contract).

- [ ] **Step 11: Delete the placeholder test**

```bash
rm NutritionTests/PlaceholderTests.swift
xcodegen generate
xcodebuild -project Nutrition.xcodeproj -scheme Nutrition \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3.1' test -quiet
```

Expected: 3 tests pass.

- [ ] **Step 12: Commit**

```bash
git add Nutrition/Models Nutrition/Networking/DateOnlyCoding.swift NutritionTests project.yml
git commit -m "feat: domain models + decoding tests against server fixtures"
```

---

## Task 5: NutritionError

**Files:**
- Create: `Nutrition/Networking/NutritionError.swift`

- [ ] **Step 1: Write the error enum**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/Networking/NutritionError.swift`

```swift
import Foundation

enum NutritionError: Error, Equatable {
    case notConfigured
    case unauthorized
    case notFound
    case network(URLError)
    case decoding(String)
    case server(status: Int)

    static func == (lhs: NutritionError, rhs: NutritionError) -> Bool {
        switch (lhs, rhs) {
        case (.notConfigured, .notConfigured),
             (.unauthorized, .unauthorized),
             (.notFound, .notFound):
            return true
        case let (.network(a), .network(b)):
            return a.code == b.code
        case let (.decoding(a), .decoding(b)):
            return a == b
        case let (.server(a), .server(b)):
            return a == b
        default:
            return false
        }
    }

    var userMessage: String {
        switch self {
        case .notConfigured: return "Set the server URL and API key in Settings."
        case .unauthorized:  return "API key rejected. Check Settings."
        case .notFound:      return "No data for this date."
        case .network:       return "Network error. Check your connection."
        case .decoding:      return "Couldn't read the server response."
        case .server(let s): return "Server error (\(s)). Try again."
        }
    }
}
```

- [ ] **Step 2: Verify build, commit**

```bash
xcodegen generate
xcodebuild -project Nutrition.xcodeproj -scheme Nutrition \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3.1' -quiet build
git add Nutrition/Networking/NutritionError.swift
git commit -m "feat: NutritionError with user-facing messages"
```

---

## Task 6: NutritionClient

**Files:**
- Create: `Nutrition/Networking/NutritionClient.swift`
- Create: `NutritionTests/NutritionClientTests.swift`

- [ ] **Step 1: Write the failing client tests using URLProtocol stub**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/NutritionTests/NutritionClientTests.swift`

```swift
import XCTest
@testable import Nutrition

final class StubURLProtocol: URLProtocol {
    static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class NutritionClientTests: XCTestCase {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(forResource: name, withExtension: "json")!
        return try Data(contentsOf: url)
    }

    override func tearDown() {
        StubURLProtocol.responder = nil
        super.tearDown()
    }

    func testSummaryRequestSendsApiKeyAndUserKey() async throws {
        let summaryJSON = try loadFixture("summary")
        var capturedRequest: URLRequest?
        StubURLProtocol.responder = { req in
            capturedRequest = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, summaryJSON)
        }

        let client = NutritionClient(
            baseURL: URL(string: "https://example.test")!,
            apiKey: "secret-key",
            session: makeSession()
        )

        let date = DateOnly.formatter.date(from: "2026-05-06")!
        let summary = try await client.summary(date: date)

        XCTAssertEqual(summary.target.calories, 2200)
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "X-API-Key"), "secret-key")
        XCTAssertEqual(capturedRequest?.url?.path, "/summary/2026-05-06")
        XCTAssertEqual(capturedRequest?.url?.query, "user_key=khash")
    }

    func testLogsRequestUsesFromAndToParams() async throws {
        let logsJSON = try loadFixture("logs")
        var capturedURL: URL?
        StubURLProtocol.responder = { req in
            capturedURL = req.url
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, logsJSON)
        }

        let client = NutritionClient(
            baseURL: URL(string: "https://example.test")!,
            apiKey: "k",
            session: makeSession()
        )
        let from = DateOnly.formatter.date(from: "2026-04-30")!
        let to = DateOnly.formatter.date(from: "2026-05-06")!
        let list = try await client.logs(from: from, to: to)

        XCTAssertEqual(list.logs.count, 7)
        XCTAssertEqual(capturedURL?.path, "/logs")
        let q = capturedURL?.query ?? ""
        XCTAssertTrue(q.contains("from=2026-04-30"))
        XCTAssertTrue(q.contains("to=2026-05-06"))
        XCTAssertTrue(q.contains("user_key=khash"))
    }

    func test401MapsToUnauthorized() async throws {
        StubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = NutritionClient(
            baseURL: URL(string: "https://example.test")!,
            apiKey: "k",
            session: makeSession()
        )
        let date = DateOnly.formatter.date(from: "2026-05-06")!
        do {
            _ = try await client.summary(date: date)
            XCTFail("Expected unauthorized error")
        } catch let error as NutritionError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func test404MapsToNotFound() async throws {
        StubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = NutritionClient(
            baseURL: URL(string: "https://example.test")!,
            apiKey: "k",
            session: makeSession()
        )
        let date = DateOnly.formatter.date(from: "2026-05-06")!
        do {
            _ = try await client.summary(date: date)
            XCTFail("Expected notFound error")
        } catch let error as NutritionError {
            XCTAssertEqual(error, .notFound)
        }
    }
}
```

- [ ] **Step 2: Run tests — they should fail (NutritionClient doesn't exist yet)**

```bash
xcodegen generate
xcodebuild -project Nutrition.xcodeproj -scheme Nutrition \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3.1' test -quiet 2>&1 | tail -10
```

Expected: build error referencing `NutritionClient`.

- [ ] **Step 3: Implement `NutritionClient`**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/Networking/NutritionClient.swift`

```swift
import Foundation

actor NutritionClient {
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    private let decoder: JSONDecoder

    init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
        self.decoder = JSONDecoder.nutritionDefault()
    }

    func summary(date: Date) async throws -> DailySummary {
        let path = "/summary/\(DateOnly.string(from: date))"
        let url = try makeURL(path: path, query: [URLQueryItem(name: "user_key", value: Constants.userKey)])
        return try await fetch(url: url)
    }

    func logs(from: Date, to: Date) async throws -> LogsList {
        let url = try makeURL(
            path: "/logs",
            query: [
                URLQueryItem(name: "from", value: DateOnly.string(from: from)),
                URLQueryItem(name: "to", value: DateOnly.string(from: to)),
                URLQueryItem(name: "user_key", value: Constants.userKey),
            ]
        )
        return try await fetch(url: url)
    }

    // MARK: - private

    private func makeURL(path: String, query: [URLQueryItem]) throws -> URL {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw NutritionError.notConfigured
        }
        comps.queryItems = query
        guard let url = comps.url else { throw NutritionError.notConfigured }
        return url
    }

    private func fetch<T: Decodable>(url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let urlError as URLError {
            throw NutritionError.network(urlError)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NutritionError.server(status: -1)
        }

        switch http.statusCode {
        case 200..<300:
            do {
                return try decoder.decode(T.self, from: data)
            } catch let decodingError {
                throw NutritionError.decoding(String(describing: decodingError))
            }
        case 401, 403:
            throw NutritionError.unauthorized
        case 404:
            throw NutritionError.notFound
        case 500...:
            throw NutritionError.server(status: http.statusCode)
        default:
            throw NutritionError.server(status: http.statusCode)
        }
    }
}
```

- [ ] **Step 4: Run tests — should pass**

```bash
xcodegen generate
xcodebuild -project Nutrition.xcodeproj -scheme Nutrition \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3.1' test -quiet 2>&1 | grep -E "(Test Suite|Executed|FAIL)" | tail -10
```

Expected: All tests pass (3 decoding + 4 client = 7 tests).

- [ ] **Step 5: Commit**

```bash
git add Nutrition/Networking/NutritionClient.swift NutritionTests/NutritionClientTests.swift
git commit -m "feat: NutritionClient actor with URLProtocol-stubbed tests"
```

---

## Task 7: AppSettings (@Observable)

**Files:**
- Create: `Nutrition/State/AppSettings.swift`

- [ ] **Step 1: Write the settings observable**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/State/AppSettings.swift`

```swift
import Foundation
import Observation

@Observable
final class AppSettings {
    var baseURLString: String {
        didSet { UserDefaults.standard.set(baseURLString, forKey: Constants.Defaults.baseURL) }
    }
    var apiKey: String {
        didSet { KeychainStore.write(apiKey) }
    }

    init() {
        self.baseURLString = UserDefaults.standard.string(forKey: Constants.Defaults.baseURL) ?? ""
        self.apiKey = KeychainStore.read() ?? ""
    }

    var isConfigured: Bool {
        !baseURLString.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: baseURLString) != nil
    }

    func makeClient() -> NutritionClient? {
        guard isConfigured, let url = URL(string: baseURLString) else { return nil }
        return NutritionClient(baseURL: url, apiKey: apiKey)
    }
}
```

- [ ] **Step 2: Build, commit**

```bash
xcodegen generate
xcodebuild -project Nutrition.xcodeproj -scheme Nutrition \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3.1' -quiet build
git add Nutrition/State/AppSettings.swift
git commit -m "feat: AppSettings @Observable wires UserDefaults + Keychain"
```

---

## Task 8: LoadState

**Files:**
- Create: `Nutrition/State/LoadState.swift`

- [ ] **Step 1: Write the enum**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/State/LoadState.swift`

```swift
import Foundation

enum LoadState<T> {
    case idle
    case loading
    case loaded(T)
    case failed(NutritionError)
}
```

- [ ] **Step 2: Build, commit**

```bash
xcodegen generate
xcodebuild -project Nutrition.xcodeproj -scheme Nutrition \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3.1' -quiet build
git add Nutrition/State/LoadState.swift
git commit -m "feat: LoadState enum"
```

---

## Task 9: DayMacroModel

**Files:**
- Create: `Nutrition/State/DayMacroModel.swift`

- [ ] **Step 1: Write the model**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/State/DayMacroModel.swift`

```swift
import Foundation
import Observation

@Observable
final class DayMacroModel {
    let date: Date
    private(set) var state: LoadState<DailySummary> = .idle
    private weak var settings: AppSettings?

    init(date: Date, settings: AppSettings) {
        self.date = date
        self.settings = settings
    }

    func load() async {
        guard let client = settings?.makeClient() else {
            state = .failed(.notConfigured)
            return
        }
        state = .loading
        do {
            let summary = try await client.summary(date: date)
            state = .loaded(summary)
        } catch let error as NutritionError {
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }
}
```

- [ ] **Step 2: Build, commit**

```bash
xcodegen generate
xcodebuild -project Nutrition.xcodeproj -scheme Nutrition \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3.1' -quiet build
git add Nutrition/State/DayMacroModel.swift
git commit -m "feat: DayMacroModel @Observable"
```

---

## Task 10: WeekModel

**Files:**
- Create: `Nutrition/State/WeekModel.swift`

- [ ] **Step 1: Write the model**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/State/WeekModel.swift`

```swift
import Foundation
import Observation

@Observable
final class WeekModel {
    private(set) var state: LoadState<LogsList> = .idle
    private weak var settings: AppSettings?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func loadLast7Days(today: Date = Date()) async {
        guard let client = settings?.makeClient() else {
            state = .failed(.notConfigured)
            return
        }
        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -6, to: today) ?? today
        state = .loading
        do {
            let logs = try await client.logs(from: from, to: today)
            state = .loaded(logs)
        } catch let error as NutritionError {
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }

    /// Average kcal per logged day (skips days with 0 entries).
    static func avgCalories(_ logs: [DailyLog]) -> Int {
        let logged = logs.filter { $0.entryCount > 0 }
        guard !logged.isEmpty else { return 0 }
        return logged.map(\.totalCalories).reduce(0, +) / logged.count
    }

    static func avgProtein(_ logs: [DailyLog]) -> Double {
        let logged = logs.filter { $0.entryCount > 0 }
        guard !logged.isEmpty else { return 0 }
        return logged.map(\.totalProteinG).reduce(0, +) / Double(logged.count)
    }

    static func avgCarbs(_ logs: [DailyLog]) -> Double {
        let logged = logs.filter { $0.entryCount > 0 }
        guard !logged.isEmpty else { return 0 }
        return logged.map(\.totalCarbsG).reduce(0, +) / Double(logged.count)
    }

    static func avgFat(_ logs: [DailyLog]) -> Double {
        let logged = logs.filter { $0.entryCount > 0 }
        guard !logged.isEmpty else { return 0 }
        return logged.map(\.totalFatG).reduce(0, +) / Double(logged.count)
    }
}
```

- [ ] **Step 2: Build, commit**

```bash
xcodegen generate
xcodebuild -project Nutrition.xcodeproj -scheme Nutrition \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3.1' -quiet build
git add Nutrition/State/WeekModel.swift
git commit -m "feat: WeekModel @Observable + average helpers"
```

---

## Task 11: UI components

**Files:**
- Create: `Nutrition/Views/Components/MacroRing.swift`
- Create: `Nutrition/Views/Components/MacroTotalsRow.swift`
- Create: `Nutrition/Views/Components/EntryRow.swift`
- Create: `Nutrition/Views/Components/DailyKcalBars.swift`
- Create: `Nutrition/Views/Components/AverageMacrosTable.swift`

- [ ] **Step 1: `MacroRing.swift`**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/Views/Components/MacroRing.swift`

```swift
import SwiftUI

struct MacroRing: View {
    let consumed: Int
    let target: Int

    private var progress: Double {
        guard target > 0 else { return 0 }
        return min(1.0, Double(consumed) / Double(target))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 12)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.tint, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut, value: progress)
            VStack(spacing: 2) {
                Text("\(consumed)")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("of \(target) kcal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 140, height: 140)
    }
}

#Preview {
    MacroRing(consumed: 740, target: 2200)
        .padding()
}
```

- [ ] **Step 2: `MacroTotalsRow.swift`**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/Views/Components/MacroTotalsRow.swift`

```swift
import SwiftUI

struct MacroTotalsRow: View {
    let totals: MacroTotals
    let targets: MacroTargets?

    var body: some View {
        HStack(spacing: 8) {
            cell(label: "Protein", value: totals.proteinG, target: targets?.proteinG, color: .blue)
            cell(label: "Carbs",   value: totals.carbsG,   target: targets?.carbsG,   color: .orange)
            cell(label: "Fat",     value: totals.fatG,     target: targets?.fatG,     color: .pink)
        }
    }

    private func cell(label: String, value: Double, target: Double?, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                Text("\(Int(value.rounded()))")
                    .font(.headline)
                    .monospacedDigit()
                Text("g")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let target {
                Text("/ \(Int(target.rounded()))g")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    MacroTotalsRow(
        totals: MacroTotals(calories: 740, proteinG: 67, carbsG: 55, fatG: 25),
        targets: MacroTargets(calories: 2200, proteinG: 150, carbsG: 250, fatG: 70)
    )
    .padding()
}
```

- [ ] **Step 3: `EntryRow.swift`**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/Views/Components/EntryRow.swift`

```swift
import SwiftUI

struct EntryRow: View {
    let entry: FoodEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(entry.quantityText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(entry.calories) kcal")
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                    .monospacedDigit()
            }
            HStack(spacing: 12) {
                macro(label: "P", grams: entry.proteinG, color: .blue)
                macro(label: "C", grams: entry.carbsG,   color: .orange)
                macro(label: "F", grams: entry.fatG,     color: .pink)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func macro(label: String, grams: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(label) \(Int(grams.rounded()))g")
        }
    }
}

#Preview {
    List {
        EntryRow(entry: FoodEntry(
            id: UUID(), dailyLogId: UUID(), userKey: "khash", entryGroupId: UUID(),
            displayName: "Oats, raw", quantityText: "80 g",
            normalizedQuantityValue: 80, normalizedQuantityUnit: "g",
            usdaFdcId: 173904, usdaDescription: "Oats, raw", customFoodId: nil,
            calories: 320, proteinG: 10, carbsG: 54, fatG: 6,
            consumedAt: Date(), createdAt: Date()
        ))
    }
}
```

- [ ] **Step 4: `DailyKcalBars.swift`**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/Views/Components/DailyKcalBars.swift`

```swift
import SwiftUI

struct DailyKcalBars: View {
    /// Logs in chronological (oldest → newest) order — caller passes them this way.
    let logs: [DailyLog]
    let targetCalories: Int?

    private var maxKcal: Int {
        max(logs.map(\.totalCalories).max() ?? 0, targetCalories ?? 0, 1)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(logs) { log in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.tint)
                            .frame(height: barHeight(for: log.totalCalories))
                        Text(weekdayLetter(log.date))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 140)
            if let target = targetCalories {
                Text("Target: \(target) kcal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func barHeight(for kcal: Int) -> CGFloat {
        let ratio = CGFloat(kcal) / CGFloat(maxKcal)
        return max(2, ratio * 120)
    }

    private func weekdayLetter(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEEE"   // narrow weekday: M T W T F S S
        return f.string(from: date)
    }
}

#Preview {
    let cal = Calendar.current
    let today = Date()
    let logs: [DailyLog] = (0..<7).reversed().map { offset in
        DailyLog(
            date: cal.date(byAdding: .day, value: -offset, to: today)!,
            totalCalories: Int.random(in: 1200...2400),
            totalProteinG: Double.random(in: 80...150),
            totalCarbsG: Double.random(in: 150...280),
            totalFatG: Double.random(in: 50...90),
            entryCount: 4
        )
    }
    return DailyKcalBars(logs: logs, targetCalories: 2200).padding()
}
```

- [ ] **Step 5: `AverageMacrosTable.swift`**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/Views/Components/AverageMacrosTable.swift`

```swift
import SwiftUI

struct AverageMacrosTable: View {
    let logs: [DailyLog]

    var body: some View {
        VStack(spacing: 0) {
            row(label: "Avg / day", value: "\(WeekModel.avgCalories(logs)) kcal", isHeader: true)
            row(label: "Protein",   value: "\(Int(WeekModel.avgProtein(logs).rounded())) g")
            row(label: "Carbs",     value: "\(Int(WeekModel.avgCarbs(logs).rounded())) g")
            row(label: "Fat",       value: "\(Int(WeekModel.avgFat(logs).rounded())) g")
        }
    }

    private func row(label: String, value: String, isHeader: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(isHeader ? .subheadline.bold() : .subheadline)
            Spacer()
            Text(value)
                .font(isHeader ? .subheadline.bold() : .subheadline)
                .monospacedDigit()
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

#Preview {
    let cal = Calendar.current
    let today = Date()
    let logs: [DailyLog] = (0..<7).reversed().map { offset in
        DailyLog(
            date: cal.date(byAdding: .day, value: -offset, to: today)!,
            totalCalories: 2000 + offset * 50,
            totalProteinG: 120,
            totalCarbsG: 220,
            totalFatG: 70,
            entryCount: 4
        )
    }
    return AverageMacrosTable(logs: logs).padding()
}
```

- [ ] **Step 6: Build, commit**

```bash
xcodegen generate
xcodebuild -project Nutrition.xcodeproj -scheme Nutrition \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3.1' -quiet build
git add Nutrition/Views/Components
git commit -m "feat: UI components — ring, totals row, entry row, bars, averages"
```

---

## Task 12: DayMacroView

**Files:**
- Create: `Nutrition/Views/DayMacroView.swift`

- [ ] **Step 1: Write the view**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/Views/DayMacroView.swift`

```swift
import SwiftUI

struct DayMacroView: View {
    let date: Date
    @Environment(AppSettings.self) private var settings
    @State private var model: DayMacroModel?

    var body: some View {
        Group {
            switch model?.state ?? .idle {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let summary):
                loadedBody(summary)
            case .failed(let error):
                errorBody(error)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: date) {
            if model == nil { model = DayMacroModel(date: date, settings: settings) }
            await model?.load()
        }
        .refreshable { await model?.load() }
    }

    private var title: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return f.string(from: date)
    }

    @ViewBuilder
    private func loadedBody(_ summary: DailySummary) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                MacroRing(consumed: summary.consumed.calories, target: summary.target.calories)
                    .padding(.top, 12)
                MacroTotalsRow(totals: summary.consumed, targets: summary.target)
                    .padding(.horizontal)

                if summary.entries.isEmpty {
                    ContentUnavailableView("No entries logged",
                                           systemImage: "fork.knife",
                                           description: Text("Anything you log will appear here."))
                        .padding(.top, 40)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(summary.entries) { entry in
                            EntryRow(entry: entry)
                                .padding(.horizontal)
                            Divider().padding(.leading)
                        }
                    }
                    .padding(.top, 8)
                }

                Spacer(minLength: 80) // room for floating dock
            }
        }
    }

    @ViewBuilder
    private func errorBody(_ error: NutritionError) -> some View {
        switch error {
        case .notFound:
            ContentUnavailableView {
                Label("No targets set", systemImage: "target")
            } description: {
                Text("Set targets in the server to start tracking.")
            } actions: {
                Button("Retry") { Task { await model?.load() } }
            }
        default:
            ContentUnavailableView {
                Label("Couldn't load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.userMessage)
            } actions: {
                Button("Retry") { Task { await model?.load() } }
            }
        }
    }
}
```

- [ ] **Step 2: Build, commit**

```bash
xcodegen generate
xcodebuild -project Nutrition.xcodeproj -scheme Nutrition \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3.1' -quiet build
git add Nutrition/Views/DayMacroView.swift
git commit -m "feat: DayMacroView for Today + DayDetail"
```

---

## Task 13: WeekView

**Files:**
- Create: `Nutrition/Views/WeekView.swift`

- [ ] **Step 1: Write the view**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/Views/WeekView.swift`

```swift
import SwiftUI

struct WeekView: View {
    @Environment(AppSettings.self) private var settings
    @State private var model: WeekModel?

    var body: some View {
        Group {
            switch model?.state ?? .idle {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let list):
                loadedBody(list.logs)
            case .failed(let error):
                ContentUnavailableView {
                    Label("Couldn't load week", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.userMessage)
                } actions: {
                    Button("Retry") { Task { await model?.loadLast7Days() } }
                }
            }
        }
        .navigationTitle("This week")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil { model = WeekModel(settings: settings) }
            await model?.loadLast7Days()
        }
        .refreshable { await model?.loadLast7Days() }
    }

    private func loadedBody(_ logs: [DailyLog]) -> some View {
        // Server returns desc; chart wants chronological ascending.
        let chronological = logs.sorted { $0.date < $1.date }
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DailyKcalBars(logs: chronological, targetCalories: nil)
                    .padding(.horizontal)
                    .padding(.top, 12)
                AverageMacrosTable(logs: chronological)
                    .padding(.horizontal)
                Spacer(minLength: 80) // room for dock
            }
        }
    }
}
```

- [ ] **Step 2: Build, commit**

```bash
xcodegen generate
xcodebuild -project Nutrition.xcodeproj -scheme Nutrition \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3.1' -quiet build
git add Nutrition/Views/WeekView.swift
git commit -m "feat: WeekView with bar chart + averages"
```

---

## Task 14: SettingsView

**Files:**
- Create: `Nutrition/Views/SettingsView.swift`

- [ ] **Step 1: Write the view**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/Views/SettingsView.swift`

```swift
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    /// When true, the sheet cannot be dismissed without valid config.
    let requireConfig: Bool

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://nutrition.up.railway.app", text: $settings.baseURLString)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    TextField("API key", text: $settings.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Text("User: \(Constants.userKey)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(requireConfig && !settings.isConfigured)
                }
            }
            .interactiveDismissDisabled(requireConfig && !settings.isConfigured)
        }
    }
}

#Preview {
    SettingsView(requireConfig: false)
        .environment(AppSettings())
}
```

- [ ] **Step 2: Build, commit**

```bash
xcodegen generate
xcodebuild -project Nutrition.xcodeproj -scheme Nutrition \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3.1' -quiet build
git add Nutrition/Views/SettingsView.swift
git commit -m "feat: SettingsView with required-config gate"
```

---

## Task 15: DatePickerSheet

**Files:**
- Create: `Nutrition/Views/DatePickerSheet.swift`

- [ ] **Step 1: Write the sheet**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/Views/DatePickerSheet.swift`

```swift
import SwiftUI

struct DatePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (Date) -> Void

    @State private var selected: Date = Date()

    var body: some View {
        NavigationStack {
            VStack {
                DatePicker("Pick a date",
                           selection: $selected,
                           in: ...Date(),
                           displayedComponents: [.date])
                    .datePickerStyle(.graphical)
                    .padding()
                Spacer()
            }
            .navigationTitle("Pick a date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") {
                        onPick(selected)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    DatePickerSheet { _ in }
}
```

- [ ] **Step 2: Build, commit**

```bash
xcodegen generate
xcodebuild -project Nutrition.xcodeproj -scheme Nutrition \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3.1' -quiet build
git add Nutrition/Views/DatePickerSheet.swift
git commit -m "feat: DatePickerSheet capped at today"
```

---

## Task 16: FloatingDock

**Files:**
- Create: `Nutrition/Views/FloatingDock.swift`

- [ ] **Step 1: Write the dock**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/Views/FloatingDock.swift`

```swift
import SwiftUI

enum DockTab {
    case today, week
}

struct FloatingDock: View {
    @Binding var tab: DockTab
    let onPickDate: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            button(label: "Today", system: "circle.fill", active: tab == .today) {
                tab = .today
            }
            button(label: "Week", system: "chart.bar.fill", active: tab == .week) {
                tab = .week
            }
            button(label: "Date", system: "calendar", active: false, action: onPickDate)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .padding(.bottom, 12)
    }

    private func button(label: String, system: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: system)
                    .font(.system(size: 14))
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(active ? Color.accentColor : .secondary)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    @Previewable @State var tab: DockTab = .today
    return ZStack(alignment: .bottom) {
        Color.gray.opacity(0.1).ignoresSafeArea()
        FloatingDock(tab: $tab, onPickDate: {})
    }
}
```

- [ ] **Step 2: Build, commit**

```bash
xcodegen generate
xcodebuild -project Nutrition.xcodeproj -scheme Nutrition \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3.1' -quiet build
git add Nutrition/Views/FloatingDock.swift
git commit -m "feat: FloatingDock with Today/Week/Date buttons"
```

---

## Task 17: RootView + NutritionApp wiring

**Files:**
- Create: `Nutrition/Views/RootView.swift`
- Modify: `Nutrition/NutritionApp.swift`

- [ ] **Step 1: Write `RootView`**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/Views/RootView.swift`

```swift
import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings

    @State private var tab: DockTab = .today
    @State private var path = NavigationPath()
    @State private var showSettings = false
    @State private var showDatePicker = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                .navigationDestination(for: Date.self) { date in
                    DayMacroView(date: date)
                }
        }
        .overlay(alignment: .bottom) {
            if path.isEmpty {
                FloatingDock(tab: $tab, onPickDate: { showDatePicker = true })
            }
        }
        .sheet(isPresented: $showDatePicker) {
            DatePickerSheet { picked in
                path.append(picked)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(requireConfig: false)
        }
        // Auto-present settings if not configured
        .sheet(isPresented: .constant(!settings.isConfigured && !showSettings)) {
            SettingsView(requireConfig: true)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .today: DayMacroView(date: Date())
        case .week:  WeekView()
        }
    }
}
```

- [ ] **Step 2: Replace `NutritionApp.swift`**

File: `/Users/khxsh/Documents/repos/projects/nutrition-ios/Nutrition/NutritionApp.swift`

```swift
import SwiftUI

@main
struct NutritionApp: App {
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
        }
    }
}
```

- [ ] **Step 3: Build, run all tests**

```bash
xcodegen generate
xcodebuild -project Nutrition.xcodeproj -scheme Nutrition \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3.1' test -quiet 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`, all 7 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Nutrition/NutritionApp.swift Nutrition/Views/RootView.swift
git commit -m "feat: RootView wiring + tab/sheet/dock orchestration"
```

---

## Task 18: Smoke test on simulator

- [ ] **Step 1: Boot the simulator and install the app**

```bash
cd /Users/khxsh/Documents/repos/projects/nutrition-ios
xcrun simctl boot "iPhone 16 Pro" 2>/dev/null || true
open -a Simulator
xcodebuild -project Nutrition.xcodeproj -scheme Nutrition \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3.1' \
  -derivedDataPath build -quiet build
APP_PATH="build/Build/Products/Debug-iphonesimulator/Nutrition.app"
xcrun simctl install booted "$APP_PATH"
xcrun simctl launch booted com.khxsh.nutrition
```

Expected: app launches in Simulator and presents the Settings sheet (no config yet).

- [ ] **Step 2: Manual checks** — perform each in the Simulator and confirm:

  - [ ] Settings sheet auto-presents.
  - [ ] Enter Railway URL + API key (from `nutrition-server/.env`), tap Done. Sheet dismisses.
  - [ ] Today screen loads — ring + macro totals + entry list (or "No entries logged" + a "Set targets" banner if no targets configured server-side).
  - [ ] Floating dock visible at bottom.
  - [ ] Tap Week → bar chart for last 7 days appears.
  - [ ] Tap calendar → date picker appears, pick a past date → DayDetail pushes; floating dock disappears; back button works.
  - [ ] Tap gear (top-right) → Settings sheet (now optional) appears, can dismiss without changes.
  - [ ] Pull-to-refresh on Today / Week works.

- [ ] **Step 3: Final commit if anything tweaked**

```bash
git status
# if anything changed during smoke test:
# git commit -am "fix: <whatever>"
```

- [ ] **Step 4: Tag v0.1.0**

```bash
git tag v0.1.0
git log --oneline | head -20
```

---

## Spec coverage check

| Spec section | Implemented in |
|---|---|
| Native SwiftUI iOS 17+ | Task 1 (project.yml deploymentTarget 17.0) |
| `NutritionClient` actor + `X-API-Key` | Task 6 |
| `@Observable` view-models with `LoadState<T>` | Tasks 7–10 |
| Floating dock overlay | Tasks 16, 17 |
| Server endpoints `/summary/{date}` and `/logs?from=&to=` | Task 6 |
| Models mirror server | Task 4 |
| Custom date decoding (YYYY-MM-DD + ISO-8601) | Task 4 |
| `DayMacroView` reused for Today + DayDetail | Tasks 12, 17 |
| Floating dock hidden when destination pushed | Task 17 (`if path.isEmpty`) |
| Tab state + NavigationPath in RootView | Task 17 |
| `LoadState` enum cases (idle/loading/loaded/failed) | Task 8 |
| Error states: loading / error / empty | Tasks 12, 13 |
| 404-no-targets handled with banner | Task 12 (`errorBody(.notFound)`) |
| Pull-to-refresh on every screen | Tasks 12, 13 (`.refreshable`) |
| Settings auto-present when not configured | Task 17 (auto-present sheet) |
| Settings cannot dismiss until configured | Task 14 (`interactiveDismissDisabled`) |
| URL → UserDefaults, key → Keychain | Tasks 2, 3, 7 |
| `user_key="khash"` hardcoded | Task 2, used in Task 6 |
| Bundle ID `com.khxsh.nutrition` | Task 1 |
| Decoding tests with fixtures | Task 4 |
| SwiftUI Previews on every component | Tasks 11–16 (`#Preview` blocks) |
| 7-day rolling week ending today | Task 10 |
