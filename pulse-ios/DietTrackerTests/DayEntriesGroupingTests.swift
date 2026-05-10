import XCTest
@testable import DietTracker

final class DayEntriesGroupingTests: XCTestCase {

    // MARK: - helpers

    private func entry(
        id: String = UUID().uuidString,
        groupId: String,
        name: String = "item",
        kcal: Int = 100,
        proteinG: Double = 5,
        carbsG: Double = 10,
        fatG: Double = 2,
        mealId: String? = nil,
        mealName: String? = nil,
        consumedAt: Date
    ) -> FoodEntry {
        FoodEntry(
            id: UUID(uuidString: id)!,
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
            calories: kcal,
            proteinG: proteinG,
            carbsG: carbsG,
            fatG: fatG,
            mealId: mealId.flatMap(UUID.init(uuidString:)),
            mealName: mealName,
            consumedAt: consumedAt,
            createdAt: consumedAt
        )
    }

    private func date(_ hour: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 6
        comps.hour = hour; comps.minute = 0
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    private let mealA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let mealB = "cccccccc-cccc-cccc-cccc-cccccccccccc"

    // MARK: - tests

    func testAllSinglesPassThroughInOrder() {
        let entries = [
            entry(groupId: "11111111-1111-1111-1111-111111111111", name: "A", consumedAt: date(8)),
            entry(groupId: "22222222-2222-2222-2222-222222222222", name: "B", consumedAt: date(13)),
        ]
        let rows = groupDayEntries(entries)
        XCTAssertEqual(rows.count, 2)
        guard case .single(let a) = rows[0], case .single(let b) = rows[1] else {
            return XCTFail("expected two singles")
        }
        XCTAssertEqual(a.displayName, "A")
        XCTAssertEqual(b.displayName, "B")
    }

    func testSingleMealGroupOfThreeCollapsesAndUsesItsItems() {
        let g = "33333333-3333-3333-3333-333333333333"
        let entries = [
            entry(groupId: g, name: "Oats", kcal: 320, mealId: mealA, mealName: "Breakfast", consumedAt: date(8)),
            entry(groupId: g, name: "Yogurt", kcal: 130, mealId: mealA, mealName: "Breakfast", consumedAt: date(8)),
            entry(groupId: g, name: "Berries", kcal: 60, mealId: mealA, mealName: "Breakfast", consumedAt: date(8)),
        ]
        let rows = groupDayEntries(entries)
        XCTAssertEqual(rows.count, 1)
        guard case .meal(let group) = rows[0] else { return XCTFail("expected meal") }
        XCTAssertEqual(group.count, 1)
        XCTAssertEqual(group.displayName, "Breakfast")
        XCTAssertEqual(group.items.map { $0.displayName }, ["Oats", "Yogurt", "Berries"])
        XCTAssertEqual(group.totals.calories, 510)
    }

    func testSameMealIdRepeatedTwiceMergesWithCountTwoAndSummedTotals() {
        let g1 = "44444444-4444-4444-4444-444444444444"
        let g2 = "55555555-5555-5555-5555-555555555555"
        let entries = [
            entry(groupId: g1, name: "Oats", kcal: 320, mealId: mealA, mealName: "Breakfast", consumedAt: date(8)),
            entry(groupId: g1, name: "Yogurt", kcal: 130, mealId: mealA, mealName: "Breakfast", consumedAt: date(8)),
            entry(groupId: g2, name: "Oats", kcal: 320, mealId: mealA, mealName: "Breakfast", consumedAt: date(13)),
            entry(groupId: g2, name: "Yogurt", kcal: 130, mealId: mealA, mealName: "Breakfast", consumedAt: date(13)),
        ]
        let rows = groupDayEntries(entries)
        XCTAssertEqual(rows.count, 1)
        guard case .meal(let group) = rows[0] else { return XCTFail("expected meal") }
        XCTAssertEqual(group.count, 2)
        XCTAssertEqual(group.totals.calories, 900)
        XCTAssertEqual(group.sortDate, date(13))
    }

    func testMostRecentInstanceItemsWinWhenTemplateChanged() {
        let g1 = "66666666-6666-6666-6666-666666666666"
        let g2 = "77777777-7777-7777-7777-777777777777"
        let entries = [
            entry(groupId: g1, name: "Oats v1", mealId: mealA, mealName: "Breakfast", consumedAt: date(8)),
            entry(groupId: g1, name: "Yogurt v1", mealId: mealA, mealName: "Breakfast", consumedAt: date(8)),
            entry(groupId: g2, name: "Oats v2", mealId: mealA, mealName: "Breakfast", consumedAt: date(13)),
            entry(groupId: g2, name: "Yogurt v2", mealId: mealA, mealName: "Breakfast", consumedAt: date(13)),
            entry(groupId: g2, name: "Berries v2", mealId: mealA, mealName: "Breakfast", consumedAt: date(13)),
        ]
        let rows = groupDayEntries(entries)
        guard case .meal(let group) = rows[0] else { return XCTFail("expected meal") }
        XCTAssertEqual(group.count, 2)
        XCTAssertEqual(group.items.map { $0.displayName }, ["Oats v2", "Yogurt v2", "Berries v2"])
    }

    func testNilMealIdMultiItemGroupsStaySeparateAndUseFallbackName() {
        let g1 = "88888888-8888-8888-8888-888888888888"
        let g2 = "99999999-9999-9999-9999-999999999999"
        let entries = [
            entry(groupId: g1, name: "X", consumedAt: date(8)),
            entry(groupId: g1, name: "Y", consumedAt: date(8)),
            entry(groupId: g2, name: "X", consumedAt: date(13)),
            entry(groupId: g2, name: "Y", consumedAt: date(13)),
        ]
        let rows = groupDayEntries(entries)
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            guard case .meal(let group) = row else { return XCTFail("expected meal") }
            XCTAssertEqual(group.count, 1)
            XCTAssertEqual(group.displayName, "Meal")
            XCTAssertNil(group.mealId)
        }
    }

