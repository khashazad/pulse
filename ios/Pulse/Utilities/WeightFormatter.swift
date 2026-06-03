/// Weight unit conversion and display formatting.
/// Provides kg<->lb conversion constants and helpers, plus a one-decimal
/// display string. Used wherever the UI shows weight values stored
/// canonically in pounds.
import Foundation

/// Namespace for weight unit conversion and display.
enum WeightFormatter {
    static let kgToLb: Double = 2.20462262

    /// Converts a value in the given unit to pounds.
    /// Inputs:
    ///   - value: numeric weight in `unit`.
    ///   - unit: source unit (`.lb` or `.kg`).
    /// Outputs: equivalent weight in pounds.
    static func toLb(_ value: Double, from unit: WeightUnit) -> Double {
        switch unit {
        case .lb: return value
        case .kg: return value * kgToLb
        }
    }

    /// Converts a pound value into the target unit.
    /// Inputs:
    ///   - lb: weight in pounds.
    ///   - unit: target unit (`.lb` or `.kg`).
    /// Outputs: equivalent weight in `unit`.
    static func fromLb(_ lb: Double, to unit: WeightUnit) -> Double {
        switch unit {
        case .lb: return lb
        case .kg: return lb / kgToLb
        }
    }

    /// Formats a pound value for display in the given unit, with one decimal
    /// place and the unit raw value appended.
    /// Inputs:
    ///   - lb: weight in pounds.
    ///   - unit: unit to render in.
    /// Outputs: e.g. `"180.4 lb"` or `"81.8 kg"`.
    static func display(lb: Double, in unit: WeightUnit) -> String {
        let value = fromLb(lb, to: unit)
        return String(format: "%.1f %@", value, unit.rawValue)
    }
}
