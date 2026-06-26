import XCTest
@testable import Pulse

final class ActivityModelTests: XCTestCase {
    /// Loads a JSON fixture from the test bundle by name.
    /// Inputs:
    ///   - name: fixture file base name (without extension).
    /// Outputs: raw `Data` bytes of the fixture file.
    /// Exceptions: throws via `XCTUnwrap` if the fixture is not found, or if reading the file fails.
    private func loadFixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    /// Verifies `WorkoutFeedPage` decodes correctly from the `activity_feed_page` fixture, including cursor fields, strength brief, and distance.
    func testDecodeFeedPage() throws {
        let page = try JSONDecoder.pulseDefault().decode(WorkoutFeedPage.self, from: loadFixture("activity_feed_page"))
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.items[0].activityType, "TraditionalStrengthTraining")
        XCTAssertTrue(page.items[0].hasStrengthDetail)
        XCTAssertEqual(page.items[0].strengthBrief?.setCount, 16)
        XCTAssertNil(page.items[1].strengthBrief)
        XCTAssertEqual(page.items[1].distanceKm, 5.1)
        XCTAssertEqual(page.nextBefore, "2026-06-23T12:00:00+00:00")
        XCTAssertEqual(page.nextBeforeId, "aaaaaaaa-0000-0000-0000-000000000002")
    }

    /// Verifies `ActivityWorkoutDetail` decodes correctly from the `activity_workout_detail` fixture, including heart rate, exercises, sets, top set, and strength totals.
    func testDecodeWorkoutDetail() throws {
        let d = try JSONDecoder.pulseDefault().decode(ActivityWorkoutDetail.self, from: loadFixture("activity_workout_detail"))
        XCTAssertEqual(d.avgHeartRate, 121.0)
        XCTAssertEqual(d.exercises.count, 1)
        XCTAssertEqual(d.exercises[0].sets.count, 2)
        XCTAssertEqual(d.exercises[0].topSet?.weightLbs, 145.0)
        XCTAssertEqual(d.exercises[0].sets[0].setType, "warmup")
        XCTAssertEqual(d.strengthTotals?.volumeLbs, 1950.0)
    }

    /// Verifies `ActivitySummary` decodes correctly from the `activity_summary` fixture,
    /// including totals, deltas, by-type breakdown, months, volume series, and top lifts.
    func testDecodeSummary() throws {
        let s = try JSONDecoder.pulseDefault().decode(ActivitySummary.self, from: loadFixture("activity_summary"))
        XCTAssertEqual(s.totals.workoutCount, 48)
        XCTAssertEqual(s.deltas.workoutCount.pct, 0.1429)
        XCTAssertNil(s.deltas.totalActiveEnergyCal.pct)
        // by_type — both strength types collapsed server-side into "Weights"
        XCTAssertEqual(s.byType.count, 2)
        XCTAssertEqual(s.byType.first?.activityType, "Weights")
        XCTAssertEqual(s.byType.first?.count, 34)
        // months populated for year period; weeks empty
        XCTAssertEqual(s.months.count, 2)
        XCTAssertEqual(s.months.first?.sessionCount, 8)
        XCTAssertTrue(s.weeks.isEmpty)
        XCTAssertEqual(s.volumeSeries.count, 2)
        XCTAssertEqual(s.topLifts[0].bestReps, 6)
        XCTAssertTrue(s.topLifts[0].isPr)
    }

    /// Verifies `WeekDetail` decodes correctly from the `week_detail` fixture,
    /// including `weekStart`, `weekEnd`, and the nested day groups with workouts.
    func testDecodeWeekDetail() throws {
        let wd = try JSONDecoder.pulseDefault().decode(WeekDetail.self, from: loadFixture("week_detail"))
        XCTAssertEqual(wd.dayGroups.count, 2)
        XCTAssertEqual(wd.dayGroups.first?.workouts.count, 1)
        XCTAssertEqual(wd.dayGroups.first?.workouts.first?.activityType, "TraditionalStrengthTraining")
        XCTAssertEqual(wd.dayGroups[1].workouts.first?.distanceKm, 5.1)
    }

    /// Verifies `ActivityTypesResponse` decodes from the `activity_types` fixture,
    /// mapping `activity_type`, `display_name`, `count`, and `is_cardio` correctly,
    /// and that `id` equals `activityType` for each entry.
    func testDecodeActivityTypes() throws {
        let response = try JSONDecoder.pulseDefault().decode(
            ActivityTypesResponse.self,
            from: loadFixture("activity_types")
        )
        XCTAssertEqual(response.types.count, 2)

        let running = response.types[0]
        XCTAssertEqual(running.activityType, "Running")
        XCTAssertEqual(running.displayName, "Running")
        XCTAssertEqual(running.count, 12)
        XCTAssertTrue(running.isCardio)
        XCTAssertEqual(running.id, running.activityType)

        let strength = response.types[1]
        XCTAssertEqual(strength.activityType, "TraditionalStrengthTraining")
        XCTAssertEqual(strength.displayName, "Traditional Strength Training")
        XCTAssertEqual(strength.count, 34)
        XCTAssertFalse(strength.isCardio)
        XCTAssertEqual(strength.id, strength.activityType)
    }
}
