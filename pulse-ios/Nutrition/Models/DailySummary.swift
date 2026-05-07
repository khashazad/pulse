import Foundation

struct DailySummary: Codable, Equatable {
    let date: Date              // YYYY-MM-DD
    let target: MacroTargets
    let consumed: MacroTotals
    let remaining: MacroTotals
    let entries: [FoodEntry]
}
