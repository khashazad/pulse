// PulseTests/SwipeActionsRowTests.swift
import XCTest
import SwiftUI
@testable import Pulse

/// Logic-level tests for `SwipeAction` (the value type backing
/// `SwipeActionsRow`). The swipe gesture and rendering are verified manually.
final class SwipeActionsRowTests: XCTestCase {
    func test_swipeAction_storesFieldsAndFiresHandler() {
        var fired = false
        let action = SwipeAction(
            label: "Delete", systemImage: "trash", tint: Theme.CTP.red,
            role: .destructive, handler: { fired = true }
        )
        XCTAssertEqual(action.label, "Delete")
        XCTAssertEqual(action.role, .destructive)
        action.handler()
        XCTAssertTrue(fired)
    }
}
