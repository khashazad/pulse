/// Unit tests for `WeightFormatter`'s unit conversion and display helpers.
/// Covers kg → lb conversion, lb passthrough, kg ↔ lb round-trip, and the
/// display helpers that format a stored lb value in either unit.
/// Part of the iOS app's formatting test suite.
import XCTest
@testable import Pulse

final class WeightFormatterTests: XCTestCase {

    /// Verifies kg → lb conversion against a known reference.
    func testKgToLbExact() {
        XCTAssertEqual(WeightFormatter.toLb(70.0, from: .kg), 154.32, accuracy: 0.005)
    }

    /// Verifies an lb-source value passes through `toLb` unchanged.
    func testLbPassthrough() {
        XCTAssertEqual(WeightFormatter.toLb(180.5, from: .lb), 180.5, accuracy: 0.001)
    }

    /// Verifies kg → lb → kg round-trips within tolerance.
    func testRoundTrip() {
        let originalKg = 82.7
        let lb = WeightFormatter.toLb(originalKg, from: .kg)
        let backKg = WeightFormatter.fromLb(lb, to: .kg)
        XCTAssertEqual(originalKg, backKg, accuracy: 0.01)
    }

    /// Verifies the lb display format with one decimal place.
    func testDisplayLb() {
        XCTAssertEqual(WeightFormatter.display(lb: 180.5, in: .lb), "180.5 lb")
    }

    /// Verifies an lb value displays correctly when the user chose kg.
    func testDisplayKg() {
        // 154.32 lb -> 70.00 kg -> "70.0 kg"
        XCTAssertEqual(WeightFormatter.display(lb: 154.32, in: .kg), "70.0 kg")
    }
}
