import SwiftUI

enum DockTab {
    case today, week, prep
}

struct FloatingDock: View {
    @Binding var tab: DockTab
    let onPickDate: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            button(label: "Today", system: "circle.fill", active: tab == .today) {
                tab = .today
            }
            button(label: "Week", system: "chart.bar.fill", active: tab == .week) {
                tab = .week
            }
            button(label: "Prep", system: "cube.box.fill", active: tab == .prep) {
                tab = .prep
            }
            button(label: "Date", system: "calendar", active: false, action: onPickDate)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .padding(.bottom, 12)
    }

    private func button(label: String, system: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: system).font(.system(size: 14))
                Text(label).font(.caption2)
            }
            .foregroundStyle(active ? Color.accentColor : .secondary)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    @Previewable @State var tab: DockTab = .today
    return ZStack(alignment: .bottom) {
        Color.gray.opacity(0.1).ignoresSafeArea()
        FloatingDock(tab: $tab, onPickDate: {})
    }
}
