import SwiftUI

/// Maps Apple `activity_type` raw strings to a display color and friendly name.
enum ActivityType {
    /// Theme color for a workout type's feed dot, bars, and chart fills.
    /// - Parameter raw: The Apple `activity_type` string.
    /// - Returns: A `Theme.CTP` color; mauve for strength, teal for run/cardio, sky default.
    static func color(_ raw: String) -> Color {
        let k = raw.lowercased()
        if k.contains("strength") { return Theme.CTP.mauve }
        if k.contains("run") { return Theme.CTP.teal }
        if k.contains("cycling") || k.contains("bike") { return Theme.CTP.sky }
        if k.contains("walk") || k.contains("hiking") { return Theme.CTP.green }
        if k.contains("swim") { return Theme.CTP.sapphire }
        if k.contains("yoga") || k.contains("flexibility") { return Theme.CTP.flamingo }
        if k.contains("hiit") || k.contains("functional") { return Theme.CTP.peach }
        if k == "other" { return Theme.CTP.overlay1 }
        return Theme.CTP.lavender
    }

    /// Friendly display name for a workout type (camel-cased Apple identifiers → words).
    /// - Parameter raw: The Apple `activity_type` string.
    /// - Returns: A spaced, human-readable label.
    static func displayName(_ raw: String) -> String {
        switch raw {
        case "TraditionalStrengthTraining": return "Strength"
        case "FunctionalStrengthTraining": return "Functional Strength"
        case "HighIntensityIntervalTraining": return "HIIT"
        default:
            // Insert spaces before capitals: "OutdoorRun" -> "Outdoor Run".
            var s = ""
            for (i, ch) in raw.enumerated() {
                if i > 0 && ch.isUppercase { s.append(" ") }
                s.append(ch)
            }
            return s
        }
    }
}
