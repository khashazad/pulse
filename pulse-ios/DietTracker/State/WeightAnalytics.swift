import Foundation
import os.log

private let analyticsDiagLog = Logger(subsystem: "com.khxsh.diettracker", category: "AnalyticsDiag")

enum WeightETA: Hashable {
    case date(Date)
    case stable
    case never
}

struct WeightAnalyticsResult: Hashable {
    let maintenanceKcal: Int?      // simple energy-balance estimate
    let recentAvgKcal: Int?        // avg daily intake over recent window
    let trendLbPerWeek: Double?
    let etaToTarget: WeightETA?
    let recentWindowDays: Int?     // length of the consecutive-logged window used above
}

enum WeightAnalytics {

    static let maxRecentWindowDays = 30
    static let minRecentWindowDays = 14
    static let trendWindowDays = 28
    static let minTrendWeightObs = 5
    static let kcalPerLb = 3500.0
    static let stableLbPerWeekThreshold = 0.05
    static let atTargetLbThreshold = 0.5

    static func compute(
        entries: [WeightEntry],
        kcal: [CaloriesDailyRow],
        targetWeightLb: Double?,
        today: Date = .now
    ) -> WeightAnalyticsResult {
        let cal = Calendar(identifier: .gregorian)
        let endDay = cal.startOfDay(for: today)

        let kcalByDay: [Date: Double] = Dictionary(
            uniqueKeysWithValues: kcal.map { (cal.startOfDay(for: $0.date), Double($0.calories)) }
        )

        // Display trend + ETA depend only on weight data; calorie gaps must not
        // suppress them.
        let trendCutoff = cal.date(byAdding: .day, value: -(trendWindowDays - 1), to: endDay)!
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
        analyticsDiagLog.notice("window=\(winStr, privacy: .public) recentAvgKcal=\(avgStr, privacy: .public) trendLb/wk=\(trendStr, privacy: .public) maintenance=\(maintStr, privacy: .public)")
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
    private static func recentConsecutiveWindow(
        kcalByDay: [Date: Double],
        today: Date,
        calendar cal: Calendar
    ) -> (start: Date, end: Date, days: Int)? {
        var endDay: Date? = nil
        for offset in 0..<maxRecentWindowDays {
            let day = cal.date(byAdding: .day, value: -offset, to: today)!
            if kcalByDay[day] != nil { endDay = day; break }
        }
        guard let end = endDay else { return nil }
        var start = end
        for offset in 1..<maxRecentWindowDays {
            let day = cal.date(byAdding: .day, value: -offset, to: end)!
            if kcalByDay[day] != nil { start = day } else { break }
        }
        let days = daysBetween(start, end, calendar: cal) + 1
        guard days >= minRecentWindowDays else { return nil }
        return (start, end, days)
    }

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

    private static func computeETA(
        entries: [WeightEntry],
        trendLbPerWeek: Double?,
        targetWeightLb: Double?,
        today: Date,
        calendar cal: Calendar
    ) -> WeightETA? {
        guard let target = targetWeightLb, let trend = trendLbPerWeek else { return nil }
        if abs(trend) < stableLbPerWeekThreshold { return .stable }

        let cutoff = cal.date(byAdding: .day, value: -6, to: today)!
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
        let eta = cal.date(byAdding: .day, value: Int(daysOut.rounded()), to: today)!
        return .date(eta)
    }

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

    private static func daysBetween(_ a: Date, _ b: Date, calendar cal: Calendar) -> Int {
        cal.dateComponents([.day], from: a, to: b).day ?? 0
    }
}
