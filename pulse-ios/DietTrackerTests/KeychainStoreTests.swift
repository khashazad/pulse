import XCTest
@testable import DietTracker

final class KeychainStoreTests: XCTestCase {
    private let service = "com.khxsh.diettracker.test"
    private let account = "kc-test-\(UUID().uuidString)"

    override func tearDown() {
        _ = KeychainStore.delete(service: service, account: account)
        super.tearDown()
    }

    func testWriteThenReadRoundTrip() {
        XCTAssertTrue(KeychainStore.write("hello", service: service, account: account))
        XCTAssertEqual(KeychainStore.read(service: service, account: account), "hello")
    }

    func testWriteOverwrites() {
        _ = KeychainStore.write("a", service: service, account: account)
        _ = KeychainStore.write("b", service: service, account: account)
        XCTAssertEqual(KeychainStore.read(service: service, account: account), "b")
    }

    func testDeleteRemovesValue() {
        _ = KeychainStore.write("x", service: service, account: account)
        XCTAssertTrue(KeychainStore.delete(service: service, account: account))
        XCTAssertNil(KeychainStore.read(service: service, account: account))
    }

    func testDeleteOfMissingItemReturnsTrue() {
        XCTAssertTrue(KeychainStore.delete(service: service, account: "nope-\(UUID().uuidString)"))
    }

    func testReadOfMissingItemReturnsNil() {
        XCTAssertNil(KeychainStore.read(service: service, account: "nope-\(UUID().uuidString)"))
    }
}
