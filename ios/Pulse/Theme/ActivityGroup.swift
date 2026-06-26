import SwiftUI

/// The two top-level activity groups. Each Apple `activity_type` is a subtype of one.
enum ActivityGroup: String, CaseIterable, Identifiable, Hashable {
    case weights, cardio

    /// Stable identity for `ForEach`/`Identifiable`; mirrors the raw group name.
    /// - Returns: The enum's raw value ("weights" or "cardio").
    var id: String { rawValue }

    /// Apple activity types that belong to the Weights group (mirrors the server constant).
    static let weightsTypes: Set<String> = ["TraditionalStrengthTraining", "FunctionalStrengthTraining"]

    /// The group an Apple activity type belongs to.
    /// - Parameter activityType: The Apple `activity_type` string.
    /// - Returns: `.weights` when the type is a strength type, otherwise `.cardio`.
    static func of(_ activityType: String) -> ActivityGroup {
        weightsTypes.contains(activityType) ? .weights : .cardio
    }

    /// Human label for the group.
    /// - Returns: The display label ("Weights" or "Cardio").
    var displayName: String {
        switch self {
        case .weights: "Weights"
        case .cardio: "Cardio"
        }
    }

    /// Theme color for the group's dots, chips, and bars.
    /// - Returns: The Catppuccin palette color for this group.
    var color: Color {
        switch self {
        case .weights: Theme.CTP.mauve
        case .cardio: Theme.CTP.teal
        }
    }
}
