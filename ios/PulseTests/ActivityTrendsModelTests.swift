import XCTest
@testable import Pulse

final class ActivityTrendsModelTests: XCTestCase {
    func testDeltaTextPositive() {
        let d = MetricDelta(current: 4, previous: 3, pct: 0.3333)
        XCTAssertEqual(ActivityTrendsModel.deltaText(d), "+33%")
    }

    func testDeltaTextNegative() {
        let d = MetricDelta(current: 80, previous: 100, pct: -0.2)
        XCTAssertEqual(ActivityTrendsModel.deltaText(d), "-20%")
    }

    func testDeltaTextNilBaseline() {
        let d = MetricDelta(current: 100, previous: 0, pct: nil)
        XCTAssertEqual(ActivityTrendsModel.deltaText(d), "new")
    }
}
