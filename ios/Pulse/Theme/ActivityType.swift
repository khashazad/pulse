import SwiftUI

/// Maps Apple `activity_type` raw strings to a display color and friendly name.
enum ActivityType {
    /// Theme color for a workout type's feed dot, bars, and chart fills.
    /// - Parameter raw: The Apple `activity_type` string.
    /// - Returns: A `Theme.CTP` color; mauve for strength, peach for HIIT, sky default.
    static func color(_ raw: String) -> Color {
        // Known Apple HealthKit identifiers mapped explicitly (mirrors displayName's spine).
        // These camel-cased names contain no lowercase substring like "hiit", so the
        // substring fallback below would mis-bucket them — match them by exact name first.
        switch raw {
        case "TraditionalStrengthTraining", "FunctionalStrengthTraining": return Theme.CTP.mauve
        case "HighIntensityIntervalTraining": return Theme.CTP.peach
        case "Other": return Theme.CTP.overlay1
        default: break
        }
        // Substring fallback for the long tail of less common types, first match wins.
        let k = raw.lowercased()
        let spine: [(needles: [String], color: Color)] = [
            (["strength"], Theme.CTP.mauve),
            (["run"], Theme.CTP.teal),
            (["cycling", "bike"], Theme.CTP.sky),
            (["walk", "hiking"], Theme.CTP.green),
            (["swim"], Theme.CTP.sapphire),
            (["yoga", "flexibility"], Theme.CTP.flamingo),
            (["hiit", "functional"], Theme.CTP.peach)
        ]
        for entry in spine where entry.needles.contains(where: k.contains) {
            return entry.color
        }
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
