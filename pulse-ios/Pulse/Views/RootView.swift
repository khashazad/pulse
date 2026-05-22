/// Top-level app screen.
/// Owns the four-tab `FloatingDock` selection, one `NavigationStack` per tab,
/// the settings sheet, and the sign-in sheet gating. Also bootstraps `AuthSession`
/// once on appear.
import SwiftUI

/// Root container view. Switches between the four top-level tabs and surfaces the
/// settings + login sheets at app scope.
struct RootView: View {
    @Environment(AuthSession.self) private var auth

    @State private var tab: DockTab = .intake
    @State private var intakePath = NavigationPath()
    @State private var mealsPath = NavigationPath()
    @State private var prepPath = NavigationPath()
    @State private var measuresPath = NavigationPath()
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.BG.primary.ignoresSafeArea()

            Group {
                switch tab {
                case .intake:
                    NavigationStack(path: $intakePath) {
                        LogView(onOpenDate: { picked in
                            intakePath.append(picked)
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
                case .measures:
                    NavigationStack(path: $measuresPath) {
                        MeasuresTabRootView()
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

    /// Whether the floating dock should be visible. Hidden when the current tab has
    /// pushed at least one screen onto its navigation stack so the dock doesn't overlap
    /// detail screens.
    /// Outputs: `true` when the active tab's nav stack is at its root.
    private var dockVisible: Bool {
        switch tab {
        case .intake: intakePath.isEmpty
        case .meals:  mealsPath.isEmpty
        case .prep:   prepPath.isEmpty
        case .measures: measuresPath.isEmpty
        }
    }

    /// Shared toolbar item: gear icon that presents the settings sheet.
    /// Outputs: composed toolbar content.
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
