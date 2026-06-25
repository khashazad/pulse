/// Nutrition tab host: places the three former top-level nutrition tabs (Intake,
/// Food, Prep) behind a segmented sub-segment control, replacing the old separate
/// dock entries. Instantiates each child view with the same arguments `RootView`
/// previously passed them directly.
import SwiftUI

/// Hosts the three nutrition surfaces (Intake / Food / Prep) behind a top
/// sub-segment, replacing the former separate dock tabs for Intake, Food, and Prep.
struct NutritionTabView: View {

    /// The three sections selectable within the Nutrition tab.
    enum Section: String, CaseIterable, Identifiable {
        case intake = "Intake"
        case food   = "Food"
        case prep   = "Prep"

        /// Stable identity for `ForEach` iteration.
        /// - Returns: The raw string value of the case.
        var id: String { rawValue }
    }

    // MARK: - Inputs

    /// The app's authenticated session; passed directly to `FoodTabView`.
    let auth: AuthSession
    /// Loaded meals model. `nil` while `RootView` is still bootstrapping;
    /// the Food section shows a spinner until this is populated.
    let mealsModel: MealsModel?
    /// Loaded custom-foods model. `nil` while `RootView` is still bootstrapping;
    /// the Food section shows a spinner until this is populated.
    let foodsModel: FoodsModel?
    /// Called with a `Date` when the user picks a specific day to drill into from the Intake section.
    let onOpenDate: (Date) -> Void
    /// Called with a `MealSummary` when the user taps a saved meal in the Food section.
    let onOpenMeal: (MealSummary) -> Void
    /// Called with a `CustomFood` when the user taps a saved custom food in the Food section.
    let onOpenFood: (CustomFood) -> Void
    /// Called with a portion `UUID` when the user taps a portion in the Food section.
    /// The caller (`RootView`) resolves the UUID to a `CustomFood` and pushes the route.
    let onOpenPortion: (UUID) -> Void

    @State private var section: Section = .intake

    // MARK: - Init

    /// Initializes the nutrition tab view.
    /// - Parameters:
    ///   - auth: The app's authenticated session; forwarded to `FoodTabView`.
    ///   - mealsModel: Loaded meals model, or `nil` while bootstrapping.
    ///   - foodsModel: Loaded custom-foods model, or `nil` while bootstrapping.
    ///   - onOpenDate: Navigation callback from `LogView` when the user picks a date.
    ///   - onOpenMeal: Navigation callback from `FoodTabView` when the user taps a meal.
    ///   - onOpenFood: Navigation callback from `FoodTabView` when the user taps a custom food.
    ///   - onOpenPortion: Navigation callback from `FoodTabView` when the user taps a portion.
    init(
        auth: AuthSession,
        mealsModel: MealsModel?,
        foodsModel: FoodsModel?,
        onOpenDate: @escaping (Date) -> Void,
        onOpenMeal: @escaping (MealSummary) -> Void,
        onOpenFood: @escaping (CustomFood) -> Void,
        onOpenPortion: @escaping (UUID) -> Void
    ) {
        self.auth = auth
        self.mealsModel = mealsModel
        self.foodsModel = foodsModel
        self.onOpenDate = onOpenDate
        self.onOpenMeal = onOpenMeal
        self.onOpenFood = onOpenFood
        self.onOpenPortion = onOpenPortion
    }

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            VStack(spacing: 0) {
                sectionPicker
                activeSection
            }
        }
        .navigationTitle("Nutrition")
    }

    // MARK: - Private helpers

    /// Segmented control that switches between Intake, Food, and Prep.
    /// - Returns: A styled `Picker` pinned above the active section content.
    private var sectionPicker: some View {
        Picker("Section", selection: $section) {
            ForEach(Section.allCases) { s in
                Text(s.rawValue).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// The content area for the currently selected sub-section.
    /// Renders `LogView`, `FoodTabView` (or a spinner), or `PrepView`.
    /// - Returns: A view matching the current `section` selection.
    @ViewBuilder private var activeSection: some View {
        switch section {
        case .intake:
            LogView(onOpenDate: onOpenDate)
        case .food:
            if let mealsModel, let foodsModel {
                FoodTabView(
                    mealsModel: mealsModel,
                    foodsModel: foodsModel,
                    onOpenMeal: onOpenMeal,
                    onOpenFood: onOpenFood,
                    onOpenPortion: onOpenPortion,
                    auth: auth
                )
            } else {
                ProgressView()
                    .tint(Theme.CTP.mauve)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .prep:
            PrepView()
        }
    }
}
