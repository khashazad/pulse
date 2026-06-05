/// Reusable empty/error placeholder shared across the intake/meals/prep screens.
/// Renders an icon glyph, title, description, and an optional action button.
import SwiftUI

/// Reusable empty/error placeholder with an icon glyph, title, description, and optional action button.
/// Used by every list-style screen for the empty / load-failed states.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let description: String
    var action: (() -> Void)?
    var actionLabel: String = "Retry"

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.CTP.mauve.opacity(0.10))
                    .frame(width: 64, height: 64)
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(Theme.CTP.mauve)
            }
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.FG.primary)
            Text(description)
                .font(.system(size: 14))
                .foregroundStyle(Theme.FG.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            if let action {
                Button(actionLabel, action: action)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.CTP.mauve)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}
