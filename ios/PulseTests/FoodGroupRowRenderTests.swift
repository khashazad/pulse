// PulseTests/FoodGroupRowRenderTests.swift
/// Host-render smoke tests for `FoodGroupRow`: each variant is mounted in a real
/// key window (SwiftUI only evaluates `body` when attached to a visible window),
/// laid out, and torn down. These assert the row's `body` composes without
/// trapping across collapsed, expanded, and single-portion shapes — they are
/// coverage/no-crash tests, not content assertions.
import XCTest
import SwiftUI
@testable import Pulse

@MainActor
final class FoodGroupRowRenderTests: XCTestCase {
    /// The two-portion "Apple" food matching `foods.json` (default = the "medium"
    /// portion id), decoded through the wire decoder so it exercises the real
    /// CodingKeys path.
    /// Outputs: a `Food` with two portions and a default pointing at the first.
    private func appleFood() -> Food {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Apple", "notes": null,
          "default_portion_id": "33333333-3333-3333-3333-333333333333",
          "aliases": ["apple", "apples"],
          "portions": [
            { "custom_food_id": "33333333-3333-3333-3333-333333333333", "label": "medium",
              "basis": "per_unit", "serving_size": 1.0, "serving_size_unit": "apple",
              "calories": 95, "protein_g": 0.5, "carbs_g": 25.0, "fat_g": 0.3 },
            { "custom_food_id": "44444444-4444-4444-4444-444444444444", "label": "per 100g",
              "basis": "per_100g", "serving_size": null, "serving_size_unit": null,
              "calories": 52, "protein_g": 0.3, "carbs_g": 14.0, "fat_g": 0.2 }
          ]
        }
        """
        return try! JSONDecoder.pulseDefault().decode(Food.self, from: json.data(using: .utf8)!)
    }

    /// A single-portion food (no explicit default) to exercise the "1 portion"
    /// singular path and the first-portion representative fallback.
    /// Outputs: a `Food` with exactly one portion.
    private func singlePortionFood() -> Food {
        let json = """
        {
          "id": "55555555-5555-5555-5555-555555555555",
          "name": "Banana", "notes": null, "default_portion_id": null,
          "aliases": [],
          "portions": [
            { "custom_food_id": "66666666-6666-6666-6666-666666666666", "label": null,
              "basis": "per_unit", "serving_size": 1.0, "serving_size_unit": "banana",
              "calories": 105, "protein_g": 1.3, "carbs_g": 27.0, "fat_g": 0.4 }
          ]
        }
        """
        return try! JSONDecoder.pulseDefault().decode(Food.self, from: json.data(using: .utf8)!)
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

    func test_render_collapsed() {
        render(FoodGroupRow(food: appleFood(), isExpanded: false,
                            onToggle: {}, onSelectPortion: { _ in }))
    }

    func test_render_expanded() {
        render(FoodGroupRow(food: appleFood(), isExpanded: true,
                            onToggle: {}, onSelectPortion: { _ in }))
    }

    func test_render_singlePortion() {
        render(FoodGroupRow(food: singlePortionFood(), isExpanded: false,
                            onToggle: {}, onSelectPortion: { _ in }))
        render(FoodGroupRow(food: singlePortionFood(), isExpanded: true,
                            onToggle: {}, onSelectPortion: { _ in }))
    }
}
