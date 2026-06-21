/// Ordering helpers for focused progress-photo pair comparisons.
import Foundation

/// Returns two progress photos in chronological display order.
/// Dates sort ascending, with `updatedAt` as the deterministic tie-break for
/// multiple uploads on the same day.
/// - Parameters:
///   - lhs: one selected photo.
///   - rhs: the other selected photo.
/// - Returns: the older/newer pair for left/right comparison display.
func orderedPair(
    _ lhs: ProgressPhotoMetadata,
    _ rhs: ProgressPhotoMetadata
) -> (older: ProgressPhotoMetadata, newer: ProgressPhotoMetadata) {
    if isChronologicallyBefore(lhs, rhs) {
        return (lhs, rhs)
    }
    return (rhs, lhs)
}

/// Stable chronological comparison for two selected photo metadata values.
/// - Parameters:
///   - lhs: candidate left-side photo.
///   - rhs: candidate right-side photo.
/// - Returns: `true` when `lhs` should appear before `rhs`.
private func isChronologicallyBefore(_ lhs: ProgressPhotoMetadata, _ rhs: ProgressPhotoMetadata) -> Bool {
    if lhs.date != rhs.date { return lhs.date < rhs.date }
    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
    return lhs.id.uuidString < rhs.id.uuidString
}
