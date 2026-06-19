// PulseTests/SaveAsMealSheetRenderTests.swift
/// Host-render smoke test for `SaveAsMealSheet`: mounts the sheet with multiple
/// items in a real window so its `body` (and the embedded `MealNameStep`) is
/// evaluated. No-crash / coverage test, not a content assertion.
import XCTest
import SwiftUI
@testable import Pulse

@MainActor
final class SaveAsMealSheetRenderTests: XCTestCase {
    /// Builds a placeholder meal item for the preview.
    /// Inputs:
    ///   - name: the item's display name.
    /// Outputs: a `NewMealItem` with placeholder macros.
    private func item(_ name: String) -> NewMealItem {
        NewMealItem(id: UUID(), displayName: name, quantityText: "1 serving",
                    normalizedQuantityValue: 1, normalizedQuantityUnit: "serving",
                    usdaFdcId: nil, usdaDescription: nil, customFoodId: UUID(),
                    calories: 100, proteinG: 5, carbsG: 10, fatG: 2)
    }

    /// Mounts a view in a real key window, lays it out, then tears it down — the
    /// same harness the screen-level render tests use.
    /// Inputs:
    ///   - view: the view to mount and lay out.
    /// Outputs: nothing; fails the test only if `body` traps during evaluation.
    private func render<V: View>(_ view: V) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        window.rootViewController = nil
        window.isHidden = true
    }

    /// Mounts `SaveAsMealSheet` with two items and asserts its body composes.
    func test_renders() {
        render(SaveAsMealSheet(items: [item("Chicken"), item("Rice")], auth: nil) { _ in })
    }
}
