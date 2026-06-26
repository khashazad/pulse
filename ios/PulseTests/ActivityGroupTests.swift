import XCTest
@testable import Pulse

final class ActivityGroupTests: XCTestCase {
    /// Strength types map to Weights; everything else maps to Cardio.
    func testGroupMapping() {
        XCTAssertEqual(ActivityGroup.of("TraditionalStrengthTraining"), .weights)
        XCTAssertEqual(ActivityGroup.of("FunctionalStrengthTraining"), .weights)
        for t in ["Running", "Cycling", "HighIntensityIntervalTraining", "Yoga", "Other"] {
            XCTAssertEqual(ActivityGroup.of(t), .cardio, "\(t) should be cardio")
        }
    }
}
