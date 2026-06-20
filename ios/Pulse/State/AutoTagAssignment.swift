/// Pure ordering rule for auto-tagging progress photos.
/// Maps captured photos (their current tag, in capture order) plus an ordered
/// tag sequence to the tag id each photo should carry — filling only untagged
/// slots, never reusing a tag, and preserving manual assignments.
/// Role: SwiftUI-free helper unit-tested independently of the capture view.
import Foundation

/// Namespace for the auto-tag assignment rule.
enum AutoTagAssignment {
    /// Assigns tags to untagged photos in capture order from an ordered tag list.
    /// Inputs:
    ///   - current: each photo's current tag id (nil when untagged), in capture order.
    ///   - orderedTags: the tag ids in pose/sort order to draw from.
    /// Outputs: an array the same length and order as `current`; every nil slot is
    ///   filled with the next tag not already present and not yet consumed, while
    ///   non-nil slots are returned unchanged and surplus nils remain nil.
    static func assign(current: [UUID?], orderedTags: [UUID]) -> [UUID?] {
        let used = Set(current.compactMap { $0 })
        let available = orderedTags.filter { !used.contains($0) }
        var result = current
        var next = 0
        for i in result.indices where result[i] == nil {
            guard next < available.count else { break }
            result[i] = available[next]
            next += 1
        }
        return result
    }
}
