/// Average-macro helpers over a collection of `DailyLog`s.
/// Each average counts only days that had at least one entry AND aren't flagged
/// `excluded`, so empty days and days the user marked "ignore from stats" don't
/// drag the mean down.
/// Used by the period intake views (week/month/year) to feed `AverageMacrosTable`.
import Foundation

extension Array where Element == DailyLog {
    /// Days that count toward the period averages: at least one entry and not
    /// flagged `excluded`.
    /// Outputs: the subset of days included in every `avg*` computation.
    var statDays: [DailyLog] {
        filter { $0.entryCount > 0 && !$0.excluded }
    }

    /// Average kcal per counted day (skips empty and excluded days).
    /// Outputs: mean calories across counted days (0 when none).
    var avgCalories: Int {
        let logged = statDays
        guard !logged.isEmpty else { return 0 }
        return logged.map(\.totalCalories).reduce(0, +) / logged.count
    }

    /// Average protein grams per counted day (skips empty and excluded days).
    /// Outputs: mean protein grams across counted days (0 when none).
    var avgProtein: Double {
        let logged = statDays
        guard !logged.isEmpty else { return 0 }
        return logged.map(\.totalProteinG).reduce(0, +) / Double(logged.count)
    }

    /// Average carbohydrate grams per counted day (skips empty and excluded days).
    /// Outputs: mean carb grams across counted days (0 when none).
    var avgCarbs: Double {
        let logged = statDays
        guard !logged.isEmpty else { return 0 }
        return logged.map(\.totalCarbsG).reduce(0, +) / Double(logged.count)
    }

    /// Average fat grams per counted day (skips empty and excluded days).
    /// Outputs: mean fat grams across counted days (0 when none).
    var avgFat: Double {
        let logged = statDays
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
