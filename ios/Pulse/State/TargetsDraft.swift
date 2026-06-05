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
    /// Exclusive upper bound for a valid weight in the entered unit.
    static let weightLimit = 2_000.0

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
        proteinInput = Self.formatGrams(t.proteinG)
        carbsInput = Self.formatGrams(t.carbsG)
        fatInput = Self.formatGrams(t.fatG)
        weightInput = t.targetWeightLb
            .map { Self.formatWeight(WeightFormatter.fromLb($0, to: unit)) } ?? ""
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
            weightInput = Self.formatWeight(WeightFormatter.fromLb(baseLb, to: newUnit))
        } else if let v = Self.parse(weightInput) {
            let lb = WeightFormatter.toLb(v, from: weightUnit)
            weightInput = Self.formatWeight(WeightFormatter.fromLb(lb, to: newUnit))
        }
        weightUnit = newUnit
    }

    // MARK: - parsed values

    /// Parsed calories input, or nil when unparseable.
    var parsedCalories: Int? { Int(caloriesInput.trimmingCharacters(in: .whitespaces)) }
    /// Parsed protein grams, or nil when unparseable.
    var parsedProtein: Double? { Self.parse(proteinInput) }
    /// Parsed carbs grams, or nil when unparseable.
    var parsedCarbs: Double? { Self.parse(carbsInput) }
    /// Parsed fat grams, or nil when unparseable.
    var parsedFat: Double? { Self.parse(fatInput) }

    // MARK: - validity

    /// Whether every field parses inside its bounds: calories 1..<20000,
    /// macros 0..<2000, weight empty or 0 < v < 2000 (entered unit).
    var isValid: Bool {
        guard let cal = parsedCalories, (1..<Self.caloriesLimit).contains(cal) else { return false }
        for grams in [parsedProtein, parsedCarbs, parsedFat] {
            guard let g = grams, g >= 0, g < Self.macroGramsLimit else { return false }
        }
        if weightInput.isEmpty { return true }
        guard let w = Self.parse(weightInput) else { return false }
        return w > 0 && w < Self.weightLimit
    }

    // MARK: - dirty detection

    /// Whether the calories input differs from the baseline.
    var isCaloriesEdited: Bool { parsedCalories != baseline?.calories }
    /// Whether the protein input differs from the baseline.
    var isProteinEdited: Bool { !Self.nearlyEqual(parsedProtein, baseline?.proteinG) }
    /// Whether the carbs input differs from the baseline.
    var isCarbsEdited: Bool { !Self.nearlyEqual(parsedCarbs, baseline?.carbsG) }
    /// Whether the fat input differs from the baseline.
    var isFatEdited: Bool { !Self.nearlyEqual(parsedFat, baseline?.fatG) }

    /// Whether the weight input differs from the baseline rendered in the
    /// current unit at one decimal — so unit-toggle rewrites stay clean.
    var isWeightEdited: Bool {
        let base = baseline?.targetWeightLb
            .map { Self.round1(WeightFormatter.fromLb($0, to: weightUnit)) }
        let current = Self.parse(weightInput).map(Self.round1)
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
    /// Outputs: a `MacroTargets` ready to PUT, or nil while the draft is
    /// invalid. An empty weight field maps to a nil target weight; an
    /// unedited weight reuses the baseline value verbatim to avoid unit
    /// round-trip drift.
    func toMacroTargets() -> MacroTargets? {
        guard isValid,
              let cal = parsedCalories,
              let p = parsedProtein,
              let c = parsedCarbs,
              let f = parsedFat else { return nil }
        let weightLb: Double?
        if weightInput.isEmpty {
            weightLb = nil
        } else if !isWeightEdited, let base = baseline?.targetWeightLb {
            weightLb = base
        } else {
            weightLb = Self.parse(weightInput)
                .map { WeightFormatter.toLb($0, from: weightUnit) }
        }
        return MacroTargets(calories: cal, proteinG: p, carbsG: c, fatG: f,
                            targetWeightLb: weightLb)
    }

    // MARK: - helpers

    /// Parses a decimal string, accepting comma decimal separators.
    /// Inputs:
    ///   - s: raw user input.
    /// Outputs: the parsed value, or nil.
    private static func parse(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: "."))
    }

    /// Formats grams without trailing zeros (150.0 -> "150", 62.5 -> "62.5").
    /// Inputs:
    ///   - value: grams value.
    /// Outputs: display string.
    private static func formatGrams(_ value: Double) -> String {
        String(format: "%g", value)
    }

    /// Formats a weight at one decimal place, matching the seeding/toggle path.
    /// Inputs:
    ///   - value: weight in the current entry unit.
    /// Outputs: display string, e.g. "175.0".
    private static func formatWeight(_ value: Double) -> String {
        String(format: "%.1f", value)
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
