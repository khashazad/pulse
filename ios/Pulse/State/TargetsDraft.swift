/// TargetsDraft: pending-edit state for the Settings sheet's server-backed
/// target fields (macro targets + weight goal). A plain value type held as a
/// single `@State` by `SettingsView` — owns parsing, validation, dirty
/// detection against a seeded baseline, the computed-kcal indicator, and
/// conversion back to the `MacroTargets` wire DTO. No Observation/networking.
import Foundation

/// Draft of the user's editable targets while the Settings sheet is open.
struct TargetsDraft: Equatable {
    var caloriesInput: String = ""
    var proteinInput: String = ""
    var carbsInput: String = ""
    var fatInput: String = ""
    var weightInput: String = ""
    private(set) var weightUnit: WeightUnit = .lb
    private(set) var baseline: MacroTargets?

    /// Exclusive upper bound for a valid calories target.
    static let caloriesLimit = 20_000
    /// Exclusive upper bound for a valid macro grams value.
    static let macroGramsLimit = 2_000.0

    // MARK: - seeding / unit

    /// Resets the draft to mirror the given baseline (or empty for nil) and
    /// records it for dirty comparison.
    /// Inputs:
    ///   - targets: server truth to seed from; nil when no profile exists.
    ///   - unit: unit to render the weight input in.
    /// Outputs: nothing.
    mutating func seed(from targets: MacroTargets?, unit: WeightUnit) {
        baseline = targets
        weightUnit = unit
        guard let t = targets else {
            caloriesInput = ""
            proteinInput = ""
            carbsInput = ""
            fatInput = ""
            weightInput = ""
            return
        }
        caloriesInput = String(t.calories)
        proteinInput = NumericInput.formatBare(t.proteinG)
        carbsInput = NumericInput.formatBare(t.carbsG)
        fatInput = NumericInput.formatBare(t.fatG)
        weightInput = t.targetWeightLb
            .map { WeightFormatter.entryString(WeightFormatter.fromLb($0, to: unit)) } ?? ""
    }

    /// Switches the weight-entry unit, converting the current input in place.
    /// An unedited field is regenerated from the baseline value (same format
    /// path as seeding), so a pure toggle never reads as dirty regardless of
    /// rounding; an edited field converts the user's entered value.
    /// Inputs:
    ///   - newUnit: unit to convert the weight input into.
    /// Outputs: nothing.
    mutating func setUnit(_ newUnit: WeightUnit) {
        guard newUnit != weightUnit else { return }
        if !isWeightEdited, let baseLb = baseline?.targetWeightLb {
            weightInput = WeightFormatter.entryString(WeightFormatter.fromLb(baseLb, to: newUnit))
        } else if let v = NumericInput.parseDecimal(weightInput) {
            let lb = WeightFormatter.toLb(v, from: weightUnit)
            weightInput = WeightFormatter.entryString(WeightFormatter.fromLb(lb, to: newUnit))
        }
        weightUnit = newUnit
    }

    // MARK: - parsed values

    /// Parsed calories input, or nil when unparseable. Accepts plain integers
    /// and integral decimals ("1800.0" -> 1800); fractional values and
    /// thousands separators stay nil so they read as invalid rather than
    /// silently mis-parsing.
    var parsedCalories: Int? {
        let trimmed = caloriesInput.trimmingCharacters(in: .whitespaces)
        if let whole = Int(trimmed) { return whole }
        guard let value = Double(trimmed), value == value.rounded(),
              let whole = Int(exactly: value) else { return nil }
        return whole
    }

    /// Parsed protein grams, or nil when unparseable.
    var parsedProtein: Double? { NumericInput.parseDecimal(proteinInput) }
    /// Parsed carbs grams, or nil when unparseable.
    var parsedCarbs: Double? { NumericInput.parseDecimal(carbsInput) }
    /// Parsed fat grams, or nil when unparseable.
    var parsedFat: Double? { NumericInput.parseDecimal(fatInput) }

    // MARK: - validity

    /// Whether the calories input parses inside 1..<20000.
    var isCaloriesFieldValid: Bool {
        parsedCalories.map { (1..<Self.caloriesLimit).contains($0) } ?? false
    }

    /// Whether the protein input parses inside 0..<2000.
    var isProteinFieldValid: Bool { Self.gramsValid(parsedProtein) }
    /// Whether the carbs input parses inside 0..<2000.
    var isCarbsFieldValid: Bool { Self.gramsValid(parsedCarbs) }
    /// Whether the fat input parses inside 0..<2000.
    var isFatFieldValid: Bool { Self.gramsValid(parsedFat) }

    /// Whether the weight input is empty (no goal) or parses with
    /// 0 < v < WeightFormatter.entryLimit in the entered unit.
    var isWeightFieldValid: Bool {
        if weightInput.isEmpty { return true }
        guard let w = NumericInput.parseDecimal(weightInput) else { return false }
        return w > 0 && w < WeightFormatter.entryLimit
    }

