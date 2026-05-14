import XCTest
@testable import DietTracker

final class WeightFormatterTests: XCTestCase {

    func testKgToLbExact() {
        XCTAssertEqual(WeightFormatter.toLb(70.0, from: .kg), 154.32, accuracy: 0.005)
    }

    func testLbPassthrough() {
        XCTAssertEqual(WeightFormatter.toLb(180.5, from: .lb), 180.5, accuracy: 0.001)
    }

    func testRoundTrip() {
        let originalKg = 82.7
        let lb = WeightFormatter.toLb(originalKg, from: .kg)
        let backKg = WeightFormatter.fromLb(lb, to: .kg)
        XCTAssertEqual(originalKg, backKg, accuracy: 0.01)
    }

    func testDisplayLb() {
        XCTAssertEqual(WeightFormatter.display(lb: 180.5, in: .lb), "180.5 lb")
    }

    func testDisplayKg() {
        // 154.32 lb -> 70.00 kg -> "70.0 kg"
        XCTAssertEqual(WeightFormatter.display(lb: 154.32, in: .kg), "70.0 kg")
    }
}
