/// Bottom floating-dock tab bar used by `RootView`.
/// Defines the four top-level tabs (`DockTab`) and renders them as a capsule-shaped
/// pill of glyph + label buttons that drive the binding back to the parent.
import SwiftUI

/// Identifies one of the four top-level tabs hosted by `RootView`.
enum DockTab: Hashable {
    case intake, meals, prep, measures
}

/// Floating capsule tab bar shown at the bottom of `RootView`.
/// Renders four `tabButton`s and writes the selected tab back through the `tab` binding.
struct FloatingDock: View {
    @Binding var tab: DockTab

    var body: some View {
        HStack(spacing: 4) {
            tabButton(.intake, system: "circle.fill",  label: "Intake")
            tabButton(.meals, system: "fork.knife",   label: "Meals")
            tabButton(.prep,  system: "cube.box.fill", label: "Prep")
            tabButton(.measures, system: "figure.arms.open", label: "Measures")
        }
        .padding(6)
        .background(
            ZStack {
                Capsule(style: .continuous)
                    .fill(Theme.BG.secondary.opacity(0.72))
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.6)
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

#Preview {
    @Previewable @State var tab: DockTab = .intake
    ZStack {
        Theme.BG.primary.ignoresSafeArea()
        VStack {
            Spacer()
            FloatingDock(tab: $tab)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
    }
    .preferredColorScheme(.dark)
}
