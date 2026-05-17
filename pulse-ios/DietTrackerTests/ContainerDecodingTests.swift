/// Unit tests for `Container` / `ContainersList` JSON decoding.
/// Confirms the shared `dietTrackerDefault()` decoder maps the server's
/// snake_case `containers` payloads to the Swift camelCase model and that
/// `normalizedName` round-trips on a single-container response.
/// Part of the iOS app's decoding test suite.
import XCTest
@testable import DietTracker

final class ContainerDecodingTests: XCTestCase {

    /// Loads a JSON fixture from the test bundle.
    /// Inputs:
    ///   - name: fixture file base name (no extension).
    /// Outputs: raw bytes of `<name>.json`.
    /// Exceptions: throws if the fixture is missing or unreadable.
    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            XCTFail("Fixture \(name).json not found in test bundle")
            throw NSError(domain: "fixture", code: 0)
        }
        return try Data(contentsOf: url)
    }

    /// Verifies a `containers` list fixture decodes with the right element
    /// count, name, tare, and `hasPhoto` flag per entry.
    func testDecodeContainersList() throws {
        let data = try loadFixture("containers")
        let list = try JSONDecoder.dietTrackerDefault().decode(ContainersList.self, from: data)
        XCTAssertEqual(list.containers.count, 2)
        XCTAssertEqual(list.containers[0].name, "Big Pyrex")
        XCTAssertEqual(list.containers[0].tareWeightG, 412.0)
        XCTAssertTrue(list.containers[0].hasPhoto)
        XCTAssertFalse(list.containers[1].hasPhoto)
    }

    /// Verifies a single `container` fixture decodes with the right id and
    /// `normalizedName`.
    func testDecodeSingleContainer() throws {
        let data = try loadFixture("container")
        let c = try JSONDecoder.dietTrackerDefault().decode(Container.self, from: data)
        XCTAssertEqual(c.id.uuidString, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(c.normalizedName, "big pyrex")
    }
}
