/// WeightAnalytics: pure functions that derive trends, maintenance kcal, and ETA
/// from weight + calorie history.
/// Contains WeightETA (target outcome), WeightAnalyticsResult (output bundle),
/// and the WeightAnalytics enum's static `compute` plus private helpers.
/// Role: shared math used by WeightTrendsModel; no I/O, fully testable.
import Foundation
import os.log

private let analyticsDiagLog = Logger(subsystem: "com.pulseapp.pulse", category: "AnalyticsDiag")

/// Outcome of projecting current trend against a target weight.
enum WeightETA: Hashable {
    case date(Date)
    case stable
    case never
}

/// Output bundle of analytics derived from weight + calorie history.
struct WeightAnalyticsResult: Hashable {
    let maintenanceKcal: Int?      // simple energy-balance estimate
    let recentAvgKcal: Int?        // avg daily intake over recent window
    let trendLbPerWeek: Double?
    let etaToTarget: WeightETA?
    let recentWindowDays: Int?     // length of the consecutive-logged window used above
}

/// Namespace for pure analytics functions over weight + calorie history.
enum WeightAnalytics {

    static let maxRecentWindowDays = 30
    static let minRecentWindowDays = 14
    static let trendWindowDays = 28
    static let minTrendWeightObs = 5
    static let kcalPerLb = 3500.0
    static let stableLbPerWeekThreshold = 0.05
    static let atTargetLbThreshold = 0.5

    /// Computes the full analytics bundle (trend, maintenance kcal, ETA) from history.
    /// Inputs:
    ///   - entries: all available weight entries.
    ///   - kcal: daily calorie totals.
    ///   - targetWeightLb: user's target weight (for ETA), or nil.
    ///   - today: anchor date for windows (defaults to now).
    /// Outputs: aggregated analytics; individual fields may be nil when inputs are insufficient.
    static func compute(
        entries: [WeightEntry],
        kcal: [CaloriesDailyRow],
        targetWeightLb: Double?,
        today: Date = .now
    ) -> WeightAnalyticsResult {
        let cal = Calendar(identifier: .gregorian)
        let endDay = cal.startOfDay(for: today)

        // Days the user flagged "ignore from stats" are dropped so a forgotten or
        // partial log day can't distort the maintenance/intake-average math (they
        // also read as gaps, breaking the consecutive-day window like an unlogged day).
        let kcalByDay: [Date: Double] = Dictionary(
            uniqueKeysWithValues: kcal
                .filter { !$0.excluded }
                .map { (cal.startOfDay(for: $0.date), Double($0.calories)) }
        )

        // Display trend + ETA depend only on weight data; calorie gaps must not
        // suppress them.
        // Gregorian day arithmetic cannot fail here; collapse to a single-day
        // window (trend becomes nil) rather than crash if it ever did.
        let trendCutoff = cal.date(byAdding: .day, value: -(trendWindowDays - 1), to: endDay) ?? endDay
        let trendLbPerWeek = Self.trendLbPerWeek(
            entries: entries, start: trendCutoff, end: endDay, calendar: cal
        )

        // Intake average comes from the consecutive-kcal window so partial
        // logging doesn't deflate it. The 28-day weight trend is used for the
        // deficit term so the caption matches what's displayed.
        let window = recentConsecutiveWindow(
            kcalByDay: kcalByDay, today: endDay, calendar: cal
        )
        let (maintenanceKcal, recentAvgKcal): (Int?, Int?) = window.map { w in
            simpleMaintenance(
                kcalByDay: kcalByDay, start: w.start, end: w.end,
                trendLbPerWeek: trendLbPerWeek, calendar: cal
            )
        } ?? (nil, nil)

        let eta = computeETA(
            entries: entries,
            trendLbPerWeek: trendLbPerWeek,
            targetWeightLb: targetWeightLb,
            today: endDay,
            calendar: cal
        )

        #if DEBUG
        let avgStr = recentAvgKcal.map(String.init) ?? "nil"
        let trendStr = trendLbPerWeek.map { String(format: "%.2f", $0) } ?? "nil"
        let maintStr = maintenanceKcal.map(String.init) ?? "nil"
        let winStr = window.map { "\($0.days)d" } ?? "nil"
        let summary = "window=\(winStr) recentAvgKcal=\(avgStr) trendLb/wk=\(trendStr) maintenance=\(maintStr)"
        analyticsDiagLog.notice("\(summary, privacy: .public)")
        #endif

        return WeightAnalyticsResult(
            maintenanceKcal: maintenanceKcal,
            recentAvgKcal: recentAvgKcal,
            trendLbPerWeek: trendLbPerWeek,
            etaToTarget: eta,
            recentWindowDays: window.map { $0.days }
        )
    }

