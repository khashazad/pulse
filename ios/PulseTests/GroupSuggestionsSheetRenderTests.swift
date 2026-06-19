// PulseTests/GroupSuggestionsSheetRenderTests.swift
/// Host-render smoke test for `GroupSuggestionsSheet`: mounts the sheet with
/// multiple clusters in a real window so its `body` is evaluated. No-crash /
/// coverage test, not a content assertion.
import XCTest
import SwiftUI
@testable import Pulse

@MainActor
final class GroupSuggestionsSheetRenderTests: XCTestCase {
    private func food(_ name: String, _ id: String) -> CustomFood {
        CustomFood(id: UUID(uuidString: id)!, name: name, basis: .perUnit,
                   servingSize: 1, servingSizeUnit: "x", calories: 1,
                   proteinG: 0, carbsG: 0, fatG: 0, foodId: nil, portionLabel: nil)
    }

    func test_rendersAllClusters() {
        let clusters: [[CustomFood]] = [
            [food("small apple", "aaaa1111-0000-0000-0000-000000000001"),
             food("large apple", "aaaa1111-0000-0000-0000-000000000002")],
            [food("mini banana", "bbbb1111-0000-0000-0000-000000000001"),
             food("big banana", "bbbb1111-0000-0000-0000-000000000002")]
        ]
        let view = GroupSuggestionsSheet(clusters: clusters) { _ in }
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: .init(x: 0, y: 0, width: 390, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        XCTAssertNotNil(host.view)
        window.isHidden = true
    }
}
