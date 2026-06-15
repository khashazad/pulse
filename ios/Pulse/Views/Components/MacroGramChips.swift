/// Three small colored "P 138g" / "C 210g" / "F 62g" chips for a macro-gram
/// breakdown. Shared by the Week and Month day-detail captions so a tapped day
/// reads the same way in both places.
import SwiftUI

/// Protein/carbs/fat gram chips for one day's (or a span's average) macro totals.
struct MacroGramChips: View {
    let proteinG: Double
    let carbsG: Double
    let fatG: Double

    var body: some View {
        HStack(spacing: 8) {
            chip(.protein, proteinG)
            chip(.carbs, carbsG)
            chip(.fat, fatG)
        }
    }

    /// One macro gram chip ("X NNg").
    /// Inputs:
    ///   - macro: which macro channel (drives color + letter).
    ///   - grams: the gram value, rounded to a whole number for display.
    /// Outputs: a colored "X NNg" label.
    private func chip(_ macro: Theme.Macro, _ grams: Double) -> some View {
        HStack(spacing: 3) {
            Text(macro.short)
                .font(.system(size: 10, weight: .bold))
            Text("\(Int(grams.rounded()))g")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
        }
        .foregroundStyle(macro.color)
    }
}

#Preview {
    MacroGramChips(proteinG: 138, carbsG: 210, fatG: 62)
        .padding()
        .background(Theme.BG.primary)
        .preferredColorScheme(.dark)
}
