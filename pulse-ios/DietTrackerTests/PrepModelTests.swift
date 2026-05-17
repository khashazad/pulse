/// Unit tests for `PrepModel`, the view model behind the meal-prep screen.
/// Verifies net-weight math (`total - tare`) and per-portion division,
/// negative-net clamping, nil propagation when total weight is missing,
/// the minimum-portions=1 contract, and that clearing the selected
/// container zeroes the tare (regression for the deleted-container drift).
/// Part of the iOS app's view-model test suite.
import XCTest
@testable import DietTracker

final class PrepModelTests: XCTestCase {

    /// Builds a `Container` fixture with the requested tare weight.
    /// Inputs:
    ///   - tare: tare weight in grams.
    ///   - name: display name, defaulting to "X".
    /// Outputs: a fully formed `Container` suitable for `PrepModel` selection.
    private func mkContainer(tare: Double, name: String = "X") -> Container {
        Container(
            id: UUID(),
            userKey: "khash",
            name: name,
            normalizedName: name.lowercased(),
            tareWeightG: tare,
            hasPhoto: false,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// Verifies net = total - tare with portions=1 makes net == perPortion.
    func testNetEqualsTotalMinusTare() {
        let m = PrepModel()
        m.selectedContainer = mkContainer(tare: 412)
        m.totalGrams = 1450
        m.portions = 1
        XCTAssertEqual(m.netGrams ?? 0, 1038, accuracy: 0.001)
        XCTAssertEqual(m.perPortionGrams ?? 0, 1038, accuracy: 0.001)
    }

    /// Verifies perPortion = net / portions for portions > 1.
    func testPortionsDivision() {
        let m = PrepModel()
        m.selectedContainer = mkContainer(tare: 412)
        m.totalGrams = 1450
        m.portions = 5
        XCTAssertEqual(m.netGrams ?? 0, 1038, accuracy: 0.001)
        XCTAssertEqual(m.perPortionGrams ?? 0, 207.6, accuracy: 0.001)
    }

    /// Verifies a tare greater than the total clamps net (and per-portion)
    /// to zero instead of going negative.
    func testNegativeNetClampsToZero() {
        let m = PrepModel()
        m.selectedContainer = mkContainer(tare: 1000)
        m.totalGrams = 500
        m.portions = 2
        XCTAssertEqual(m.netGrams, 0)
        XCTAssertEqual(m.perPortionGrams, 0)
    }

    /// Verifies a nil total propagates nil net and perPortion (no defaulting).
    func testNoTotalReturnsNil() {
        let m = PrepModel()
        m.selectedContainer = mkContainer(tare: 412)
        m.totalGrams = nil
        XCTAssertNil(m.netGrams)
        XCTAssertNil(m.perPortionGrams)
    }

    /// Verifies portions = 0 is treated as 1 for the per-portion division.
    func testPortionsAtLeastOne() {
        let m = PrepModel()
        m.selectedContainer = mkContainer(tare: 100)
        m.totalGrams = 300
        m.portions = 0
        XCTAssertEqual(m.perPortionGrams, 200)
    }

    /// Verifies that with no container selected, tare is treated as 0 and
    /// net equals total.
    func testNoSelectionMeansZeroTare() {
        // Regression for the deleted-container drift: with no selection,
        // tare is 0, so net == total. Previously a stale tareWeightG could
        // remain even after the selection was cleared.
        let m = PrepModel()
        m.selectedContainer = nil
        m.totalGrams = 500
        XCTAssertEqual(m.netGrams, 500)
    }

    /// Verifies that clearing the selected container after a non-zero tare
    /// was applied resets the tare back to 0 (regression test).
    func testClearingSelectionAlsoZeroesTare() {
        let m = PrepModel()
        m.selectedContainer = mkContainer(tare: 412)
        m.totalGrams = 1000
        XCTAssertEqual(m.netGrams, 588)
        m.selectedContainer = nil
        XCTAssertEqual(m.netGrams, 1000, "tare must drop to 0 when selection clears")
    }
}
