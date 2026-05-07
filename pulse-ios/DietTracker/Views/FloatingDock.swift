import SwiftUI

enum DockTab: Hashable {
    case today, week, date
}

struct FloatingDock: View {
    @Binding var tab: DockTab
    let onPickDate: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            tabButton(.today, system: "circle.fill",    label: "Today")
            tabButton(.week,  system: "chart.bar.fill", label: "Week")
            Button {
                onPickDate()
            } label: {
                tabContents(system: "calendar", label: "Date", isActive: tab == .date)
            }
            .buttonStyle(.plain)
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

    private func tabButton(_ target: DockTab, system: String, label: String) -> some View {
        Button {
            tab = target
        } label: {
            tabContents(system: system, label: label, isActive: tab == target)
        }
        .buttonStyle(.plain)
    }

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
    @Previewable @State var tab: DockTab = .today
    ZStack {
        Theme.BG.primary.ignoresSafeArea()
        VStack {
            Spacer()
            FloatingDock(tab: $tab, onPickDate: {})
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
    }
    .preferredColorScheme(.dark)
}
