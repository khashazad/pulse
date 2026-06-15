// PulseTests/PendingProjectionTests.swift
import XCTest
@testable import Pulse

/// Tests the day-view pending-projection math: summing pending entries' macros
/// (`sumMacroTotals`) and projecting confirmed totals forward by them
/// (`projectedTotals`), including the "no pending → no projection" case.
final class PendingProjectionTests: XCTestCase {
    /// Builds a `FoodEntry` carrying only the macros that matter to the math.
    /// - Parameters mirror the macro fields; everything else gets a fixed stub.
    /// - Returns: a `FoodEntry` with the requested macros (and `isConfirmed`).
    private func entry(calories: Int, protein: Double, carbs: Double, fat: Double, confirmed: Bool = false) -> FoodEntry {
        FoodEntry(
            id: UUID(),
            dailyLogId: UUID(),
            userKey: "khash",
            entryGroupId: UUID(),
            displayName: "X",
            quantityText: "1",
            normalizedQuantityValue: nil,
            normalizedQuantityUnit: nil,
            usdaFdcId: nil,
            usdaDescription: nil,
            customFoodId: nil,
            calories: calories,
            proteinG: protein,
            carbsG: carbs,
            fatG: fat,
            mealId: nil,
            mealName: nil,
            consumedAt: Date(timeIntervalSince1970: 0),
            createdAt: Date(timeIntervalSince1970: 0),
            isConfirmed: confirmed
        )
    }

    func test_sumMacroTotals_addsEachChannel() {
        let total = sumMacroTotals([
            entry(calories: 600, protein: 50, carbs: 40, fat: 20),
            entry(calories: 200, protein: 10, carbs: 15, fat: 5)
        ])
        XCTAssertEqual(total.calories, 800)
        XCTAssertEqual(total.proteinG, 60, accuracy: 0.0001)
        XCTAssertEqual(total.carbsG, 55, accuracy: 0.0001)
        XCTAssertEqual(total.fatG, 25, accuracy: 0.0001)
    }

    func test_sumMacroTotals_emptyIsZero() {
        let total = sumMacroTotals([])
        XCTAssertEqual(total.calories, 0)
        XCTAssertEqual(total.proteinG, 0)
        XCTAssertEqual(total.carbsG, 0)
        XCTAssertEqual(total.fatG, 0)
    }

    func test_projectedTotals_addsPendingOntoConsumed() throws {
        let consumed = MacroTotals(calories: 1240, proteinG: 92, carbsG: 138, fatG: 42)
        let projected = try XCTUnwrap(projectedTotals(
            consumed: consumed,
            pending: [entry(calories: 600, protein: 50, carbs: 40, fat: 20)]
        ))
        XCTAssertEqual(projected.calories, 1840)
        XCTAssertEqual(projected.proteinG, 142, accuracy: 0.0001)
        XCTAssertEqual(projected.carbsG, 178, accuracy: 0.0001)
        XCTAssertEqual(projected.fatG, 62, accuracy: 0.0001)
    }

    func test_projectedTotals_nilWhenNoPending() {
        let consumed = MacroTotals(calories: 1240, proteinG: 92, carbsG: 138, fatG: 42)
        XCTAssertNil(projectedTotals(consumed: consumed, pending: []))
    }
}
