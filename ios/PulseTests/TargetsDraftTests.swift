/// Unit tests for `TargetsDraft`: seeding, dirty detection (including the
/// unit-toggle-stays-clean and clear-weight-goes-dirty cases), validation
/// bounds, the computed-kcal indicator, and `toMacroTargets()` round-trips.
/// Pure value-type tests — no networking, no UI.
import XCTest
@testable import Pulse

final class TargetsDraftTests: XCTestCase {
    private let baseline = MacroTargets(
        calories: 2000, proteinG: 150, carbsG: 200, fatG: 60, targetWeightLb: 175)

    /// Builds a draft seeded from `baseline` in the given unit.
    /// Inputs:
    ///   - unit: weight-entry unit to seed with (default `.lb`).
    /// Outputs: a seeded `TargetsDraft`.
    private func seeded(unit: WeightUnit = .lb) -> TargetsDraft {
        var d = TargetsDraft()
        d.seed(from: baseline, unit: unit)
        return d
    }

    // MARK: - seeding

    /// Verifies seeding fills all five inputs from the baseline and is clean.
    func test_seed_fillsInputsAndIsClean() {
        let d = seeded()
        XCTAssertEqual(d.caloriesInput, "2000")
        XCTAssertEqual(d.proteinInput, "150")
        XCTAssertEqual(d.carbsInput, "200")
        XCTAssertEqual(d.fatInput, "60")
        XCTAssertEqual(d.weightInput, "175.0")
        XCTAssertFalse(d.isDirty)
        XCTAssertTrue(d.isValid)
    }

    /// Verifies seeding from nil (404 / no profile) leaves all inputs empty,
    /// clean, and invalid (macros are required to create a profile).
    func test_seed_fromNilIsEmptyCleanInvalid() {
        var d = TargetsDraft()
        d.seed(from: nil, unit: .lb)
        XCTAssertEqual(d.caloriesInput, "")
        XCTAssertEqual(d.weightInput, "")
        XCTAssertFalse(d.isDirty)
        XCTAssertFalse(d.isValid)
    }

    /// Verifies a nil target weight seeds an empty weight field and stays clean.
    func test_seed_nilWeightIsEmptyAndClean() {
        var d = TargetsDraft()
        d.seed(from: MacroTargets(calories: 2000, proteinG: 150, carbsG: 200,
                                  fatG: 60, targetWeightLb: nil), unit: .lb)
        XCTAssertEqual(d.weightInput, "")
        XCTAssertFalse(d.isDirty)
        XCTAssertTrue(d.isValid)
    }

    /// Verifies fractional grams seed without trailing zeros.
    func test_seed_formatsFractionalGrams() {
        var d = TargetsDraft()
        d.seed(from: MacroTargets(calories: 2000, proteinG: 162.5, carbsG: 200,
                                  fatG: 60, targetWeightLb: nil), unit: .lb)
        XCTAssertEqual(d.proteinInput, "162.5")
    }

    // MARK: - dirty detection

    /// Verifies editing one macro marks the draft and that field dirty.
    func test_editProtein_marksDirty() {
        var d = seeded()
        d.proteinInput = "190"
        XCTAssertTrue(d.isDirty)
        XCTAssertTrue(d.isMacroDirty)
        XCTAssertTrue(d.isProteinEdited)
        XCTAssertFalse(d.isCaloriesEdited)
        XCTAssertFalse(d.isWeightEdited)
    }

    /// Verifies toggling the weight unit (lb -> kg -> lb) never marks dirty,
    /// including values like 176.0 whose naive parse/format round-trip drifts
    /// by 0.1 lb (the unedited field must regenerate from the baseline).
    func test_unitToggle_staysClean() {
        for lb in [150.0, 160.0, 175.0, 176.0, 203.3] {
            var d = TargetsDraft()
            d.seed(from: MacroTargets(calories: 2000, proteinG: 150, carbsG: 200,
                                      fatG: 60, targetWeightLb: lb), unit: .lb)
            d.setUnit(.kg)
            XCTAssertFalse(d.isDirty, "lb->kg toggle dirtied \(lb)")
            d.setUnit(.lb)
            XCTAssertFalse(d.isDirty, "kg->lb round-trip dirtied \(lb)")
            XCTAssertEqual(d.weightInput, String(format: "%.1f", lb),
                           "round-trip must restore the seeded display value")
        }
    }

