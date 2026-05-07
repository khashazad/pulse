import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings

    @State private var tab: DockTab = .today
    @State private var todayPath = NavigationPath()
    @State private var weekPath = NavigationPath()
    @State private var showSettings = false
    @State private var showDatePicker = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.BG.primary.ignoresSafeArea()

            Group {
                switch tab {
                case .today:
                    NavigationStack(path: $todayPath) {
                        DayMacroView(date: Date())
                            .toolbar { settingsButton }
                            .navigationDestination(for: Date.self) { date in
                                DayMacroView(date: date)
                                    .toolbar { settingsButton }
                            }
                    }
                case .week:
                    NavigationStack(path: $weekPath) {
                        WeekView()
                            .toolbar { settingsButton }
                    }
                case .date:
                    Color.clear.onAppear { tab = .today }
                }
            }

            if dockVisible {
                FloatingDock(
                    tab: $tab,
                    onPickDate: { showDatePicker = true }
                )
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
            }
        }
        .sheet(isPresented: $showDatePicker) {
            DatePickerSheet { picked in
                tab = .today
                todayPath.append(picked)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(requireConfig: false)
        }
        .sheet(isPresented: .constant(!settings.isConfigured && !showSettings)) {
            SettingsView(requireConfig: true)
        }
    }

    private var dockVisible: Bool {
        switch tab {
        case .today: todayPath.isEmpty
        case .week:  weekPath.isEmpty
        case .date:  true
        }
    }

    @ToolbarContentBuilder
    private var settingsButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(Theme.CTP.mauve)
            }
        }
    }
}