    /// Whether every field is individually valid (see the per-field flags).
    var isValid: Bool {
        isCaloriesFieldValid && isProteinFieldValid && isCarbsFieldValid
            && isFatFieldValid && isWeightFieldValid
    }

    // MARK: - dirty detection

    /// Whether the calories input differs from the baseline.
    var isCaloriesEdited: Bool { parsedCalories != baseline?.calories }
    /// Whether the protein input differs from the baseline.
    var isProteinEdited: Bool { Self.gramsEdited(proteinInput, baseline: baseline?.proteinG) }
    /// Whether the carbs input differs from the baseline.
    var isCarbsEdited: Bool { Self.gramsEdited(carbsInput, baseline: baseline?.carbsG) }
    /// Whether the fat input differs from the baseline.
    var isFatEdited: Bool { Self.gramsEdited(fatInput, baseline: baseline?.fatG) }

    /// Whether the weight input differs from the baseline rendered in the
    /// current unit at one decimal — so unit-toggle rewrites stay clean.
    var isWeightEdited: Bool {
        let base = baseline?.targetWeightLb
            .map { Self.round1(WeightFormatter.fromLb($0, to: weightUnit)) }
        let current = NumericInput.parseDecimal(weightInput).map(Self.round1)
        return current != base
    }

    /// Whether any of the four macro fields differs from the baseline.
    var isMacroDirty: Bool {
        isCaloriesEdited || isProteinEdited || isCarbsEdited || isFatEdited
    }

    /// Whether anything server-backed differs from the baseline.
    var isDirty: Bool { isMacroDirty || isWeightEdited }

    // MARK: - derived

    /// Calories implied by the macro inputs (4*P + 4*C + 9*F), rounded.
    /// Unparseable fields contribute 0.
    var computedCalories: Int {
        let p = parsedProtein ?? 0
        let c = parsedCarbs ?? 0
        let f = parsedFat ?? 0
        return Int((4 * p + 4 * c + 9 * f).rounded())
    }

    /// Builds the wire DTO from the draft.
    /// Inputs:
    ///   - fresh: latest server truth fetched just before saving, or nil.
    ///     Unedited fields take their values from it (falling back to the
    ///     baseline) so a save can't clobber concurrent changes to fields the
    ///     user never touched.
    /// Outputs: a `MacroTargets` ready to PUT, or nil while the draft is
    /// invalid. An edited-empty weight field maps to nil (deliberate clear);
    /// an unedited field passes the reference value through verbatim, so no
    /// format/parse round-trip drift is ever written back.
    func toMacroTargets(merging fresh: MacroTargets? = nil) -> MacroTargets? {
        guard isValid,
              let cal = parsedCalories,
              let p = parsedProtein,
              let c = parsedCarbs,
              let f = parsedFat else { return nil }
        let reference = fresh ?? baseline
        let weightLb: Double?
        if isWeightEdited {
            weightLb = weightInput.isEmpty
                ? nil
                : NumericInput.parseDecimal(weightInput)
                    .map { WeightFormatter.toLb($0, from: weightUnit) }
        } else {
            weightLb = reference?.targetWeightLb
        }
        return MacroTargets(
            calories: isCaloriesEdited ? cal : (reference?.calories ?? cal),
            proteinG: isProteinEdited ? p : (reference?.proteinG ?? p),
            carbsG: isCarbsEdited ? c : (reference?.carbsG ?? c),
            fatG: isFatEdited ? f : (reference?.fatG ?? f),
            targetWeightLb: weightLb)
    }

    // MARK: - helpers

    /// Whether a grams value parses inside 0..<macroGramsLimit.
    /// Inputs:
    ///   - value: parsed grams, or nil when unparseable.
    /// Outputs: true when present and in bounds.
    private static func gramsValid(_ value: Double?) -> Bool {
        guard let g = value else { return false }
        return g >= 0 && g < Self.macroGramsLimit
    }

    /// Whether a grams input differs from its baseline. The baseline is
    /// compared through the same format/parse round-trip used by seeding, so
    /// a high-precision server value (truncated by "%g"'s six significant
    /// figures) never reads as dirty on an untouched field.
    /// Inputs:
    ///   - input: raw field text.
    ///   - baseline: server truth for the field, or nil.
    /// Outputs: true when the input no longer matches the seeded baseline.
    private static func gramsEdited(_ input: String, baseline: Double?) -> Bool {
        let seeded = baseline.map { NumericInput.parseDecimal(NumericInput.formatBare($0)) ?? $0 }
        return !nearlyEqual(NumericInput.parseDecimal(input), seeded)
    }

    /// Rounds to one decimal place.
    /// Inputs:
    ///   - value: value to round.
    /// Outputs: value rounded to 0.1.
    private static func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    /// Compares two optional doubles with a small epsilon; nil == nil.
    /// Inputs:
    ///   - a: first value.
    ///   - b: second value.
    /// Outputs: true when both nil or both within 0.001.
    private static func nearlyEqual(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x - y) < 0.001
        default: return false
        }
    }
}