    func testMixedSinglesAndMealsAreSortedByRepresentativeTime() {
        let coffeeGroup = "11111111-1111-1111-1111-111111111111"
        let breakfastGroup = "aaaaaaaa-1aaa-1aaa-1aaa-aaaaaaaaaaaa"
        let appleGroup = "22222222-2222-2222-2222-222222222222"
        let entries = [
            entry(groupId: coffeeGroup, name: "Coffee", consumedAt: date(7)),
            entry(groupId: breakfastGroup, name: "Oats", mealId: mealA, mealName: "Breakfast", consumedAt: date(8)),
            entry(groupId: breakfastGroup, name: "Yogurt", mealId: mealA, mealName: "Breakfast", consumedAt: date(8)),
            entry(groupId: appleGroup, name: "Apple", consumedAt: date(15)),
        ]
        let rows = groupDayEntries(entries)
        XCTAssertEqual(rows.count, 3)
        guard case .single(let coffee) = rows[0],
              case .meal(let breakfast) = rows[1],
              case .single(let apple) = rows[2] else {
            return XCTFail("expected single, meal, single")
        }
        XCTAssertEqual(coffee.displayName, "Coffee")
        XCTAssertEqual(breakfast.displayName, "Breakfast")
        XCTAssertEqual(apple.displayName, "Apple")
    }

    func testDifferentMealIdsAreNotMerged() {
        let g1 = "bbbbbbbb-1bbb-1bbb-1bbb-bbbbbbbbbbbb"
        let g2 = "bbbbbbbb-2bbb-2bbb-2bbb-bbbbbbbbbbbb"
        let entries = [
            entry(groupId: g1, name: "Oats", mealId: mealA, mealName: "Breakfast", consumedAt: date(8)),
            entry(groupId: g1, name: "Yogurt", mealId: mealA, mealName: "Breakfast", consumedAt: date(8)),
            entry(groupId: g2, name: "Rice", mealId: mealB, mealName: "Lunch", consumedAt: date(13)),
            entry(groupId: g2, name: "Beans", mealId: mealB, mealName: "Lunch", consumedAt: date(13)),
        ]
        let rows = groupDayEntries(entries)
        XCTAssertEqual(rows.count, 2)
        guard case .meal(let breakfast) = rows[0], case .meal(let lunch) = rows[1] else {
            return XCTFail("expected two meals")
        }
        XCTAssertEqual(breakfast.displayName, "Breakfast")
        XCTAssertEqual(lunch.displayName, "Lunch")
    }
}
