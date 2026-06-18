// Pulse/Views/Components/FoodGroupRow.swift
/// Collapsible list row for a grouped Food in the Food tab's "Foods" section.
/// Collapsed: name, "N portions", and the representative (default) portion's
/// kcal + P/C/F. Expanded: a tappable sub-row per portion. Mirrors CustomFoodRow's
/// visual language. Expansion state is owned by the caller so the list controls it.
import SwiftUI

/// Row view for one grouped food and its expandable portions.
struct FoodGroupRow: View {
    /// The grouped food to render, including its nested portions.
    let food: Food
    /// Whether the portion sub-rows are currently shown.
    let isExpanded: Bool
    /// Toggles this row's expansion.
    let onToggle: () -> Void
    /// Invoked with a portion's custom-food id when a portion sub-row is tapped.
    let onSelectPortion: (UUID) -> Void
    /// Invoked when the user taps Ungroup (shown only when expanded and non-nil).
    var onUngroup: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) { header }.buttonStyle(.plain)
            if isExpanded {
                ForEach(food.portions) { portion in
                    Button { onSelectPortion(portion.customFoodId) } label: {
                        portionRow(portion)
                    }
                    .buttonStyle(.plain)
                }
                if let onUngroup { ungroupButton(onUngroup) }
            }
        }
        .contentShape(Rectangle())
    }

    /// The Ungroup action shown at the foot of an expanded food.
    /// Inputs:
    ///   - action: the handler invoked when Ungroup is tapped.
    /// Outputs: the composed ungroup button row.
    private func ungroupButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 12, weight: .semibold))
                Text("Ungroup")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .foregroundStyle(Theme.CTP.red)
            .padding(.vertical, 10)
            .padding(.leading, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The collapsed header: name + portion count on the left, representative
    /// macros on the right, and a chevron that points down when expanded.
    /// Outputs: the composed header view.
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(food.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.FG.primary)
                    .lineLimit(1)
                Text("\(food.portions.count) portion\(food.portions.count == 1 ? "" : "s")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.FG.tertiary)
            }
            Spacer(minLength: 8)
            if let rep = food.representativePortion {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(rep.calories)")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.CTP.mauve)
                        Text("cal").font(.system(size: 10)).foregroundStyle(Theme.FG.tertiary)
                    }
                    Text(MacroTotals.pcfSummary(proteinG: rep.proteinG, carbsG: rep.carbsG, fatG: rep.fatG))
                        .font(.system(size: 10, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Theme.FG.secondary)
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.FG.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// One portion sub-row, indented, with its label and kcal.
    /// Inputs:
    ///   - portion: the portion to render.
    /// Outputs: the composed sub-row view.
    private func portionRow(_ portion: FoodPortion) -> some View {
        HStack(spacing: 10) {
            Text(portion.label ?? "portion")
                .font(.system(size: 13))
                .foregroundStyle(Theme.FG.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(portion.calories) cal")
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Theme.FG.tertiary)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.FG.tertiary)
        }
        .padding(.vertical, 10)
        .padding(.leading, 16)
        .contentShape(Rectangle())
    }
}
