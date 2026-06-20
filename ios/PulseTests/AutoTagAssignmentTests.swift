/// Unit tests for `AutoTagAssignment.assign`, the pure ordering rule behind
/// auto-tagging progress photos. Verifies sequential fill, manual-pick
/// preservation, no tag reuse, and graceful run-out.
/// Part of the iOS app's logic test suite.
import XCTest
@testable import Pulse

final class AutoTagAssignmentTests: XCTestCase {
    /// All-untagged photos receive tags in sort order, one each.
    func testFillsAllUntaggedInOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        let out = AutoTagAssignment.assign(current: [nil, nil, nil], orderedTags: [a, b, c])
        XCTAssertEqual(out, [a, b, c])
    }

    /// A manually assigned tag is preserved and not handed out again.
    func testPreservesManualAndSkipsItsTag() {
        let a = UUID(), b = UUID(), c = UUID()
        let out = AutoTagAssignment.assign(current: [nil, b, nil], orderedTags: [a, b, c])
        XCTAssertEqual(out, [a, b, c])
    }

    /// More photos than tags: extra slots stay nil.
    func testRunsOutOfTags() {
        let a = UUID(), b = UUID()
        let out = AutoTagAssignment.assign(current: [nil, nil, nil, nil], orderedTags: [a, b])
        XCTAssertEqual(out, [a, b, nil, nil])
    }

    /// Fewer photos than tags: only as many as photos get assigned.
    func testFewerPhotosThanTags() {
        let a = UUID(), b = UUID(), c = UUID()
        let out = AutoTagAssignment.assign(current: [nil], orderedTags: [a, b, c])
        XCTAssertEqual(out, [a])
    }

    /// Empty tag list is a no-op.
    func testEmptyTagsNoOp() {
        let out = AutoTagAssignment.assign(current: [nil, nil], orderedTags: [])
        XCTAssertEqual(out, [nil, nil])
    }

    /// All photos already tagged: unchanged.
    func testAllPreTaggedUnchanged() {
        let a = UUID(), b = UUID(), c = UUID()
        let out = AutoTagAssignment.assign(current: [a, b], orderedTags: [a, b, c])
        XCTAssertEqual(out, [a, b])
    }
}
