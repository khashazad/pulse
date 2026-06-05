/// Unit tests for `clusterByProximity`.
/// Verifies that chronologically-ordered day rows split into time-proximity
/// clusters: rows within the gap threshold stay together, a larger gap starts a
/// new cluster, the threshold boundary is inclusive, meal groups cluster as a
/// single unit, and degenerate inputs (empty, single) behave.
/// Part of the iOS app's view-model test suite.
import XCTest
@testable import Pulse

final class DayProximityClusteringTests: XCTestCase {

    // MARK: - helpers

    /// Builds a `FoodEntry` with sensible defaults for clustering tests.
    /// Inputs:
    ///   - groupId: string UUID for the `entryGroupId`.
    ///   - name: display name for the entry.
    ///   - mealId: optional string UUID of the originating meal.
    ///   - mealName: optional display name for the meal.
    ///   - consumedAt: timestamp used for sort/representative time.
    /// Outputs: a fully formed `FoodEntry`.
    private func entry(
        groupId: String,
        name: String = "item",
        mealId: String? = nil,
        mealName: String? = nil,
        consumedAt: Date
    ) -> FoodEntry {
        FoodEntry(
            id: UUID(),
            dailyLogId: UUID(),
            userKey: "khash",
            entryGroupId: UUID(uuidString: groupId)!,
            displayName: name,
            quantityText: "x",
            normalizedQuantityValue: nil,
            normalizedQuantityUnit: nil,
            usdaFdcId: 1,
            usdaDescription: "x",
            customFoodId: nil,
            calories: 100,
            proteinG: 5,
            carbsG: 10,
            fatG: 2,
            mealId: mealId.flatMap(UUID.init(uuidString:)),
            mealName: mealName,
            consumedAt: consumedAt,
            createdAt: consumedAt
        )
    }

    /// Builds a fixed-day `Date` (2026-05-06) at the requested hour/minute.
    /// Inputs:
    ///   - hour: hour-of-day in 24-hour form.
    ///   - minute: minute-of-hour (defaults to 0).
    /// Outputs: the corresponding `Date` in the gregorian calendar.
    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 6
        comps.hour = hour; comps.minute = minute
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    /// Convenience: produces a `.single` `DayRow` at a given time.
    /// Inputs:
    ///   - i: disambiguates the entry's group id.
    ///   - at: the entry's `consumedAt`.
    /// Outputs: a single-entry `DayRow`.
    private func single(_ i: Int, at: Date) -> DayRow {
        .single(entry(groupId: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", i))", name: "item", consumedAt: at))
    }

    private let mealA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

    // MARK: - tests

    /// Verifies an empty input yields no clusters.
    func testEmptyInputYieldsNoClusters() {
        XCTAssertTrue(clusterByProximity([]).isEmpty)
    }

    /// Verifies a single row yields one cluster containing that row.
    func testSingleRowYieldsOneCluster() {
        let rows = [single(1, at: date(8))]
        let clusters = clusterByProximity(rows)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].rows.count, 1)
    }

    /// Verifies rows closer together than the gap collapse into one cluster.
    func testRowsWithinGapStayInOneCluster() {
        let rows = [
            single(1, at: date(8, 0)),
            single(2, at: date(8, 10)),
            single(3, at: date(8, 30))
        ]
        let clusters = clusterByProximity(rows)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].rows.count, 3)
    }

    /// Verifies a gap larger than the threshold starts a new cluster.
    func testGapLargerThanThresholdSplitsClusters() {
        let rows = [
            single(1, at: date(8, 0)),
            single(2, at: date(8, 5)),
            single(3, at: date(13, 0))  // hours later → new occasion
        ]
        let clusters = clusterByProximity(rows)
        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(clusters[0].rows.count, 2)
        XCTAssertEqual(clusters[1].rows.count, 1)
    }

    /// Verifies the threshold is inclusive: a gap exactly equal to `gap` does not
    /// split, while one second more does.
    func testThresholdBoundaryIsInclusive() {
        let exact = [
            single(1, at: date(8, 0)),
            single(2, at: date(8, 0).addingTimeInterval(DayProximity.gap))
        ]
        XCTAssertEqual(clusterByProximity(exact).count, 1)

        let justOver = [
            single(1, at: date(8, 0)),
            single(2, at: date(8, 0).addingTimeInterval(DayProximity.gap + 1))
        ]
        XCTAssertEqual(clusterByProximity(justOver).count, 2)
    }

    /// Verifies gaps are measured between consecutive rows, so a slow drip of
    /// entries each within the gap of the prior one stays a single cluster even
    /// when the span exceeds the gap.
    func testConsecutiveDripStaysOneCluster() {
        let rows = (0..<5).map { single($0, at: date(8, $0 * 40)) }  // 40-min steps < 45-min gap
        let clusters = clusterByProximity(rows)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].rows.count, 5)
    }

    /// Verifies a meal group clusters as a single unit alongside nearby singles,
    /// and a far single forms its own cluster.
    func testMealGroupClustersAsOneUnit() {
        let g = "33333333-3333-3333-3333-333333333333"
        let entries = [
            entry(groupId: "11111111-1111-1111-1111-111111111111", name: "Coffee", consumedAt: date(8, 0)),
            entry(groupId: g, name: "Oats", mealId: mealA, mealName: "Breakfast", consumedAt: date(8, 10)),
            entry(groupId: g, name: "Yogurt", mealId: mealA, mealName: "Breakfast", consumedAt: date(8, 10)),
            entry(groupId: "22222222-2222-2222-2222-222222222222", name: "Apple", consumedAt: date(15, 0))
        ]
        let rows = groupDayEntries(entries)
        let clusters = clusterByProximity(rows)
        XCTAssertEqual(clusters.count, 2)
        // First cluster: coffee single + breakfast meal group = 2 rows.
        XCTAssertEqual(clusters[0].rows.count, 2)
        guard case .single = clusters[0].rows[0], case .meal = clusters[0].rows[1] else {
            return XCTFail("expected a single then a meal in the morning cluster")
        }
        // Second cluster: the lone afternoon apple.
        XCTAssertEqual(clusters[1].rows.count, 1)
    }

    /// Verifies each cluster's id is stable and derived from its first row.
    func testClusterIdComesFromFirstRow() {
        let rows = [single(1, at: date(8)), single(2, at: date(13))]
        let clusters = clusterByProximity(rows)
        XCTAssertEqual(clusters[0].id, clusters[0].rows[0].id)
        XCTAssertEqual(clusters[1].id, clusters[1].rows[0].id)
    }
}
