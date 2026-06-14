/// Average-macro helpers over a collection of `DailyLog`s.
/// Each average skips days with no entries so empty days don't drag the mean down.
/// Used by the period intake views (week/month/year) to feed `AverageMacrosTable`.
import Foundation

extension Array where Element == DailyLog {
    /// Average kcal per logged day (skips days with 0 entries).
    /// Outputs: mean calories across days that had at least one entry (0 when none).
    var avgCalories: Int {
        let logged = filter { $0.entryCount > 0 }
        guard !logged.isEmpty else { return 0 }
        return logged.map(\.totalCalories).reduce(0, +) / logged.count
    }

    /// Average protein grams per logged day (skips days with 0 entries).
    /// Outputs: mean protein grams across days that had at least one entry (0 when none).
    var avgProtein: Double {
        let logged = filter { $0.entryCount > 0 }
        guard !logged.isEmpty else { return 0 }
        return logged.map(\.totalProteinG).reduce(0, +) / Double(logged.count)
    }

    /// Average carbohydrate grams per logged day (skips days with 0 entries).
    /// Outputs: mean carb grams across days that had at least one entry (0 when none).
    var avgCarbs: Double {
        let logged = filter { $0.entryCount > 0 }
        guard !logged.isEmpty else { return 0 }
        return logged.map(\.totalCarbsG).reduce(0, +) / Double(logged.count)
    }

    /// Average fat grams per logged day (skips days with 0 entries).
    /// Outputs: mean fat grams across days that had at least one entry (0 when none).
    var avgFat: Double {
        let logged = filter { $0.entryCount > 0 }
        guard !logged.isEmpty else { return 0 }
        return logged.map(\.totalFatG).reduce(0, +) / Double(logged.count)
    }

    /// Y-axis ceiling for a kcal bar chart: the larger of the peak day and an
    /// optional target, floored at 1 so the vertical scale is always positive.
    /// Inputs:
    ///   - target: optional daily kcal target the chart also marks.
    /// Outputs: a positive ceiling used as the chart's vertical scale.
    func calorieCeiling(target: Int?) -> Int {
        Swift.max(map(\.totalCalories).max() ?? 0, target ?? 0, 1)
    }
}
