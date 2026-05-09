import SwiftUI

struct RootView: View {
    @Environment(AuthSession.self) private var auth

    @State private var tab: DockTab = .log
    @State private var logPath = NavigationPath()
    @State private var mealsPath = NavigationPath()
    @State private var prepPath = NavigationPath()
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.BG.primary.ignoresSafeArea()

            Group {
                switch tab {
                case .log:
                    NavigationStack(path: $logPath) {
                        LogView(onOpenDate: { picked in
                            logPath.append(picked)
                        })
                        .toolbar { settingsButton }
                        .navigationDestination(for: Date.self) { date in
                            DayMacroView(date: date)
                                .toolbar { settingsButton }
                        }
                    }
                case .meals:
                    NavigationStack(path: $mealsPath) {
                        MealsView(onOpen: { summary in
                            mealsPath.append(summary)
                        })
                        .toolbar { settingsButton }
                        .navigationDestination(for: MealSummary.self) { summary in
                            MealDetailView(summary: summary)
                                .toolbar { settingsButton }
                        }
                    }
                case .prep:
                    NavigationStack(path: $prepPath) {
                        PrepView()
                            .toolbar { settingsButton }
                    }
                }
            }

            if dockVisible {
                FloatingDock(tab: $tab)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 4)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: .constant(!auth.isSignedIn && !showSettings)) {
            LoginView()
                .interactiveDismissDisabled()
        }
        .task {
            await auth.bootstrap()
        }
    }

    private var dockVisible: Bool {
        switch tab {
        case .log:   logPath.isEmpty
        case .meals: mealsPath.isEmpty
        case .prep:  prepPath.isEmpty
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
