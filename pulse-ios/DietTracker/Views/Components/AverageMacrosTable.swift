import SwiftUI

struct AverageMacrosTable: View {
    let avgKcal: Int
    let avgProteinG: Int
    let avgCarbsG: Int
    let avgFatG: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Avg / day")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.FG.secondary)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(avgKcal)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.FG.primary)
                    Text("cal")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.FG.tertiary)
                }
            }

            Rectangle().fill(Theme.separator).frame(height: 0.5)

            VStack(spacing: 8) {
                row(.protein, value: avgProteinG)
                row(.carbs,   value: avgCarbsG)
                row(.fat,     value: avgFatG)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .ctpCard()
    }

    private func row(_ macro: Theme.Macro, value: Int) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(macro.color)
                .frame(width: 8, height: 8)
            Text(macro.label)
                .font(.system(size: 14))
                .foregroundStyle(Theme.FG.primary)
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(value)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.FG.primary)
                Text("g")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.FG.tertiary)
            }
        }
    }
}

#Preview {
    AverageMacrosTable(avgKcal: 2010, avgProteinG: 124, avgCarbsG: 217, avgFatG: 69)
        .padding()
        .background(Theme.BG.primary)
        .preferredColorScheme(.dark)
}
