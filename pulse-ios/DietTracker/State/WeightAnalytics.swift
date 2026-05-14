import Foundation

struct WindowedPoint: Hashable {
    let endDate: Date
    let avgKcal: Double
    let lbPerDay: Double
}

struct WeightRegression: Hashable {
    let slope: Double     // lb/day per kcal/day
    let intercept: Double // lb/day
    let rSquared: Double
}

enum WeightETA: Hashable {
    case date(Date)
    case stable
    case never
}

struct WeightAnalyticsResult: Hashable {
    let scatter: [WindowedPoint]
    let regression: WeightRegression?
    let maintenanceKcal: Int?
    let trendLbPerWeek: Double?
    let etaToTarget: WeightETA?
    let validWindowCount: Int
}

enum WeightAnalytics {

    static let windowDays = 7
    static let minWeightObsInWindow = 5
    static let minKcalObsInWindow = 5
    static let minValidWindows = 14
    static let trendWindowDays = 28
    static let minTrendWeightObs = 7
    static let stableLbPerWeekThreshold = 0.05
    static let atTargetLbThreshold = 0.5
    static let slopeEpsilon = 1e-7

    static func compute(
        entries: [WeightEntry],
        kcal: [CaloriesDailyRow],
        targetWeightLb: Double?,
        today: Date = .now
    ) -> WeightAnalyticsResult {
        let cal = Calendar(identifier: .gregorian)
        guard !entries.isEmpty || !kcal.isEmpty else {
            return WeightAnalyticsResult(
                scatter: [], regression: nil, maintenanceKcal: nil,
                trendLbPerWeek: nil, etaToTarget: nil, validWindowCount: 0
            )
        }

        let weightByDay: [Date: Double] = Dictionary(
            uniqueKeysWithValues: entries.map { (cal.startOfDay(for: $0.date), $0.weightLb) }
        )
        let kcalByDay: [Date: Double] = Dictionary(
            uniqueKeysWithValues: kcal.map { (cal.startOfDay(for: $0.date), Double($0.calories)) }
        )

        let endDay = cal.startOfDay(for: today)
        let firstObserved = (entries.map(\.date) + kcal.map(\.date))
            .min().map { cal.startOfDay(for: $0) } ?? endDay
        let totalDays = max(1, daysBetween(firstObserved, endDay, calendar: cal) + 1)

        var scatter: [WindowedPoint] = []
        for offset in stride(from: 0, to: totalDays, by: 1) {
            let windowEnd = cal.date(byAdding: .day, value: offset - (totalDays - 1), to: endDay)!
            let windowStart = cal.date(byAdding: .day, value: -(windowDays - 1), to: windowEnd)!
            if windowStart < firstObserved { continue }

            var weightDays: [(Int, Double)] = []
            var kcalValues: [Double] = []
            for w in 0..<windowDays {
                let d = cal.date(byAdding: .day, value: w, to: windowStart)!
                if let lb = weightByDay[d] { weightDays.append((w, lb)) }
                if let c = kcalByDay[d] { kcalValues.append(c) }
            }
            guard weightDays.count >= minWeightObsInWindow,
                  kcalValues.count >= minKcalObsInWindow else { continue }

            let xs = weightDays.map { Double($0.0) }
            let ys = weightDays.map { $0.1 }
            guard let (slope, _, _) = ols(xs: xs, ys: ys) else { continue }
            let avgKcal = kcalValues.reduce(0, +) / Double(kcalValues.count)
            scatter.append(WindowedPoint(endDate: windowEnd, avgKcal: avgKcal, lbPerDay: slope))
        }

        var regression: WeightRegression? = nil
        var maintenanceKcal: Int? = nil
        if scatter.count >= minValidWindows {
            let xs = scatter.map(\.avgKcal)
            let ys = scatter.map(\.lbPerDay)
            if let (m, b, r2) = ols(xs: xs, ys: ys) {
                regression = WeightRegression(slope: m, intercept: b, rSquared: r2)
                if abs(m) >= slopeEpsilon {
                    let maintenance = -b / m
                    if maintenance.isFinite {
                        maintenanceKcal = Int(maintenance.rounded())
                    }
                }
            }
        }

        let trendLbPerWeek = trendLbPerWeek(
            entries: entries, today: endDay, calendar: cal
        )

        let eta = computeETA(
            entries: entries,
            trendLbPerWeek: trendLbPerWeek,
            targetWeightLb: targetWeightLb,
            today: endDay,
            calendar: cal
        )

        return WeightAnalyticsResult(
            scatter: scatter,
            regression: regression,
            maintenanceKcal: maintenanceKcal,
            trendLbPerWeek: trendLbPerWeek,
            etaToTarget: eta,
            validWindowCount: scatter.count
        )
    }

    // MARK: - helpers

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

    private static func trendLbPerWeek(
        entries: [WeightEntry],
        today: Date,
        calendar cal: Calendar
    ) -> Double? {
        let cutoff = cal.date(byAdding: .day, value: -(trendWindowDays - 1), to: today)!
        let pts = entries
            .filter { cal.startOfDay(for: $0.date) >= cutoff }
            .map { (entry: WeightEntry) -> (Double, Double) in
                let day = cal.startOfDay(for: entry.date)
                let offset = Double(daysBetween(cutoff, day, calendar: cal))
                return (offset, entry.weightLb)
            }
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

    private static func daysBetween(_ a: Date, _ b: Date, calendar cal: Calendar) -> Int {
        cal.dateComponents([.day], from: a, to: b).day ?? 0
    }
}
