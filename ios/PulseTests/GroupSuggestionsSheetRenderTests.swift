// PulseTests/GroupSuggestionsSheetRenderTests.swift
/// Host-render smoke test for `GroupSuggestionsSheet`: mounts the sheet with
/// multiple clusters in a real window so its `body` is evaluated. No-crash /
/// coverage test, not a content assertion.
import XCTest
import SwiftUI
@testable import Pulse

@MainActor
final class GroupSuggestionsSheetRenderTests: XCTestCase {
    /// Builds a minimal `CustomFood` for cluster fixtures.
    /// Inputs:
    ///   - name: the food's display name.
    ///   - id: the UUID string used as the food's stable identifier.
    /// Outputs: a `CustomFood` with the given name/id and placeholder macros.
    private func food(_ name: String, _ id: String) -> CustomFood {
        CustomFood(id: UUID(uuidString: id)!, name: name, basis: .perUnit,
                   servingSize: 1, servingSizeUnit: "x", calories: 1,
                   proteinG: 0, carbsG: 0, fatG: 0, foodId: nil, portionLabel: nil)
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

    /// Verifies the sheet composes its `body` without trapping when handed
    /// multiple duplicate clusters (each row renders a suggested name + members).
    func test_rendersAllClusters() {
        let clusters: [[CustomFood]] = [
            [food("small apple", "aaaa1111-0000-0000-0000-000000000001"),
             food("large apple", "aaaa1111-0000-0000-0000-000000000002")],
            [food("mini banana", "bbbb1111-0000-0000-0000-000000000001"),
             food("big banana", "bbbb1111-0000-0000-0000-000000000002")]
        ]
        render(GroupSuggestionsSheet(clusters: clusters) { _ in })
    }
}