    // Walks back from `today` and returns the most recent contiguous run of
    // kcal-logged days, capped at `maxRecentWindowDays`. Returns nil if the run
    // is shorter than `minRecentWindowDays`.
    /// Finds the most recent contiguous run of kcal-logged days.
    /// Inputs:
    ///   - kcalByDay: map of day -> calories.
    ///   - today: anchor date to walk back from.
    ///   - cal: calendar used for day arithmetic.
    /// Outputs: tuple of (start, end, days) for the window, or nil when shorter than the minimum.
    private static func recentConsecutiveWindow(
        kcalByDay: [Date: Double],
        today: Date,
        calendar cal: Calendar
    ) -> (start: Date, end: Date, days: Int)? {
        var endDay: Date?
        for offset in 0..<maxRecentWindowDays {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { break }
            if kcalByDay[day] != nil { endDay = day; break }
        }
        guard let end = endDay else { return nil }
        var start = end
        for offset in 1..<maxRecentWindowDays {
            guard let day = cal.date(byAdding: .day, value: -offset, to: end) else { break }
            if kcalByDay[day] != nil { start = day } else { break }
        }
        let days = daysBetween(start, end, calendar: cal) + 1
        guard days >= minRecentWindowDays else { return nil }
        return (start, end, days)
    }

    /// Estimates maintenance kcal via energy balance: avg intake minus the trend's deficit.
    /// Inputs:
    ///   - kcalByDay: map of day -> calories.
    ///   - start: window start (inclusive).
    ///   - end: window end (inclusive).
    ///   - trendLbPerWeek: weight trend slope, or nil to skip maintenance.
    ///   - cal: calendar (unused but kept for signature symmetry).
    /// Outputs: tuple of (maintenanceKcal, recentAvgKcal); maintenance is nil when trend missing/non-finite.
    private static func simpleMaintenance(
        kcalByDay: [Date: Double],
        start: Date,
        end: Date,
        trendLbPerWeek: Double?,
        calendar cal: Calendar
    ) -> (Int?, Int?) {
        let inWindow = kcalByDay.filter { $0.key >= start && $0.key <= end }
        guard !inWindow.isEmpty else { return (nil, nil) }
        let avg = inWindow.values.reduce(0, +) / Double(inWindow.count)
        let avgInt = Int(avg.rounded())
        guard let trend = trendLbPerWeek else { return (nil, avgInt) }
        // Energy balance: maintenance = intake - rate × kcalPerLb
        // (rate is negative when losing, so subtracting adds the deficit back.)
        let lbPerDay = trend / 7.0
        let maintenance = avg - lbPerDay * kcalPerLb
        guard maintenance.isFinite, maintenance > 0 else { return (nil, avgInt) }
        return (Int(maintenance.rounded()), avgInt)
    }

