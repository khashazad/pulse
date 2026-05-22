/// Unit tests for authenticated async image request identity.
/// Verifies header-only credential changes are visible to SwiftUI task identity.
import XCTest
@testable import Pulse

final class AuthorizedAsyncImageTests: XCTestCase {

    /// Verifies two requests for the same URL produce different identities
    /// when only the Authorization header changes.
    /// Inputs: none.
    /// Outputs: Void; asserts identity inequality.
    /// Throws: none.
    func testRequestIdentityChangesWhenAuthorizationHeaderChanges() {
        let url = URL(string: "https://example.test/images/container.jpg")!
        var first = URLRequest(url: url)
        first.setValue("Bearer old-token", forHTTPHeaderField: "Authorization")
        var second = URLRequest(url: url)
        second.setValue("Bearer new-token", forHTTPHeaderField: "Authorization")

        XCTAssertNotEqual(
            AuthorizedAsyncImageRequestIdentity(first),
            AuthorizedAsyncImageRequestIdentity(second)
        )
    }
}
