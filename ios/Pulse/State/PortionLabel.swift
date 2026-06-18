// Pulse/State/PortionLabel.swift
/// Pure derivation of a portion label from a portion's custom-food name and its
/// parent Food name. Strips the Food name (as a whole word, case-insensitively)
/// from the portion name and trims leftover separators; if nothing meaningful
/// remains, falls back to the original portion name. Used to pre-fill the
/// grouping sheet's editable labels.
import Foundation

enum PortionLabel {
    /// Derives a portion label by removing the Food name from the portion name.
    /// Inputs:
    ///   - foodName: the parent Food's display name.
    ///   - portionName: the portion's custom-food name.
    /// Outputs: the stripped, trimmed remainder, or the original `portionName`
    ///   (trimmed) when stripping leaves nothing.
    static func derive(foodName: String, portionName: String) -> String {
        let original = portionName.trimmingCharacters(in: .whitespaces)
        let needle = foodName.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return original }
        // Whole-word, case-insensitive removal of the food name.
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: needle) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return original
        }
        let range = NSRange(original.startIndex..., in: original)
        let stripped = regex.stringByReplacingMatches(in: original, range: range, withTemplate: "")
        let trimmed = stripped.trimmingCharacters(in: CharacterSet(charactersIn: " \t-–—,·"))
        return trimmed.isEmpty ? original : trimmed
    }
}
