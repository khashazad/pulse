/// Unit tests for authenticated async image loading.
/// Verifies header-only credential changes are visible to SwiftUI task
/// identity, and that the view performs its request through the injected
/// `URLSession` (so tests can intercept it with `StubURLProtocol`).
import XCTest
import SwiftUI
import UIKit
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

    /// Verifies the view loads through the injected `URLSession`: when hosted
    /// in a window, its `.task` issues the authorized request against the
    /// stubbed session (carrying the Authorization header) rather than
    /// `URLSession.shared`.
    /// Inputs: none.
    /// Outputs: Void; fails if the stub responder is never invoked.
    /// Throws: none.
    @MainActor
    func testLoadUsesInjectedURLSession() async {
        let hit = expectation(description: "stub session received the image request")
        hit.assertForOverFulfill = false
        let png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let stub = StubURLProtocol.makeSession { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            hit.fulfill()
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, png)
        }
        defer { stub.invalidate() }

        var request = URLRequest(url: URL(string: "https://example.test/images/photo.jpg")!)
        request.setValue("Bearer tok", forHTTPHeaderField: "Authorization")
        let view = AuthorizedAsyncImage(request: request, urlSession: stub.session) { image in
            image
        } placeholder: {
            ProgressView()
        }

        // SwiftUI only evaluates `body` (and runs `.task`) when the view is
        // attached to a visible window.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        await fulfillment(of: [hit], timeout: 3.0)
        window.rootViewController = nil
        window.isHidden = true
    }
}
