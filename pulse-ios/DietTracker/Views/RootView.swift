import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings

    @State private var tab: DockTab = .today
    @State private var path = NavigationPath()
    @State private var showSettings = false
    @State private var showDatePicker = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                .navigationDestination(for: Date.self) { date in
                    DayMacroView(date: date)
                }
        }
        .overlay(alignment: .bottom) {
            if path.isEmpty {
                FloatingDock(tab: $tab, onPickDate: { showDatePicker = true })
            }
        }
        .sheet(isPresented: $showDatePicker) {
            DatePickerSheet { picked in
                path.append(picked)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(requireConfig: false)
        }
        // Auto-present settings if not configured
        .sheet(isPresented: .constant(!settings.isConfigured && !showSettings)) {
            SettingsView(requireConfig: true)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .today: DayMacroView(date: Date())
        case .week:  WeekView()
        case .prep:  PrepView()
        }
    }
}
