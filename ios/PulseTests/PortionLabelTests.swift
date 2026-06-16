// PulseTests/PortionLabelTests.swift
import XCTest
@testable import Pulse

final class PortionLabelTests: XCTestCase {
    func test_stripsLeadingFoodName() {
        XCTAssertEqual(PortionLabel.derive(foodName: "Apple", portionName: "medium apple"), "medium")
    }
    func test_stripsTrailingFoodName() {
        XCTAssertEqual(PortionLabel.derive(foodName: "Apple", portionName: "apple per 100g"), "per 100g")
    }
    func test_caseAndWhitespaceInsensitive() {
        XCTAssertEqual(PortionLabel.derive(foodName: "  apple ", portionName: "LARGE Apple"), "LARGE")
    }
    func test_fallbackToOriginalWhenNothingLeft() {
        XCTAssertEqual(PortionLabel.derive(foodName: "Apple", portionName: "apple"), "apple")
    }
    func test_unrelatedNameUnchanged() {
        XCTAssertEqual(PortionLabel.derive(foodName: "Apple", portionName: "banana"), "banana")
    }
}
