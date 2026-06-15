/// Hero kcal ring for the day view.
/// Renders a circular gradient progress ring showing consumed vs. target kcal,
/// with center text for KCAL label, consumed value, target, and a percent pill.
import SwiftUI

/// Circular consumed-vs-target kcal indicator with animated fill.
struct MacroRing: View {
    let consumed: Int
    let target: Int
    /// Projected kcal if the day's pending entries were confirmed. When set and
    /// greater than `consumed`, a dimmed "ghost" arc extends from the confirmed
    /// fill out to this value. `nil` (no pending) hides the ghost entirely.
    var projected: Int?

    /// Fill fraction in 0...1. Returns 0 when target is non-positive to avoid division.
    /// Outputs: clamped progress value used to trim the ring.
    private var progress: Double {
        guard target > 0 else { return 0 }
        return min(1.0, Double(consumed) / Double(target))
    }

    /// Projected fill fraction in 0...1 for the ghost arc, or 0 when there is no
    /// projection (or no target).
    /// Outputs: clamped projected progress used to trim the ghost arc.
    private var projectedProgress: Double {
        guard let projected, target > 0 else { return 0 }
        return min(1.0, Double(projected) / Double(target))
    }

    /// Pending kcal not yet confirmed (`projected − consumed`), or nil when there
    /// is no projection or it doesn't exceed the confirmed total.
    /// Outputs: positive pending kcal to annotate, or nil.
    private var pendingDelta: Int? {
        guard let projected, projected > consumed else { return nil }
        return projected - consumed
    }

    /// Percent of target reached, rounded to nearest integer for display.
    /// Outputs: integer 0...100.
    private var pct: Int { Int((progress * 100).rounded()) }

    /// VoiceOver summary, including the pending projection when present.
    /// Outputs: a spoken description of consumed/target/percent (+ pending kcal).
    private var accessibilityText: String {
        let base = "\(consumed) of \(target) kilocalories, \(pct) percent"
        if let pendingDelta {
            return base + ", plus \(pendingDelta) pending"
        }
        return base
    }

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

            // Ghost arc for the projected (pending-included) total, drawn under the
            // confirmed arc so the segment beyond `progress` reads as "if confirmed".
            if projectedProgress > progress {
                Circle()
                    .trim(from: 0, to: projectedProgress)
                    .stroke(
                        Theme.projected.opacity(0.5),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.7), value: projectedProgress)
            }

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

                if let pendingDelta {
                    Text("+\(pendingDelta) pending")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Theme.pending)
                        .padding(.top, 4)
                }
            }
        }
        .frame(width: 168, height: 168)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }
}

#Preview {
    MacroRing(consumed: 1240, target: 2200)
        .padding()
        .background(Theme.BG.primary)
        .preferredColorScheme(.dark)
}
