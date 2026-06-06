/// Full-width action button shared across the day-copy and meal-log flows.
/// Renders the common fill + stroke-border + semibold-label shape used by
/// `DayMacroView`, `CopyEntriesSheet`, `MealDetailView`, and `MealLogSheet`.
/// The accent tint is configurable (default mauve); destructive actions pass red.
import SwiftUI

/// Primary call-to-action button: a full-width, mauve-tinted, stroke-bordered
/// capsule-card with a leading glyph or spinner and a semibold title.
///
/// Two shapes, selected by `leading`: an inline action bar (`.icon`, used by
/// `DayMacroView` and `MealDetailView`) and a sheet-confirm button (`.busy`,
/// used by `CopyEntriesSheet` and `MealDetailView`'s log sheet). The padding and
/// disabled-dimming differ between the two and are derived from `leading`, so
/// each site renders pixel-identically without per-call style knobs.
struct PrimaryActionButton: View {
    /// The leading element shown before the title — also selects the button shape.
    enum Leading {
        /// Inline-bar style with a fixed SF Symbol glyph (size 16, semibold).
        case icon(String)
        /// Sheet-confirm style with a spinner shown only while `isBusy` is true.
        case busy(Bool)
    }

    /// The button's title text.
    let title: String
    /// The leading element (glyph or conditional spinner), which selects the shape.
    let leading: Leading
    /// Accent color for the label, fill, and border. Defaults to the standard
    /// mauve primary treatment; pass `Theme.CTP.red` for destructive actions.
    var tint: Color = Theme.CTP.mauve
    /// Whether the button is disabled (non-interactive).
    let disabled: Bool
    /// The tap handler.
    let action: () -> Void

    /// Whether this is the sheet-confirm shape (taller, bottom-padded). Derived
    /// from `leading` so the two call-site shapes stay consistent.
    private var isSheetConfirm: Bool {
        if case .busy = leading { return true }
        return false
    }

    var body: some View {
        let verticalPadding: CGFloat = isSheetConfirm ? 14 : 13
        let bottomPadding: CGFloat = isSheetConfirm ? 12 : 0
        let dimWhenDisabled = !isSheetConfirm
        return primaryButton(verticalPadding: verticalPadding,
                             bottomPadding: bottomPadding,
                             dimWhenDisabled: dimWhenDisabled)
    }

    /// Builds the button body with the resolved per-shape padding/dimming.
    /// Inputs:
    ///   - verticalPadding: vertical padding inside the fill.
    ///   - bottomPadding: bottom padding applied outside the button.
    ///   - dimWhenDisabled: whether to fade to 0.5 opacity while disabled.
    /// Outputs: the composed button view.
    private func primaryButton(verticalPadding: CGFloat, bottomPadding: CGFloat, dimWhenDisabled: Bool) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                leadingView
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: Theme.Layout.cardRadius, style: .continuous)
                    .fill(tint.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Layout.cardRadius, style: .continuous)
                    .strokeBorder(tint.opacity(0.30), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(dimWhenDisabled && disabled ? 0.5 : 1)
        .padding(.bottom, bottomPadding)
    }

    /// The leading element rendered before the title: a fixed glyph, or a spinner
    /// shown only while busy.
    @ViewBuilder
    private var leadingView: some View {
        switch leading {
        case .icon(let name):
            Image(systemName: name)
                .font(.system(size: 16, weight: .semibold))
        case .busy(let isBusy):
            if isBusy {
                ProgressView().tint(tint)
            }
        }
    }
}
