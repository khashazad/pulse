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

    /// Verifies `ActivitySummary` decodes correctly from the `activity_summary` fixture, including totals, deltas, by-type breakdown, volume series, and top lifts.
    func testDecodeSummary() throws {
        let s = try JSONDecoder.pulseDefault().decode(ActivitySummary.self, from: loadFixture("activity_summary"))
        XCTAssertEqual(s.totals.workoutCount, 4)
        XCTAssertEqual(s.deltas.workoutCount.pct, 0.3333)
        XCTAssertNil(s.deltas.totalActiveEnergyCal.pct)
        XCTAssertEqual(s.byType.count, 2)
        XCTAssertEqual(s.volumeSeries.count, 2)
        XCTAssertEqual(s.topLifts[0].bestReps, 6)
        XCTAssertTrue(s.topLifts[0].isPr)
    }
}
