/// View model for a single calorie-history time bucket (e.g. a week or month).
/// Carries a label, average kcal/day for the bucket, and a flag marking the
/// current (in-progress) period. Used by trend/period summary views.
import Foundation

/// One row in a periodized calorie summary (week/month/etc.).
struct PeriodBucket: Identifiable, Hashable {
    let id: String
    let label: String
    let avgKcalPerDay: Int
    let isCurrent: Bool
    /// Aggregate protein/carbs/fat shares for the bucket, for its stacked-macro bar
    /// fill (nil when the bucket has no logged macros).
    let macroFractions: MacroFractions?
}
