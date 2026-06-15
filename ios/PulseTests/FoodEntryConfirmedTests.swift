// PulseTests/FoodEntryConfirmedTests.swift
import XCTest
@testable import Pulse

/// Tests that `FoodEntry` decodes the `confirmed` flag, defaulting it to `true`
/// when the key is absent (so payloads predating the pending concept still read
/// as normal counted entries).
final class FoodEntryConfirmedTests: XCTestCase {
    /// Builds the JSON for one entry, optionally including a `confirmed` value.
    /// - Parameter confirmed: when non-nil, emits `"confirmed": <value>`.
    /// - Returns: encoded JSON bytes for a single `FoodEntry`.
    private func entryJSON(confirmed: Bool?) -> Data {
        let confirmedLine = confirmed.map { ",\n\"confirmed\": \($0)" } ?? ""
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "daily_log_id": "22222222-2222-2222-2222-222222222222",
          "user_key": "khash",
          "entry_group_id": "33333333-3333-3333-3333-333333333333",
          "display_name": "Prep bowl",
          "quantity_text": "1 portion",
          "normalized_quantity_value": null,
          "normalized_quantity_unit": null,
          "usda_fdc_id": 123,
          "usda_description": "Bowl",
          "custom_food_id": null,
          "calories": 600,
          "protein_g": 50,
          "carbs_g": 40,
          "fat_g": 20,
          "meal_id": null,
          "meal_name": null,
          "consumed_at": "2026-06-20",
          "created_at": "2026-06-20"\(confirmedLine)
        }
        """
        return Data(json.utf8)
    }

    func test_decodesConfirmedFalse() throws {
        let entry = try JSONDecoder.pulseDefault().decode(FoodEntry.self, from: entryJSON(confirmed: false))
        XCTAssertFalse(entry.isConfirmed)
    }

    func test_decodesConfirmedTrue() throws {
        let entry = try JSONDecoder.pulseDefault().decode(FoodEntry.self, from: entryJSON(confirmed: true))
        XCTAssertTrue(entry.isConfirmed)
    }

    func test_defaultsToConfirmedWhenKeyAbsent() throws {
        let entry = try JSONDecoder.pulseDefault().decode(FoodEntry.self, from: entryJSON(confirmed: nil))
        XCTAssertTrue(entry.isConfirmed)
    }
}
