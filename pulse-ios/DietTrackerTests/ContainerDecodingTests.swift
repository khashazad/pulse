import XCTest
@testable import DietTracker

final class ContainerDecodingTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            XCTFail("Fixture \(name).json not found in test bundle")
            throw NSError(domain: "fixture", code: 0)
        }
        return try Data(contentsOf: url)
    }

    func testDecodeContainersList() throws {
        let data = try loadFixture("containers")
        let list = try JSONDecoder.dietTrackerDefault().decode(ContainersList.self, from: data)
        XCTAssertEqual(list.containers.count, 2)
        XCTAssertEqual(list.containers[0].name, "Big Pyrex")
        XCTAssertEqual(list.containers[0].tareWeightG, 412.0)
        XCTAssertTrue(list.containers[0].hasPhoto)
        XCTAssertFalse(list.containers[1].hasPhoto)
    }

    func testDecodeSingleContainer() throws {
        let data = try loadFixture("container")
        let c = try JSONDecoder.dietTrackerDefault().decode(Container.self, from: data)
        XCTAssertEqual(c.id.uuidString, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(c.normalizedName, "big pyrex")
    }
}
