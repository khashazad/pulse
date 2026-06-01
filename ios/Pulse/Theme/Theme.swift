/// Pulse visual theme tokens.
/// Defines the Catppuccin Macchiato palette (`Theme.CTP`), semantic background
/// (`BG`) and foreground (`FG`) roles, the macro-channel color/label mapping
/// (`Macro`), layout metrics (`Layout`), shared separator/tint colors, and a
/// reusable card-surface `View` modifier (`ctpCard`). Single source of truth
/// for colors, radii, and spacing used across SwiftUI views.
import SwiftUI

/// Pulse · Catppuccin Macchiato re-theme.
/// Palette: catppuccin/catppuccin (BSD). Dark only.
enum Theme {

    /// Raw Catppuccin Macchiato palette swatches. Consumers should prefer the
    /// semantic `BG` / `FG` namespaces; this is the underlying source.
    enum CTP {
        static let rosewater = Color(red: 0.957, green: 0.859, blue: 0.839) // #f4dbd6
        static let flamingo  = Color(red: 0.941, green: 0.776, blue: 0.776) // #f0c6c6
        static let pink      = Color(red: 0.961, green: 0.741, blue: 0.902) // #f5bde6
        static let mauve     = Color(red: 0.776, green: 0.627, blue: 0.965) // #c6a0f6
        static let red       = Color(red: 0.929, green: 0.529, blue: 0.588) // #ed8796
        static let maroon    = Color(red: 0.933, green: 0.600, blue: 0.627) // #ee99a0
        static let peach     = Color(red: 0.961, green: 0.663, blue: 0.498) // #f5a97f
        static let yellow    = Color(red: 0.933, green: 0.831, blue: 0.624) // #eed49f
        static let green     = Color(red: 0.651, green: 0.855, blue: 0.584) // #a6da95
        static let teal      = Color(red: 0.545, green: 0.835, blue: 0.792) // #8bd5ca
        static let sky       = Color(red: 0.569, green: 0.843, blue: 0.890) // #91d7e3
        static let sapphire  = Color(red: 0.490, green: 0.769, blue: 0.894) // #7dc4e4
        static let blue      = Color(red: 0.541, green: 0.678, blue: 0.957) // #8aadf4
        static let lavender  = Color(red: 0.718, green: 0.741, blue: 0.973) // #b7bdf8

        static let text     = Color(red: 0.792, green: 0.827, blue: 0.961) // #cad3f5
        static let subtext1 = Color(red: 0.722, green: 0.753, blue: 0.878) // #b8c0e0
        static let subtext0 = Color(red: 0.647, green: 0.678, blue: 0.796) // #a5adcb
        static let overlay2 = Color(red: 0.576, green: 0.604, blue: 0.718) // #939ab7
        static let overlay1 = Color(red: 0.502, green: 0.529, blue: 0.635) // #8087a2
        static let overlay0 = Color(red: 0.431, green: 0.451, blue: 0.553) // #6e738d
        static let surface2 = Color(red: 0.357, green: 0.376, blue: 0.471) // #5b6078
        static let surface1 = Color(red: 0.286, green: 0.302, blue: 0.392) // #494d64
        static let surface0 = Color(red: 0.212, green: 0.227, blue: 0.310) // #363a4f
        static let base     = Color(red: 0.141, green: 0.153, blue: 0.227) // #24273a
        static let mantle   = Color(red: 0.118, green: 0.125, blue: 0.188) // #1e2030
        static let crust    = Color(red: 0.094, green: 0.098, blue: 0.149) // #181926
    }

    /// Semantic background roles mapped to palette swatches.
    enum BG {
        static let primary   = CTP.base
        static let secondary = CTP.mantle
        static let tertiary  = CTP.surface0
        static let elevated  = Color(red: 0.173, green: 0.184, blue: 0.267) // #2c2f44
    }

    /// Semantic foreground (text/icon) roles mapped to palette swatches.
    enum FG {
        static let primary    = CTP.text
        static let secondary  = CTP.subtext0
        static let tertiary   = CTP.overlay1
        static let quaternary = CTP.overlay0.opacity(0.45)
    }

    static let separator = CTP.surface2.opacity(0.45)
    static let tint = CTP.mauve

    /// Macro channel identifier (protein / carbs / fat) with associated display
    /// color, translucent background tint, full label, and one-letter short label.
    enum Macro {
        case protein, carbs, fat
        var color: Color {
            switch self {
            case .protein: CTP.blue
            case .carbs:   CTP.peach
            case .fat:     CTP.pink
            }
        }
        var bgTint: Color { color.opacity(0.16) }
        var label: String {
            switch self {
            case .protein: "Protein"
            case .carbs:   "Carbs"
            case .fat:     "Fat"
            }
        }
        var short: String {
            switch self {
            case .protein: "P"
            case .carbs:   "C"
            case .fat:     "F"
            }
        }
    }

    /// Layout metrics shared across views — clearances, corner radii, spacing.
    enum Layout {
        static let dockClearance: CGFloat = 96
        static let sectionSpacing: CGFloat = 16
        static let cardRadius: CGFloat = 14
        static let chipRadius: CGFloat = 14
        static let barRadius: CGFloat = 4
    }

    static let dockShadow = (
        color: Color.black.opacity(0.55),
        radius: CGFloat(24),
        x: CGFloat(0),
        y: CGFloat(8)
    )
}

/// Adds the Catppuccin card-surface modifier to all SwiftUI `View`s.
extension View {
    /// Catppuccin "card" surface — bg-tertiary fill, hairline mauve-tinted border, 14pt radius.
    ///
    /// Inputs:
    /// - `radius`: corner radius applied to both fill and border; defaults to
    ///   `Theme.Layout.cardRadius`.
    /// - `tint`: optional translucent color layered over the base fill to give the
    ///   card a colored wash (e.g. to distinguish adjacent groupings). `nil` (the
    ///   default) yields the plain surface.
    ///
    /// Outputs: the receiver with a rounded filled background and a hairline
    /// separator-colored stroke overlay.
    func ctpCard(radius: CGFloat = Theme.Layout.cardRadius, tint: Color? = nil) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.BG.tertiary)
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(tint ?? .clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 0.5)
        )
    }
}
