/// Unit tests for `KeychainStore` (the thin generic-password wrapper used
/// to persist the session token). Covers write/read round-trip, overwrite
/// semantics, deletion, and the no-error contract for reading or deleting
/// a missing item.
/// Part of the iOS app's auth-layer test suite.
import XCTest
@testable import Pulse

final class KeychainStoreTests: XCTestCase {
    private let service = "com.pulseapp.pulse.test"
    private let account = "kc-test-\(UUID().uuidString)"

    /// Removes the test keychain entry after each test.
    override func tearDown() {
        _ = KeychainStore.delete(service: service, account: account)
        super.tearDown()
    }

    /// Verifies a written value can be read back unchanged.
    func testWriteThenReadRoundTrip() {
        XCTAssertTrue(KeychainStore.write("hello", service: service, account: account))
        XCTAssertEqual(KeychainStore.read(service: service, account: account), "hello")
    }

    /// Verifies a second write to the same slot overwrites the first.
    func testWriteOverwrites() {
        _ = KeychainStore.write("a", service: service, account: account)
        _ = KeychainStore.write("b", service: service, account: account)
        XCTAssertEqual(KeychainStore.read(service: service, account: account), "b")
    }

    /// Verifies `delete` removes a previously stored value.
    func testDeleteRemovesValue() {
        _ = KeychainStore.write("x", service: service, account: account)
        XCTAssertTrue(KeychainStore.delete(service: service, account: account))
        XCTAssertNil(KeychainStore.read(service: service, account: account))
    }

    /// Verifies deleting a never-stored item is idempotent (returns true).
    func testDeleteOfMissingItemReturnsTrue() {
        XCTAssertTrue(KeychainStore.delete(service: service, account: "nope-\(UUID().uuidString)"))
    }

    /// Verifies reading a missing key returns nil rather than throwing.
    func testReadOfMissingItemReturnsNil() {
        XCTAssertNil(KeychainStore.read(service: service, account: "nope-\(UUID().uuidString)"))
    }
}
