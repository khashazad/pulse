/// Top-level app screen.
/// Owns the three-tab `FloatingDock` selection, one `NavigationStack` per tab,
/// the settings sheet, and the sign-in sheet gating. Also bootstraps `AuthSession`
/// once on appear.
import SwiftUI

/// Root container view. Switches between the three top-level tabs and surfaces the
/// settings + login sheets at app scope.
struct RootView: View {
    @Environment(AuthSession.self) private var auth

    @State private var tab: DockTab = .nutrition
    @State private var nutritionSection: NutritionTabView.Section = .intake
    @State private var nutritionPath = NavigationPath()
    @State private var activityPath = NavigationPath()
    @State private var measuresPath = NavigationPath()
    @State private var showSettings = false
    @State private var mealsModel: MealsModel?
    @State private var foodsModel: FoodsModel?

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.BG.primary.ignoresSafeArea()

            Group {
                switch tab {
                case .nutrition:
                    NavigationStack(path: $nutritionPath) {
                        NutritionTabView(
                            section: $nutritionSection,
                            auth: auth,
                            mealsModel: mealsModel,
                            foodsModel: foodsModel,
                            onOpenDate: { picked in
                                nutritionPath.append(picked)
                            },
                            onOpenMeal: { summary in
                                nutritionPath.append(FoodRoute.meal(summary))
                            },
                            onOpenFood: { food in
                                nutritionPath.append(FoodRoute.food(food))
                            },
                            onOpenPortion: { portionId in
                                if let cf = foodsModel?.customFood(for: portionId) {
                                    nutritionPath.append(FoodRoute.food(cf))
                                }
                            }
                        )
                        .navigationDestination(for: Date.self) { date in
                            DayMacroView(date: date)
                        }
                        .navigationDestination(for: FoodRoute.self) { route in
                            switch route {
                            case .meal(let summary):
                                MealDetailView(
                                    summary: summary,
                                    onMutated: { Task { await mealsModel?.load() } },
                                    onDeleted: { id in mealsModel?.applyRemoval(id: id) }
                                )
                            case .food(let food):
                                CustomFoodDetailView(
                                    food: food,
                                    onRenamed: { updated in foodsModel?.applyRenamedStandalone(updated) },
                                    onDeleted: { id in foodsModel?.applyRemovedStandalone(id: id) }
                                )
                            }
                        }
                    }
                case .activity:
                    NavigationStack(path: $activityPath) {
                        ActivityTabView(
                            auth: auth,
                            onOpenWorkout: { id in activityPath.append(ActivityRoute.workout(id)) },
                            onOpenTrends: { activityPath.append(ActivityRoute.trends) }
                        )
                        .navigationDestination(for: ActivityRoute.self) { route in
                            switch route {
                            case let .workout(id):
                                WorkoutDetailView(id: id, auth: auth)
                            case .trends:
                                ActivityTrendsView(
                                    auth: auth,
                                    onManageTypes: { activityPath.append(ActivityRoute.types) },
                                    onOpenMonth: { activityPath.append(ActivityRoute.month($0)) },
                                    onOpenWeek: { activityPath.append(ActivityRoute.week($0)) }
                                )
                            case .types:
                                ActivityTypesView(auth: auth)
                            case let .month(anchor):
                                MonthTrendsView(
                                    anchor: anchor,
                                    onOpenWeek: { activityPath.append(ActivityRoute.week($0)) }
                                )
                            case let .week(anchor):
                                WeekTrendsView(
                                    anchor: anchor,
                                    onOpenWorkout: { activityPath.append(ActivityRoute.workout($0)) }
                                )
                            }
                        }
                    }
                case .measures:
                    NavigationStack(path: $measuresPath) {
                        MeasuresTabRootView()
                    }
                }
            }

            if dockVisible {
                FloatingDock(tab: $tab, onSettings: { showSettings = true })
                    .padding(.horizontal, 32)
                    // Ride just above the home indicator (TickTick-style) rather
                    // than floating high off the bottom edge.
                    .padding(.bottom, 0)
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
            if mealsModel == nil { mealsModel = MealsModel(auth: auth) }
            if foodsModel == nil { foodsModel = FoodsModel(auth: auth) }
        }
    }

    /// Whether the floating dock should be visible. Hidden when the current tab has
    /// pushed at least one screen onto its navigation stack so the dock does not
    /// overlap detail screens.
    /// - Returns: `true` when the active tab's navigation stack is at its root.
    private var dockVisible: Bool {
        switch tab {
        case .nutrition: nutritionPath.isEmpty
        case .activity:  activityPath.isEmpty
        case .measures:  measuresPath.isEmpty
        }
    }
}
