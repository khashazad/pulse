/// Shared helpers for user-editable numeric text fields.
/// Centralizes the comma-tolerant decimal parse and the bare ("%g") number
/// format used by gram/tare inputs, so every entry surface (Settings macro
/// targets, weight entry, container tare) parses and renders identically.
import Foundation

/// Namespace for parsing and formatting numeric text-field input.
enum NumericInput {
    /// Parses a decimal string, accepting comma decimal separators.
    /// Inputs:
    ///   - s: raw user input.
    /// Outputs: the parsed value, or nil when unparseable.
    static func parseDecimal(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: "."))
    }

    /// Formats a value without trailing zeros (150.0 -> "150", 62.5 -> "62.5").
    /// Inputs:
    ///   - value: number to render into an editable field.
    /// Outputs: display string ("%g", six significant figures).
    static func formatBare(_ value: Double) -> String {
        String(format: "%g", value)
    }
}
