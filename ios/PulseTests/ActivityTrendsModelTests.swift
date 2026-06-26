import XCTest
@testable import Pulse

final class ActivityTrendsModelTests: XCTestCase {
    /// Verifies `deltaText(_:)` formats a positive percentage delta with a leading `+` sign.
    func testDeltaTextPositive() {
        let d = MetricDelta(current: 4, previous: 3, pct: 0.3333)
        XCTAssertEqual(ActivityTrendsModel.deltaText(d), "+33%")
    }

    /// Verifies `deltaText(_:)` formats a negative percentage delta with a leading `-` sign.
    func testDeltaTextNegative() {
        let d = MetricDelta(current: 80, previous: 100, pct: -0.2)
        XCTAssertEqual(ActivityTrendsModel.deltaText(d), "-20%")
    }

    /// Verifies `deltaText(_:)` returns `"new"` when the percentage delta is nil (no prior baseline).
    func testDeltaTextNilBaseline() {
        let d = MetricDelta(current: 100, previous: 0, pct: nil)
        XCTAssertEqual(ActivityTrendsModel.deltaText(d), "new")
    }
}
