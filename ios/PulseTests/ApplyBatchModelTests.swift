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

    /// Selections carry the canonical day key the views use for conflict checks
    /// against `appliedDayKeys`.
    func test_selectionDayKeysMatchCanonicalFormat() {
        let key = DateOnly.string(from: day(1))
        let m = ApplyBatchModel(items: [item(fdc: 1, cal: 500, p: 50, c: 40, f: 10)],
                                portions: 5, appliedDayKeys: [key], auth: nil)
        m.toggle(day(1)); m.toggle(day(2))
        XCTAssertEqual(m.selections[0].dayKey, key)
        XCTAssertTrue(m.appliedDayKeys.contains(m.selections[0].dayKey))
        XCTAssertFalse(m.appliedDayKeys.contains(m.selections[1].dayKey))
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
        XCTAssertEqual(first.consumedAt, DateOnly.noon(on: day(1)))

        // Day 2, custom item at count 2: 2/5 of 500 kcal.
        let last = entries[3]
        XCTAssertEqual(last.customFoodId, customId)
        XCTAssertEqual(last.calories, 200)
        XCTAssertEqual(last.quantityText, "2/5 of prep batch")
    }

    /// Entries applied to a future day are marked pending (`confirmed == false`)
    /// so they stay out of totals until the user confirms them.
    func test_futureDayEntriesArePending() {
        let m = ApplyBatchModel(items: [item(fdc: 1, cal: 500, p: 50, c: 40, f: 10)],
                                portions: 5, appliedDayKeys: [], auth: nil)
        m.toggle(day(1))  // tomorrow
        XCTAssertTrue(m.isPending(m.selections[0]))
        let entries = m.buildEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(entries[0].confirmed)
    }

    /// Entries applied to today (or a past day) are confirmed immediately.
    func test_todayEntriesAreConfirmed() {
        let m = ApplyBatchModel(items: [item(fdc: 1, cal: 500, p: 50, c: 40, f: 10)],
                                portions: 5, appliedDayKeys: [], auth: nil)
        m.toggle(day(0))  // today
        m.toggle(day(-1))  // yesterday
        XCTAssertFalse(m.isPending(m.selections[0]))
        XCTAssertFalse(m.isPending(m.selections[1]))
        XCTAssertTrue(m.buildEntries().allSatisfy(\.confirmed))
    }

    /// The future/confirmed split is computed against the injected `now`, not the
    /// wall clock, so it is deterministic. With `now` pinned to day 0, day 1 is
    /// pending and day 0 is confirmed regardless of when the test runs.
    func test_pendingSplitUsesInjectedNow() {
        let m = ApplyBatchModel(items: [item(fdc: 1, cal: 500, p: 50, c: 40, f: 10)],
                                portions: 5, appliedDayKeys: [], auth: nil,
                                calendar: cal, now: day(0))
        m.toggle(day(0)); m.toggle(day(1))
        XCTAssertFalse(m.isPending(m.selections[0]))
        XCTAssertTrue(m.isPending(m.selections[1]))
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

    // NOTE: A deterministic unit test for the concurrent-submit guard
    // (`guard submitState != .submitting`) is intentionally omitted. The guard
    // fires on `submitState == .submitting`, but `submitState` is `private(set)`
    // and cannot be forced to `.submitting` from outside the model without
    // widening access — which would be wrong just for test convenience. The
    // auth-nil path terminates before `.submitting` is set, so it cannot seed
    // the precondition. The guard is covered by code review and the existing
    // test_submitWithoutAuthFails demonstrates the surrounding submit flow.

    /// isSelected(dayKey:) reflects toggle state by canonical day key; toggle
    /// normalizes any instant on the day to that key.
    func test_isSelectedByDayKey() {
        let m = ApplyBatchModel(items: [item(fdc: 1, cal: 500, p: 50, c: 40, f: 10)],
                                portions: 5, appliedDayKeys: [], auth: nil)
        // Toggle with a non-midnight instant: normalization happens in toggle.
        let lateOnDay1 = cal.date(byAdding: .hour, value: 23, to: day(1))!
        m.toggle(lateOnDay1)
        XCTAssertTrue(m.isSelected(dayKey: DateOnly.string(from: day(1))))
        XCTAssertFalse(m.isSelected(dayKey: DateOnly.string(from: day(2))))
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

    /// dayTotal sums the per-item rounded payload values, never an
    /// aggregate-then-scale: two 1-kcal items over 2 portions submit two
    /// 1-kcal entries (each rounds 0.5 up), so the day total must read 2,
    /// not the 1 an aggregate scale would produce.
    func test_dayTotalMatchesPerItemPayloadRounding() {
        let m = ApplyBatchModel(
            items: [item(fdc: 1, cal: 1, p: 0, c: 0, f: 0),
                    item(fdc: 2, cal: 1, p: 0, c: 0, f: 0)],
            portions: 2, appliedDayKeys: [], auth: nil)
        m.toggle(day(1))
        XCTAssertEqual(m.dayTotal(for: m.selections[0]).calories, 2)
    }

    /// Sourceless items are excluded from applicableItems and dayTotal,
    /// matching the payload (which can never log them).
    func test_dayTotalExcludesSourcelessItems() {
        let m = ApplyBatchModel(
            items: [item(fdc: 1, cal: 500, p: 50, c: 40, f: 10),
                    item(cal: 999, p: 9, c: 9, f: 9)],
            portions: 5, appliedDayKeys: [], auth: nil)
        m.toggle(day(1))
        XCTAssertEqual(m.applicableItems.count, 1)
        XCTAssertEqual(m.dayTotal(for: m.selections[0]),
                       MacroTotals(calories: 100, proteinG: 10, carbsG: 8, fatG: 2))
    }

    /// The Prep per-portion preview (BatchCompositionModel.perPortionTotal) and
    /// the Apply sheet's single-portion dayTotal must agree by construction: both
    /// scale each item individually then sum. Uses three 100-kcal items over 3
    /// portions, where aggregate-then-scale WOULD diverge (99 per-item vs 100
    /// aggregate) — proving the two surfaces show the same number.
    func test_previewMatchesDayTotalForOnePortion() {
        let items = [item(fdc: 1, cal: 100, p: 0, c: 0, f: 0),
                     item(fdc: 2, cal: 100, p: 0, c: 0, f: 0),
                     item(fdc: 3, cal: 100, p: 0, c: 0, f: 0)]
        let batch = BatchCompositionModel(items: items)
        let m = ApplyBatchModel(items: items, portions: 3, appliedDayKeys: [], auth: nil)
        m.toggle(day(1)) // count defaults to 1

        let preview = batch.perPortionTotal(portions: 3)
        let dayTotal = m.dayTotal(for: m.selections[0])
        XCTAssertEqual(preview, dayTotal)
        XCTAssertEqual(preview.calories, 99) // per-item, not the 100 aggregate-scale gives
    }

    /// submit() builds its payload from contributions() — the same builder these
    /// tests exercise — so contributions() flattened equals buildEntries(),
    /// proving the tested path is the production path.
    func test_contributionsAreTheSubmitPayload() {
        let m = ApplyBatchModel(
            items: [item(fdc: 11, cal: 1000, p: 100, c: 50, f: 20),
                    item(fdc: 12, cal: 500, p: 10, c: 80, f: 5)],
            portions: 5, appliedDayKeys: [], auth: nil)
        m.toggle(day(1)); m.toggle(day(2))
        m.setCount(2, forDay: m.selections[1].dayKey)

        let contributions = m.contributions()
        // Day keys are the selections, in order.
        XCTAssertEqual(contributions.map(\.dayKey), m.selections.map(\.dayKey))
        // Flattening contributions reproduces buildEntries exactly (same path).
        let flat = contributions.flatMap(\.entries)
        let built = m.buildEntries()
        XCTAssertEqual(flat.count, built.count)
        XCTAssertEqual(flat.map(\.calories), built.map(\.calories))
        // The applied-day-keys submit returns are exactly the non-empty
        // contributions' keys.
        let appliedKeys = Set(contributions.filter { !$0.entries.isEmpty }.map(\.dayKey))
        XCTAssertEqual(appliedKeys, Set(m.selections.map(\.dayKey)))
    }
}
