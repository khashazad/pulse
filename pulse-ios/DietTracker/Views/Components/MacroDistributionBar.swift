/// Capsule-clipped macro distribution bar.
/// Splits a horizontal bar into three colored segments sized by kcal contribution
/// from protein, carbs, and fat. Used on meal detail and similar surfaces.
import SwiftUI

/// Single horizontal bar split into Protein/Carbs/Fat segments by kcal contribution.
/// Pixel mapping mirrors the meals_redesign prototype.
struct MacroDistributionBar: View {
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
    var height: CGFloat = 5

    /// Total kcal across the three macros, clamped to at least 1 to avoid divide-by-zero.
    /// Outputs: positive kcal total used as the segment-width denominator.
    private var totalKcal: Double {
        let total = proteinG * 4 + carbsG * 4 + fatG * 9
        return total > 0 ? total : 1
    }

    var body: some View {
        GeometryReader { geo in
            let p = (proteinG * 4) / totalKcal
            let c = (carbsG * 4) / totalKcal
            let f = (fatG * 9) / totalKcal
            HStack(spacing: 0) {
                Theme.Macro.protein.color.frame(width: geo.size.width * p)
                Theme.Macro.carbs.color.frame(width: geo.size.width * c)
                Theme.Macro.fat.color.frame(width: geo.size.width * f)
            }
        }
        .frame(height: height)
        .background(Theme.CTP.surface1.opacity(0.45))
        .clipShape(Capsule())
    }
}

#Preview {
    VStack(spacing: 12) {
        MacroDistributionBar(proteinG: 25, carbsG: 108, fatG: 19)
        MacroDistributionBar(proteinG: 60, carbsG: 60, fatG: 20)
    }
    .padding()
    .background(Theme.BG.primary)
    .preferredColorScheme(.dark)
}
