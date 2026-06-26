/// Navigation destinations pushed within the Activity tab's `NavigationStack`.
/// `Hashable` so it drives `RootView`'s `navigationDestination(for:)`.
/// Lives in its own file (parallel to `FoodRoute`) so the Activity tab's
/// navigation contract is discoverable alongside the other tab-route types.
import Foundation

/// One destination reachable from the Activity tab.
enum ActivityRoute: Hashable {
    /// A single workout detail screen, identified by the workout's UUID.
    case workout(UUID)
    /// The activity trends screen (week / month / year breakdowns).
    case trends
}
