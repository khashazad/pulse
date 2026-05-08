import SwiftUI

struct BucketKcalBars: View {
    let buckets: [PeriodBucket]
    let header: String
    let targetCalories: Int?

    private var ceiling: Int {
        max(buckets.map(\.avgKcalPerDay).max() ?? 0, targetCalories ?? 0, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(header)
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.FG.secondary)
                Spacer()
                if let target = targetCalories {
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(Theme.CTP.yellow)
                            .frame(width: 14, height: 1)
                        Text("target \(target)")
                            .monospacedDigit()
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.FG.tertiary)
                }
            }

            GeometryReader { geo in
                let plotHeight = geo.size.height - 20
                let targetY = targetCalories.map { CGFloat($0) / CGFloat(ceiling) * plotHeight } ?? 0
                ZStack(alignment: .bottomLeading) {
                    if targetCalories != nil {
                        Rectangle()
                            .fill(Theme.CTP.yellow.opacity(0.7))
                            .frame(height: 1)
                            .offset(y: -targetY - 20)
                            .opacity(0.7)
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(buckets) { bucket in
                            barColumn(bucket: bucket, plotHeight: plotHeight)
                        }
                    }
                }
            }
            .frame(height: 160)
        }
    }

    private func barColumn(bucket: PeriodBucket, plotHeight: CGFloat) -> some View {
        let h = max(2, CGFloat(bucket.avgKcalPerDay) / CGFloat(ceiling) * plotHeight)
        let gradient: LinearGradient = bucket.isCurrent
            ? LinearGradient(colors: [Theme.CTP.mauve, Theme.CTP.blue], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Theme.CTP.lavender.opacity(0.85), Theme.CTP.blue.opacity(0.55)], startPoint: .top, endPoint: .bottom)
        return VStack(spacing: 6) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: Theme.Layout.barRadius, style: .continuous)
                .fill(gradient)
                .frame(height: h)
                .shadow(color: bucket.isCurrent ? Theme.CTP.mauve.opacity(0.45) : .clear, radius: 6)
            Text(bucket.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(bucket.isCurrent ? Theme.CTP.mauve : Theme.FG.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    let buckets: [PeriodBucket] = [
        .init(id: 0, label: "W1", avgKcalPerDay: 1980, isCurrent: false),
        .init(id: 1, label: "W2", avgKcalPerDay: 2120, isCurrent: false),
        .init(id: 2, label: "W3", avgKcalPerDay: 2310, isCurrent: false),
        .init(id: 3, label: "W4", avgKcalPerDay: 1840, isCurrent: true),
    ]
    return BucketKcalBars(buckets: buckets, header: "Avg cal / day", targetCalories: 2200)
        .padding()
        .background(Theme.BG.primary)
        .preferredColorScheme(.dark)
}