    /// Verifies an edited weight field converts the user's value on toggle
    /// (rather than regenerating from baseline) and stays dirty.
    func test_unitToggle_editedWeightConvertsAndStaysDirty() {
        var d = seeded(unit: .lb) // baseline weight 175.0
        d.weightInput = "180.0"
        d.setUnit(.kg)
        XCTAssertTrue(d.isDirty)
        XCTAssertEqual(d.weightInput, String(format: "%.1f", 180.0 / WeightFormatter.kgToLb))
    }

    /// Verifies editing the weight after a unit toggle is detected as dirty.
    func test_weightEditInKg_marksDirty() {
        var d = seeded(unit: .lb)
        d.setUnit(.kg)
        d.weightInput = "70.0"
        XCTAssertTrue(d.isWeightEdited)
        XCTAssertTrue(d.isDirty)
    }

    /// Verifies clearing the weight field is a deliberate edit (dirty) and
    /// maps to a nil target weight in the DTO.
    func test_clearWeight_isDirtyAndMapsToNil() {
        var d = seeded()
        d.weightInput = ""
        XCTAssertTrue(d.isDirty)
        XCTAssertTrue(d.isValid)
        XCTAssertNil(d.toMacroTargets()?.targetWeightLb)
    }

    /// Verifies any input on a nil baseline reads as dirty.
    func test_nilBaseline_anyInputIsDirty() {
        var d = TargetsDraft()
        d.seed(from: nil, unit: .lb)
        d.caloriesInput = "1800"
        XCTAssertTrue(d.isDirty)
    }

    // MARK: - validation

    /// Verifies the calories bounds: 1..<20000.
    func test_caloriesBounds() {
        var d = seeded()
        d.caloriesInput = "0"
        XCTAssertFalse(d.isValid)
        d.caloriesInput = "19999"
        XCTAssertTrue(d.isValid)
        d.caloriesInput = "20000"
        XCTAssertFalse(d.isValid)
        d.caloriesInput = "abc"
        XCTAssertFalse(d.isValid)
    }

    /// Verifies the macro grams bounds: 0..<2000, comma decimals accepted.
    func test_macroBounds_andCommaDecimal() {
        var d = seeded()
        d.fatInput = "0"
        XCTAssertTrue(d.isValid)
        d.fatInput = "2000"
        XCTAssertFalse(d.isValid)
        d.fatInput = "-1"
        XCTAssertFalse(d.isValid)
        d.fatInput = "62,5"
        XCTAssertTrue(d.isValid)
        XCTAssertEqual(d.toMacroTargets()?.fatG, 62.5)
    }

    /// Verifies the weight bounds in the entered unit: empty OR 0 < v < 2000.
    func test_weightBounds() {
        var d = seeded()
        d.weightInput = "0"
        XCTAssertFalse(d.isValid)
        d.weightInput = "1999.9"
        XCTAssertTrue(d.isValid)
        d.weightInput = "2000"
        XCTAssertFalse(d.isValid)
        d.weightInput = ""
        XCTAssertTrue(d.isValid)
    }

    // MARK: - computed kcal

    /// Verifies the indicator math: 4*P + 4*C + 9*F, rounded.
    func test_computedCalories() {
        var d = seeded()
        d.proteinInput = "190"
        d.carbsInput = "210"
        // 4*190 + 4*210 + 9*60 = 760 + 840 + 540 = 2140
        XCTAssertEqual(d.computedCalories, 2140)
    }

    // MARK: - toMacroTargets

