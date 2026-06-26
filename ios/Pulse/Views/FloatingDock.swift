/// Bottom floating-dock tab bar used by `RootView`.
/// Defines the three top-level tabs (`DockTab`) and renders them as a capsule-shaped
/// pill of glyph + label buttons that drive the binding back to the parent.
import SwiftUI

/// Identifies one of the three top-level tabs hosted by `RootView`.
enum DockTab: Hashable {
    case nutrition, activity, measures
}

/// Floating capsule tab bar shown at the bottom of `RootView`.
/// Renders the three top-level `tabButton`s plus a Settings button that opens the
/// settings sheet (via `onSettings`) rather than switching tabs.
struct FloatingDock: View {
    @Binding var tab: DockTab
    /// Invoked when the Settings dock item is tapped; presents the settings sheet.
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            tabButton(.nutrition, system: "fork.knife", label: "Nutrition")
            tabButton(.activity, system: "figure.run", label: "Activity")
            tabButton(.measures, system: "figure.arms.open", label: "Measures")
            settingsButton
        }
        .padding(6)
        .modifier(DockSurface())
    }

    /// Dock item that opens the settings sheet. Unlike the tab buttons it never
    /// shows an active state, since Settings is presented over the current tab
    /// rather than being a persistent tab of its own.
    /// - Returns: A labeled gear button wired to `onSettings`.
    private var settingsButton: some View {
        Button(action: onSettings) {
            tabContents(system: "gearshape", label: "Settings", isActive: false)
        }
        .buttonStyle(.plain)
    }

    /// One tap-target in the dock; selects `target` on tap.
    /// Inputs:
    ///   - target: tab this button activates.
    ///   - system: SF Symbol name to display.
    ///   - label: text label shown below the glyph.
    /// Outputs: composed button view.
    private func tabButton(_ target: DockTab, system: String, label: String) -> some View {
        Button {
            tab = target
        } label: {
            tabContents(system: system, label: label, isActive: tab == target)
        }
        .buttonStyle(.plain)
    }

    /// Visual contents of a tab button: glyph stacked over label, with active-state styling.
    /// Inputs:
    ///   - system: SF Symbol name to display.
    ///   - label: text label shown below the glyph.
    ///   - isActive: whether this tab is the currently selected one.
    /// Outputs: composed contents view.
    private func tabContents(system: String, label: String, isActive: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: system)
                .font(.system(size: 16, weight: isActive ? .semibold : .regular))
            Text(label)
                .font(.system(size: 10, weight: isActive ? .semibold : .medium))
                .tracking(0.2)
        }
        .foregroundStyle(isActive ? Theme.CTP.mauve : Theme.FG.secondary)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(isActive ? Theme.CTP.mauve.opacity(0.16) : .clear)
        )
        .contentShape(Capsule())
    }
}

/// Dock background surface. On iOS 26+ it uses the native Liquid Glass material,
/// which refracts and blurs the content scrolling beneath the floating capsule.
/// On earlier OS versions it falls back to a tuned translucent material (a low
/// solid fill behind `.ultraThinMaterial`) plus a hairline border, approximating
/// the glass look without the live refraction.
private struct DockSurface: ViewModifier {
    func body(content: Content) -> some View {
        // `glassEffect` only exists in the iOS 26 SDK (Xcode 26 / Swift 6.2+). A
        // runtime `#available` check is not enough — the symbol must exist at
        // compile time — so gate it behind a compiler check too. Older toolchains
        // (e.g. CI's Xcode 16.4) compile only the material fallback.
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: Capsule(style: .continuous))
                .shadow(
                    color: Theme.dockShadow.color,
                    radius: Theme.dockShadow.radius,
                    x: Theme.dockShadow.x,
                    y: Theme.dockShadow.y
                )
        } else {
            materialFallback(content)
        }
#else
        materialFallback(content)
#endif
    }

    /// Translucent material dock surface used below iOS 26 (or whenever the build
    /// SDK predates Liquid Glass). Uses only iOS 17 APIs: a low solid fill behind
    /// `.ultraThinMaterial`, a hairline border, and the shared dock shadow.
    /// Inputs:
    ///   - content: the dock content to place on the surface.
    /// Outputs: the content backed by the fallback capsule surface.
    private func materialFallback(_ content: Content) -> some View {
        content
            .background(
                ZStack {
                    Capsule(style: .continuous)
                        .fill(Theme.BG.secondary.opacity(0.55))
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(0.7)
                }
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Theme.CTP.lavender.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(
                color: Theme.dockShadow.color,
                radius: Theme.dockShadow.radius,
                x: Theme.dockShadow.x,
                y: Theme.dockShadow.y
            )
    }
}

#Preview {
    @Previewable @State var tab: DockTab = .nutrition
    ZStack {
        Theme.BG.primary.ignoresSafeArea()
        VStack {
            Spacer()
            FloatingDock(tab: $tab, onSettings: {})
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
    }
    .preferredColorScheme(.dark)
}