    /// OLS slope of weight in lb/week over the window, or nil with insufficient data.
    /// Inputs:
    ///   - entries: weight entries to consider.
    ///   - start: window start (inclusive).
    ///   - end: window end (inclusive).
    ///   - cal: calendar used for day arithmetic.
    /// Outputs: trend in lb/week, or nil when below `minTrendWeightObs` observations.
    private static func trendLbPerWeek(
        entries: [WeightEntry],
        start: Date,
        end: Date,
        calendar cal: Calendar
    ) -> Double? {
        let pts: [(Double, Double)] = entries
            .map { (cal.startOfDay(for: $0.date), $0.weightLb) }
            .filter { $0.0 >= start && $0.0 <= end }
            .map { (Double(daysBetween(start, $0.0, calendar: cal)), $0.1) }
        guard pts.count >= minTrendWeightObs,
              let (slope, _, _) = ols(xs: pts.map(\.0), ys: pts.map(\.1)) else { return nil }
        return slope * 7.0
    }

    /// Projects when the user will hit `targetWeightLb` given the current trend.
    /// Inputs:
    ///   - entries: weight entries to seed the latest mean weight.
    ///   - trendLbPerWeek: slope in lb/week; nil suppresses the ETA.
    ///   - targetWeightLb: user target; nil suppresses the ETA.
    ///   - today: anchor date for projection.
    ///   - cal: calendar used for day arithmetic.
    /// Outputs: .date / .stable / .never depending on direction and slope, or nil when inputs missing.
    private static func computeETA(
        entries: [WeightEntry],
        trendLbPerWeek: Double?,
        targetWeightLb: Double?,
        today: Date,
        calendar cal: Calendar
    ) -> WeightETA? {
        guard let target = targetWeightLb, let trend = trendLbPerWeek else { return nil }
        if abs(trend) < stableLbPerWeekThreshold { return .stable }

        guard let cutoff = cal.date(byAdding: .day, value: -6, to: today) else { return nil }
        let recent = entries.filter { cal.startOfDay(for: $0.date) >= cutoff }
        let latestMean: Double
        if !recent.isEmpty {
            latestMean = recent.map(\.weightLb).reduce(0, +) / Double(recent.count)
        } else if let last = entries.max(by: { $0.date < $1.date }) {
            latestMean = last.weightLb
        } else {
            return nil
        }

        let direction = target - latestMean
        if abs(direction) < atTargetLbThreshold { return .stable }
        let sameSign = (direction > 0 && trend > 0) || (direction < 0 && trend < 0)
        if !sameSign { return .never }

        let lbPerDay = trend / 7.0
        let daysOut = direction / lbPerDay
        guard let eta = cal.date(byAdding: .day, value: Int(daysOut.rounded()), to: today) else {
            return nil
        }
        return .date(eta)
    }

    /// Ordinary least squares regression for two parallel numeric arrays.
    /// Inputs:
    ///   - xs: independent variable samples.
    ///   - ys: dependent variable samples (same length as xs).
    /// Outputs: (slope, intercept, r2), or nil when fewer than 2 points or zero x-variance.
    private static func ols(xs: [Double], ys: [Double]) -> (slope: Double, intercept: Double, r2: Double)? {
        guard xs.count == ys.count, xs.count >= 2 else { return nil }
        let n = Double(xs.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for i in 0..<xs.count {
            let dx = xs[i] - meanX
            let dy = ys[i] - meanY
            sxx += dx * dx
            sxy += dx * dy
            syy += dy * dy
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        let intercept = meanY - slope * meanX
        let r2 = syy > 0 ? (sxy * sxy) / (sxx * syy) : 1.0
        return (slope, intercept, r2)
    }

    /// Whole-day distance from `a` to `b`.
    /// Inputs:
    ///   - a: earlier date.
    ///   - b: later date.
    ///   - cal: calendar used for day arithmetic.
    /// Outputs: number of full days between `a` and `b`; 0 when the calendar cannot compute it.
    private static func daysBetween(_ a: Date, _ b: Date, calendar cal: Calendar) -> Int {
        cal.dateComponents([.day], from: a, to: b).day ?? 0
    }
}
