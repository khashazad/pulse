// PulseTests/ApplyBatchModelTests.swift
import XCTest
@testable import Pulse

/// Tests for `ApplyBatchModel`: day selection, allocation/conflict accounting,
/// and `FoodEntryCreate` payload building for apply-to-days.
final class ApplyBatchModelTests: XCTestCase {
    private let cal = Calendar.current

    /// Builds a batch item with the given source ids and frozen macros.
    /// Inputs:
    ///   - fdc: USDA id, nil for custom-food items.
    ///   - custom: custom food id, nil for USDA items.
    ///   - cal/p/c/f: frozen macro totals.
    /// Outputs: a `BatchFoodItem`.
    private func item(fdc: Int? = nil, custom: UUID? = nil,
                      cal: Int, p: Double, c: Double, f: Double) -> BatchFoodItem {
        BatchFoodItem(
            id: UUID(), displayName: "Food", usdaFdcId: fdc,
            usdaDescription: fdc.map { _ in "USDA Food" }, customFoodId: custom,
            nutrition: FoodNutrition(basis: .per100g, servingSize: nil, servingSizeUnit: nil,
                                     caloriesPerBasis: cal, proteinGPerBasis: p,
                                     carbsGPerBasis: c, fatGPerBasis: f),
            quantity: .typed(value: 100, unit: .grams), containerId: nil,
            macros: MacroTotals(calories: cal, proteinG: p, carbsG: c, fatG: f))
    }

    /// A date at midnight `offset` days from today.
    private func day(_ offset: Int) -> Date {
        cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date()))!
    }

    /// Toggling adds a selection at count 1, keeps selections date-sorted, and
    /// toggling again removes it.
    func test_toggleAddsSortedAndRemoves() {
        let m = ApplyBatchModel(items: [item(fdc: 1, cal: 500, p: 50, c: 40, f: 10)],
                                portions: 5, appliedDayKeys: [], auth: nil)
        m.toggle(day(3)); m.toggle(day(1))
        XCTAssertEqual(m.selections.map(\.count), [1, 1])
        XCTAssertLessThan(m.selections[0].date, m.selections[1].date)
        m.toggle(day(3))
        XCTAssertEqual(m.selections.count, 1)
    }

    /// Allocation sums per-day counts; over-allocation flips past `portions`.
    func test_allocationAccounting() {
        let m = ApplyBatchModel(items: [item(fdc: 1, cal: 500, p: 50, c: 40, f: 10)],
                                portions: 2, appliedDayKeys: [], auth: nil)
        m.toggle(day(1)); m.toggle(day(2))
        XCTAssertEqual(m.allocatedPortions, 2)
        XCTAssertFalse(m.isOverAllocated)
        m.setCount(2, forDay: m.selections[0].dayKey)
        XCTAssertEqual(m.allocatedPortions, 3)
        XCTAssertTrue(m.isOverAllocated)
    }

    /// Selected days already in `appliedDayKeys` are reported as conflicts.
    func test_conflictDetection() {
        let key = DateOnly.formatter.string(from: day(1))
        let m = ApplyBatchModel(items: [item(fdc: 1, cal: 500, p: 50, c: 40, f: 10)],
                                portions: 5, appliedDayKeys: [key], auth: nil)
        m.toggle(day(1)); m.toggle(day(2))
        XCTAssertEqual(m.conflictedDayKeys, [key])
    }

    /// buildEntries emits one entry per (selected day x batch item), scaled by
    /// count/portions, with consumedAt at noon local on the target day and the
    /// correct food source per item.
    func test_buildEntriesShape() {
        let customId = UUID()
        let m = ApplyBatchModel(
            items: [item(fdc: 11, cal: 1000, p: 100, c: 50, f: 20),
                    item(custom: customId, cal: 500, p: 10, c: 80, f: 5)],
            portions: 5, appliedDayKeys: [], auth: nil)
        m.toggle(day(1)); m.toggle(day(2))
        m.setCount(2, forDay: m.selections[1].dayKey)

        let entries = m.buildEntries()
        XCTAssertEqual(entries.count, 4) // 2 days x 2 items

        // Day 1, USDA item: 1/5 of 1000 kcal.
        let first = entries[0]
        XCTAssertEqual(first.usdaFdcId, 11)
        XCTAssertEqual(first.calories, 200)
        XCTAssertEqual(first.proteinG, 20)
        XCTAssertEqual(first.quantityText, "1/5 of prep batch")
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: day(1))!
        XCTAssertEqual(first.consumedAt, noon)

        // Day 2, custom item at count 2: 2/5 of 500 kcal.
        let last = entries[3]
        XCTAssertEqual(last.customFoodId, customId)
        XCTAssertEqual(last.calories, 200)
        XCTAssertEqual(last.quantityText, "2/5 of prep batch")
    }

    /// Items with neither food source are skipped, never sent.
    func test_buildEntriesSkipsSourcelessItems() {
        let m = ApplyBatchModel(items: [item(cal: 100, p: 1, c: 1, f: 1)],
                                portions: 2, appliedDayKeys: [], auth: nil)
        m.toggle(day(1))
        XCTAssertTrue(m.buildEntries().isEmpty)
    }

    /// Submitting signed-out fails with .notSignedIn and returns nil.
    func test_submitWithoutAuthFails() async {
        let m = ApplyBatchModel(items: [item(fdc: 1, cal: 100, p: 1, c: 1, f: 1)],
                                portions: 2, appliedDayKeys: [], auth: nil)
        m.toggle(day(1))
        let applied = await m.submit()
        XCTAssertNil(applied)
        XCTAssertEqual(m.submitState, .failed(.notSignedIn))
    }

    /// isSelected matches any instant on a selected day and stays false otherwise.
    func test_isSelectedNormalizesToDay() {
        let m = ApplyBatchModel(items: [item(fdc: 1, cal: 500, p: 50, c: 40, f: 10)],
                                portions: 5, appliedDayKeys: [], auth: nil)
        m.toggle(day(1))
        let lateOnDay1 = cal.date(byAdding: .hour, value: 23, to: day(1))!
        XCTAssertTrue(m.isSelected(lateOnDay1))
        XCTAssertFalse(m.isSelected(day(2)))
    }

    /// dayTotal sums all items' macros and scales them by count/portions.
    func test_dayTotalScalesBatchTotal() {
        let m = ApplyBatchModel(
            items: [item(fdc: 11, cal: 1000, p: 100, c: 50, f: 20),
                    item(fdc: 12, cal: 500, p: 10, c: 80, f: 5)],
            portions: 5, appliedDayKeys: [], auth: nil)
        m.toggle(day(1))
        m.setCount(2, forDay: m.selections[0].dayKey)
        XCTAssertEqual(m.dayTotal(for: m.selections[0]),
                       MacroTotals(calories: 600, proteinG: 44, carbsG: 52, fatG: 10))
    }
}
