/// Card-with-header section container shared by the form-style screens.
/// Wraps content in a `.ctpCard()` under an optional uppercase header caption and
/// above an optional tertiary footer caption. Used by `PrepView`,
/// `ContainerEditView`, and `SettingsView` so their section layout stays identical.
import SwiftUI

/// Wraps a card-styled content block under an optional uppercase section header
/// and above an optional footer caption.
///
/// The header's horizontal padding is parameterized (20 for the Prep/container
/// forms, 16 for Settings) so each call site renders exactly as before.
struct SectionCard<Content: View>: View {
    /// Optional uppercase caption rendered above the card.
    let header: String?
    /// Optional caption rendered below the card.
    let footer: String?
    /// Horizontal padding applied to the header caption.
    let headerHorizontalPadding: CGFloat
    /// The rows embedded inside the card.
    @ViewBuilder let content: Content

    /// Creates a section card.
    /// Inputs:
    ///   - header: optional uppercase caption rendered above the card.
    ///   - footer: optional caption rendered below the card.
    ///   - headerHorizontalPadding: horizontal padding for the header caption (default 20).
    ///   - content: view builder for the card body.
    /// Outputs: a `SectionCard` view.
    init(
        header: String? = nil,
        footer: String? = nil,
        headerHorizontalPadding: CGFloat = 20,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header
        self.footer = footer
        self.headerHorizontalPadding = headerHorizontalPadding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.FG.secondary)
                    .padding(.horizontal, headerHorizontalPadding)
            }
            VStack(spacing: 0) { content }
                .ctpCard()
                .padding(.horizontal, 16)
            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.FG.tertiary)
                    .padding(.horizontal, 20)
            }
        }
    }
}
