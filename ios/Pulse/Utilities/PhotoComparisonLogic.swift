/// Pure helpers backing the progress-photo gallery and pair comparison: which
/// tags can be compared across two dates, which photo represents a tag on a day,
/// and a by-day weight index. Kept free of SwiftUI/networking so they're unit
/// testable.
import Foundation

/// Returns the tags that have at least one photo on BOTH given days, preserving
/// the input tag order. Used to populate the comparison tag switcher so the user
/// can only pick tags that actually have a photo at both compared time points.
/// - Parameters:
///   - tags: candidate tags, in display order.
///   - metadata: all available photo metadata (any tag, any date).
///   - dayA: first day to require a photo on.
///   - dayB: second day to require a photo on.
///   - calendar: calendar used for same-day comparison; defaults to `.current`.
/// - Returns: the subset of `tags` with a photo on both days.
func tagsWithPhotosOnBothDates(
    tags: [ProgressPhotoTag],
    metadata: [ProgressPhotoMetadata],
    dayA: Date,
    dayB: Date,
    calendar: Calendar = .current
) -> [ProgressPhotoTag] {
    tags.filter { tag in
        let mine = metadata.filter { $0.tagId == tag.id }
        let hasA = mine.contains { calendar.isDate($0.date, inSameDayAs: dayA) }
        let hasB = mine.contains { calendar.isDate($0.date, inSameDayAs: dayB) }
        return hasA && hasB
    }
}

/// Picks a tag's representative photo on a given day: the most recently updated
/// photo for that tag on that calendar day, or `nil` when the tag has none.
/// - Parameters:
///   - tag: the tag whose photo is wanted.
///   - day: the calendar day to match.
///   - metadata: all available photo metadata.
///   - calendar: calendar used for same-day comparison; defaults to `.current`.
/// - Returns: the matching photo metadata, or `nil`.
func photo(
    for tag: ProgressPhotoTag,
    on day: Date,
    in metadata: [ProgressPhotoMetadata],
    calendar: Calendar = .current
) -> ProgressPhotoMetadata? {
    metadata
        .filter { $0.tagId == tag.id && calendar.isDate($0.date, inSameDayAs: day) }
        .max { $0.updatedAt < $1.updatedAt }
}

/// Indexes weight entries by start-of-day so a gallery cell can look up its
/// photo's weight in O(1). When several entries share a day, the most recently
/// updated one wins.
/// - Parameters:
///   - entries: weight entries to index.
///   - calendar: calendar used to derive the day key; defaults to `.current`.
/// - Returns: a map from start-of-day to the winning weight entry.
func indexWeightsByDay(
    _ entries: [WeightEntry],
    calendar: Calendar = .current
) -> [Date: WeightEntry] {
    var map: [Date: WeightEntry] = [:]
    for entry in entries {
        let day = calendar.startOfDay(for: entry.date)
        if let existing = map[day], existing.updatedAt >= entry.updatedAt { continue }
        map[day] = entry
    }
    return map
}

/// Splits a date range into consecutive windows no longer than the server's
/// range cap (366 days), so weights spanning more than a year can be fetched in
/// a few capped requests instead of one rejected one.
/// - Parameters:
///   - from: inclusive range start.
///   - to: inclusive range end.
///   - maxDays: maximum window length in days; defaults to 366.
///   - calendar: calendar used to step days; defaults to `.current`.
/// - Returns: ordered `(start, end)` windows covering `from...to` (empty when `to < from`).
func dateRangeWindows(
    from: Date,
    to: Date,
    maxDays: Int = 366,
    calendar: Calendar = .current
) -> [(start: Date, end: Date)] {
    let start = calendar.startOfDay(for: from)
    let end = calendar.startOfDay(for: to)
    guard end >= start else { return [] }
    var windows: [(start: Date, end: Date)] = []
    var windowStart = start
    while windowStart <= end {
        let proposedEnd = calendar.date(byAdding: .day, value: maxDays - 1, to: windowStart) ?? end
        let windowEnd = min(proposedEnd, end)
        windows.append((windowStart, windowEnd))
        guard let next = calendar.date(byAdding: .day, value: 1, to: windowEnd) else { break }
        windowStart = next
    }
    return windows
}
