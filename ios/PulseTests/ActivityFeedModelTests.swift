import XCTest
@testable import Pulse

final class ActivityFeedModelTests: XCTestCase {
    /// Constructs an `ActivityWorkoutSummary` stub for use in grouping tests.
    /// - Parameters:
    ///   - id: UUID string assigned to the summary.
    ///   - iso: ISO-8601 timestamp string used for both `startTime` and `endTime`.
    ///   - type: activity type string (defaults to `"Running"`).
    /// - Returns: A minimally populated `ActivityWorkoutSummary`.
    private func summary(id: String, _ iso: String, type: String = "Running") -> ActivityWorkoutSummary {
        ActivityWorkoutSummary(
            id: UUID(uuidString: id)!, activityType: type,
            startTime: ISO8601DateFormatter().date(from: iso)!,
            endTime: ISO8601DateFormatter().date(from: iso)!,
            durationMin: 30, activeEnergyCal: 200, distanceKm: nil,
            hasStrengthDetail: false, strengthBrief: nil)
    }

    /// Verifies `groupByWeek(_:calendar:)` assigns workouts to the correct week buckets,
    /// orders weeks newest-first, and sorts workouts newest-first within each bucket.
    func testGroupByWeekOrdersNewestFirstAndSplitsWeeks() {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // Monday, to match server Mon-Sun weeks
        cal.timeZone = TimeZone(identifier: "UTC")!
        let items = [
            summary(id: "11111111-1111-1111-1111-111111111111", "2026-06-24T18:00:00Z"), // Wed wk A
            summary(id: "22222222-2222-2222-2222-222222222222", "2026-06-22T18:00:00Z"), // Mon wk A
            summary(id: "33333333-3333-3333-3333-333333333333", "2026-06-19T18:00:00Z")  // Fri wk B
        ]
        let sections = ActivityFeedModel.groupByWeek(items, calendar: cal)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].workouts.count, 2)            // week A holds two
        XCTAssertEqual(sections[1].workouts.count, 1)            // week B holds one
        XCTAssertEqual(sections[0].workouts.first?.id,
                       UUID(uuidString: "11111111-1111-1111-1111-111111111111"))  // newest first
        XCTAssertTrue(sections[0].weekStart < Date(timeIntervalSince1970: 1_790_000_000))
    }

    /// Verifies `groupByWeek(_:calendar:)` returns an empty array when given no workouts.
    func testGroupByWeekEmpty() {
        XCTAssertTrue(ActivityFeedModel.groupByWeek([], calendar: .current).isEmpty)
    }

    /// Verifies that `groupByWeek` correctly places workouts belonging to three distinct
    /// week buckets and that each section contains the expected workouts.
    func testGroupByWeekThreeDistinctWeeks() {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        cal.timeZone = TimeZone(identifier: "UTC")!
        let items = [
            summary(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", "2026-06-08T10:00:00Z"), // wk C
            summary(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", "2026-06-15T10:00:00Z"), // wk B
            summary(id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", "2026-06-22T10:00:00Z")  // wk A
        ]
        let sections = ActivityFeedModel.groupByWeek(items, calendar: cal)
        XCTAssertEqual(sections.count, 3, "Three separate weeks expected")
        XCTAssertEqual(sections[0].workouts.first?.id,
                       UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"),
                       "Newest week should come first")
    }
}
