import SwiftUI

/// A small uppercased section title styled consistently across all activity cards.
///
/// - Parameter text: The label to display; it is uppercased automatically.
/// - Returns: A full-width `Text` view in a semibold, tracked, secondary-foreground style.
func activityCardTitle(_ text: String) -> some View {
    Text(text.uppercased())
        .font(.system(size: 11, weight: .semibold))
        .tracking(0.8)
        .foregroundStyle(Theme.FG.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
}
