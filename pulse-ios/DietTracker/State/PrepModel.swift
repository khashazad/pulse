/// PrepModel: state for the meal-prep portion calculator screen.
/// Tracks selected container, total weight, and portion count; derives tare,
/// net, and per-portion grams.
/// Role: backing view-model for the Prep screen.
import Foundation
import Observation

/// Observable view-model that computes net and per-portion weights for the meal-prep screen.
@Observable
final class PrepModel {
    /// Source of truth for both UI ("which container is selected") and math
    /// ("what tare to subtract"). Storing the whole `Container` (vs. just an
    /// id + a separate tare field) makes drift impossible: if selection is
    /// nil, tare is 0; if selection is set, tare is the container's own.
    var selectedContainer: Container?
    var totalGrams: Double?
    var portions: Int = 1

    var tareWeightG: Double { selectedContainer?.tareWeightG ?? 0 }

    var netGrams: Double? {
        guard let total = totalGrams else { return nil }
        return max(0, total - tareWeightG)
    }

    var perPortionGrams: Double? {
        guard let net = netGrams else { return nil }
        let p = max(1, portions)
        return net / Double(p)
    }
}
