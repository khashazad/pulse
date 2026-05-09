import XCTest
@testable import DietTracker

final class PrepModelTests: XCTestCase {

    func testNetEqualsTotalMinusTare() {
        let m = PrepModel()
        m.tareWeightG = 412
        m.totalGrams = 1450
        m.portions = 1
        XCTAssertEqual(m.netGrams ?? 0, 1038, accuracy: 0.001)
        XCTAssertEqual(m.perPortionGrams ?? 0, 1038, accuracy: 0.001)
    }

    func testPortionsDivision() {
        let m = PrepModel()
        m.tareWeightG = 412
        m.totalGrams = 1450
        m.portions = 5
        XCTAssertEqual(m.netGrams ?? 0, 1038, accuracy: 0.001)
        XCTAssertEqual(m.perPortionGrams ?? 0, 207.6, accuracy: 0.001)
    }

    func testNegativeNetClampsToZero() {
        let m = PrepModel()
        m.tareWeightG = 1000
        m.totalGrams = 500
        m.portions = 2
        XCTAssertEqual(m.netGrams, 0)
        XCTAssertEqual(m.perPortionGrams, 0)
    }

    func testNoTotalReturnsNil() {
        let m = PrepModel()
        m.tareWeightG = 412
        m.totalGrams = nil
        XCTAssertNil(m.netGrams)
        XCTAssertNil(m.perPortionGrams)
    }

    func testPortionsAtLeastOne() {
        let m = PrepModel()
        m.tareWeightG = 100
        m.totalGrams = 300
        m.portions = 0
        XCTAssertEqual(m.perPortionGrams, 200)
    }
}
