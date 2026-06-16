/// Navigation routes pushed within the Food tab's stack: a saved meal or a saved
/// custom food. `Hashable` so it drives `RootView`'s `navigationDestination(for:)`.
/// Lives in its own file (not buried in `RootView`) so the tab's navigation
/// contract is discoverable alongside the other Food-tab types.
import Foundation

/// One destination reachable from the Food tab's list.
enum FoodRoute: Hashable {
    /// A saved meal template (opens `MealDetailView`).
    case meal(MealSummary)
    /// A saved custom food (opens `CustomFoodDetailView`).
    case food(CustomFood)
}
