/// Wire model bundling a single day's targets, consumed totals, remaining
/// macros, and the underlying food entries.
/// Returned by the day-summary endpoint and rendered on the home/today screen.
import Foundation

/// One day's targets, consumed/remaining macros, and the list of food entries.
struct DailySummary: Codable, Equatable {
    let date: Date              // YYYY-MM-DD
    let target: MacroTargets
    let consumed: MacroTotals
    let remaining: MacroTotals
    let entries: [FoodEntry]
}
