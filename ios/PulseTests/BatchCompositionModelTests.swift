// PulseTests/BatchCompositionModelTests.swift
import XCTest
@testable import Pulse

/// Tests for the in-app batch: add/remove/replace items and sum macros.
final class BatchCompositionModelTests: XCTestCase {
    private func item(_ cal: Int, _ p: Double, _ c: Double, _ f: Double) -> BatchFoodItem {
        BatchFoodItem(
            id: UUID(), displayName: "X", usdaFdcId: nil, usdaDescription: nil, customFoodId: nil,
            nutrition: FoodNutrition(basis: .per100g, servingSize: nil, servingSizeUnit: nil,
                                     caloriesPerBasis: cal, proteinGPerBasis: p, carbsGPerBasis: c, fatGPerBasis: f),
            quantity: .typed(value: 100, unit: .grams), containerId: nil,
            macros: MacroTotals(calories: cal, proteinG: p, carbsG: c, fatG: f))
    }

    func test_addAndTotal() {
        let m = BatchCompositionModel()
        m.add(item(200, 20, 10, 8))
        m.add(item(100, 5, 12, 3))
        XCTAssertEqual(m.items.count, 2)
        XCTAssertEqual(m.total, MacroTotals(calories: 300, proteinG: 25, carbsG: 22, fatG: 11))
    }

    func test_removeById() {
        let m = BatchCompositionModel()
        let a = item(200, 20, 10, 8)
        m.add(a); m.add(item(100, 5, 12, 3))
        m.remove(id: a.id)
        XCTAssertEqual(m.items.count, 1)
        XCTAssertEqual(m.total.calories, 100)
    }

    func test_replacePreservesPosition() {
        let m = BatchCompositionModel()
        let a = item(200, 20, 10, 8); let b = item(100, 5, 12, 3)
        m.add(a); m.add(b)
        let edited = BatchFoodItem(id: a.id, displayName: "X", usdaFdcId: nil, usdaDescription: nil,
            customFoodId: nil, nutrition: a.nutrition, quantity: a.quantity, containerId: nil,
            macros: MacroTotals(calories: 50, proteinG: 1, carbsG: 1, fatG: 1))
        m.replace(edited)
        XCTAssertEqual(m.items.first?.id, a.id)
        XCTAssertEqual(m.total.calories, 150)
    }

    func test_emptyTotalIsZero() {
        XCTAssertEqual(BatchCompositionModel().total, MacroTotals(calories: 0, proteinG: 0, carbsG: 0, fatG: 0))
    }

    /// Builds a source-bearing item (usable by perPortionTotal, which filters on
    /// `hasSource`) with the given frozen macros.
    private func sourcedItem(_ cal: Int, _ p: Double, _ c: Double, _ f: Double) -> BatchFoodItem {
        BatchFoodItem(
            id: UUID(), displayName: "X", usdaFdcId: 1, usdaDescription: "USDA", customFoodId: nil,
            nutrition: FoodNutrition(basis: .per100g, servingSize: nil, servingSizeUnit: nil,
                                     caloriesPerBasis: cal, proteinGPerBasis: p, carbsGPerBasis: c, fatGPerBasis: f),
            quantity: .typed(value: 100, unit: .grams), containerId: nil,
            macros: MacroTotals(calories: cal, proteinG: p, carbsG: c, fatG: f))
    }

    /// perPortionTotal scales each item individually then sums, which can differ
    /// from aggregate-then-scale: three 100-kcal items over 3 portions yield
    /// 1 + 1 + 1 = 3 single-portion entries (each rounds 100/3 = 33.33 → 33),
    /// summing to 99, NOT the 100 that scaling the 300-kcal aggregate produces.
    func test_perPortionTotalScalesPerItem() {
        let m = BatchCompositionModel()
        m.add(sourcedItem(100, 0, 0, 0))
        m.add(sourcedItem(100, 0, 0, 0))
        m.add(sourcedItem(100, 0, 0, 0))
        XCTAssertEqual(m.perPortionTotal(portions: 3).calories, 99)
        // Aggregate-then-scale would diverge — proving the helper is needed.
        XCTAssertEqual(m.total.scaled(count: 1, portions: 3).calories, 100)
    }

    /// perPortionTotal only counts source-bearing items, matching the apply
    /// payload (sourceless items can never be logged).
    func test_perPortionTotalExcludesSourcelessItems() {
        let m = BatchCompositionModel()
        m.add(sourcedItem(300, 30, 0, 0))
        m.add(item(999, 99, 0, 0)) // sourceless (item() builds usdaFdcId == nil)
        XCTAssertEqual(m.perPortionTotal(portions: 3).calories, 100)
    }
}
