/// Hero kcal ring for the day view.
/// Renders a circular gradient progress ring showing consumed vs. target kcal,
/// with center text for KCAL label, consumed value, target, and a percent pill.
import SwiftUI

/// Circular consumed-vs-target kcal indicator with animated fill.
struct MacroRing: View {
    let consumed: Int
    let target: Int

    /// Fill fraction in 0...1. Returns 0 when target is non-positive to avoid division.
    /// Outputs: clamped progress value used to trim the ring.
    private var progress: Double {
        guard target > 0 else { return 0 }
        return min(1.0, Double(consumed) / Double(target))
    }

    /// Percent of target reached, rounded to nearest integer for display.
    /// Outputs: integer 0...100.
    private var pct: Int { Int((progress * 100).rounded()) }

    private let ringGradient = AngularGradient(
        gradient: Gradient(colors: [Theme.CTP.lavender, Theme.CTP.mauve, Theme.CTP.pink, Theme.CTP.lavender]),
        center: .center,
        startAngle: .degrees(0),
        endAngle: .degrees(360)
    )

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.FG.quaternary, lineWidth: 10)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    ringGradient,
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: Theme.CTP.mauve.opacity(0.45), radius: 6)
                .animation(.easeOut(duration: 0.7), value: progress)

            VStack(spacing: 2) {
                Text("KCAL")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.FG.secondary)

                Text("\(consumed)")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.FG.primary)
                    .padding(.top, 2)

                HStack(spacing: 4) {
                    Text("of")
                        .foregroundStyle(Theme.FG.secondary)
                    Text("\(target)")
                        .monospacedDigit()
                        .foregroundStyle(Theme.FG.primary)
                }
                .font(.system(size: 12))
                .padding(.top, 4)

                Text("\(pct)%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.4)
                    .monospacedDigit()
                    .foregroundStyle(Theme.CTP.mauve)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Theme.CTP.mauve.opacity(0.14))
                    )
                    .padding(.top, 6)
            }
        }
        .frame(width: 168, height: 168)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(consumed) of \(target) kilocalories, \(pct) percent")
    }
}

#Preview {
    MacroRing(consumed: 1240, target: 2200)
        .padding()
        .background(Theme.BG.primary)
        .preferredColorScheme(.dark)
}