    /// Verifies a clean kg-seeded draft preserves the exact baseline weight
    /// (no lb->kg->lb rounding drift on save).
    func test_toMacroTargets_uneditedWeightKeepsBaselineVerbatim() {
        var d = TargetsDraft()
        let odd = MacroTargets(calories: 2000, proteinG: 150, carbsG: 200,
                               fatG: 60, targetWeightLb: 170.25)
        d.seed(from: odd, unit: .kg)
        d.caloriesInput = "1900" // dirty the draft without touching weight
        XCTAssertEqual(d.toMacroTargets()?.targetWeightLb, 170.25)
    }

    /// Verifies an edited weight is converted from the entered unit to lb.
    func test_toMacroTargets_editedKgWeightConvertsToLb() {
        var d = seeded(unit: .lb)
        d.setUnit(.kg)
        d.weightInput = "80"
        let lb = d.toMacroTargets()?.targetWeightLb
        XCTAssertEqual(lb ?? 0, 80 * WeightFormatter.kgToLb, accuracy: 0.001)
    }

    /// Verifies `toMacroTargets()` is nil while invalid.
    func test_toMacroTargets_nilWhenInvalid() {
        var d = seeded()
        d.caloriesInput = ""
        XCTAssertNil(d.toMacroTargets())
    }

    // MARK: - precision / parsing edge cases

    /// Verifies a high-precision server value (truncated by "%g"'s six
    /// significant figures when seeding) does not read as dirty untouched,
    /// and is written back verbatim rather than at display precision.
    func test_seed_highPrecisionGramsStaysCleanAndSavesVerbatim() {
        var d = TargetsDraft()
        let precise = MacroTargets(calories: 2000, proteinG: 1234.567, carbsG: 200,
                                   fatG: 60, targetWeightLb: nil)
        d.seed(from: precise, unit: .lb)
        XCTAssertFalse(d.isDirty, "%g truncation of 1234.567 must not read as an edit")
        d.caloriesInput = "1900" // dirty the draft without touching protein
        XCTAssertEqual(d.toMacroTargets()?.proteinG, 1234.567,
                       "unedited macro must pass the baseline through verbatim")
    }

    /// Verifies calories accepts integral decimals but rejects fractional
    /// values and thousands separators (which must not mis-parse as 1.8).
    func test_parsedCalories_decimalTolerance() {
        var d = seeded()
        d.caloriesInput = "1800.0"
        XCTAssertTrue(d.isValid)
        XCTAssertEqual(d.toMacroTargets()?.calories, 1800)
        d.caloriesInput = "1800.5"
        XCTAssertFalse(d.isValid)
        d.caloriesInput = "1,800"
        XCTAssertFalse(d.isValid, "thousands separator must read invalid, not as 1.8")
    }

    // MARK: - merging

    /// Verifies unedited fields take their values from the freshly fetched
    /// server profile, so saving doesn't clobber concurrent changes.
    func test_toMacroTargets_mergingPrefersFreshForUneditedFields() {
        var d = seeded() // baseline 2000 / 150 / 200 / 60 / 175
        d.proteinInput = "190" // only protein edited
        let fresh = MacroTargets(calories: 1800, proteinG: 120, carbsG: 210,
                                 fatG: 65, targetWeightLb: 168)
        let merged = d.toMacroTargets(merging: fresh)
        XCTAssertEqual(merged?.calories, 1800, "unedited calories take the fresh value")
        XCTAssertEqual(merged?.proteinG, 190, "edited protein keeps the draft value")
        XCTAssertEqual(merged?.carbsG, 210)
        XCTAssertEqual(merged?.fatG, 65)
        XCTAssertEqual(merged?.targetWeightLb, 168, "unedited weight takes the fresh value")
    }

    /// Verifies an edited field (including a deliberate weight clear) beats
    /// the freshly fetched value.
    func test_toMacroTargets_mergingEditedFieldsWin() {
        var d = seeded()
        d.weightInput = "" // deliberate clear (edited)
        let fresh = MacroTargets(calories: 2000, proteinG: 150, carbsG: 200,
                                 fatG: 60, targetWeightLb: 168)
        XCTAssertNil(d.toMacroTargets(merging: fresh)?.targetWeightLb,
                     "cleared weight must override the fresh server value")
    }
}
