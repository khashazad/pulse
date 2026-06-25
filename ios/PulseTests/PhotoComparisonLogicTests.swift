// PulseTests/PhotoComparisonLogicTests.swift
import XCTest
@testable import Pulse

/// Unit tests for the pure progress-photo comparison/gallery helpers.
final class PhotoComparisonLogicTests: XCTestCase {
    /// Fixed UTC Gregorian calendar so day math is deterministic across machines.
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func tag(_ name: String, order: Int) -> ProgressPhotoTag {
        ProgressPhotoTag(
            id: UUID(), name: name, normalizedName: name.lowercased(),
            sortOrder: order, createdAt: day(2020, 1, 1), updatedAt: day(2020, 1, 1)
        )
    }

    private func meta(tag: ProgressPhotoTag, date: Date, updated: Date) -> ProgressPhotoMetadata {
        ProgressPhotoMetadata(
            id: UUID(), date: date, tagId: tag.id, mime: "image/jpeg",
            bytes: 1, sha256: UUID().uuidString, updatedAt: updated
        )
    }

    private func weight(_ lb: Double, date: Date, updated: Date) -> WeightEntry {
        WeightEntry(
            id: UUID(), date: date, weightLb: lb, sourceUnit: .lb,
            createdAt: date, updatedAt: updated
        )
    }

    func test_tagsWithPhotosOnBothDates_keepsOnlyTagsPresentOnBothDays_inOrder() {
        let front = tag("Front", order: 0)
        let side = tag("Side", order: 1)
        let back = tag("Back", order: 2)
        let dayA = day(2026, 5, 1)
        let dayB = day(2026, 6, 1)

        let metadata = [
            meta(tag: front, date: dayA, updated: dayA),
            meta(tag: front, date: dayB, updated: dayB),     // Front: both -> kept
            meta(tag: side, date: dayA, updated: dayA),       // Side: only dayA -> dropped
            meta(tag: back, date: dayB, updated: dayB)        // Back: only dayB -> dropped
        ]

        let result = tagsWithPhotosOnBothDates(
            tags: [front, side, back], metadata: metadata,
            dayA: dayA, dayB: dayB, calendar: cal
        )
        XCTAssertEqual(result.map(\.name), ["Front"])
    }

    func test_tagsWithPhotosOnBothDates_matchesByCalendarDayNotInstant() {
        let front = tag("Front", order: 0)
        let dayA = day(2026, 5, 1)
        let dayB = day(2026, 6, 1)
        // Same days but with intraday time offsets — must still match.
        let aLater = dayA.addingTimeInterval(3600 * 9)
        let bLater = dayB.addingTimeInterval(3600 * 20)
        let metadata = [
            meta(tag: front, date: aLater, updated: aLater),
            meta(tag: front, date: bLater, updated: bLater)
        ]
        let result = tagsWithPhotosOnBothDates(
            tags: [front], metadata: metadata, dayA: dayA, dayB: dayB, calendar: cal
        )
        XCTAssertEqual(result.map(\.name), ["Front"])
    }

    func test_photoForTagOnDay_returnsNewestByUpdatedAt() {
        let front = tag("Front", order: 0)
        let target = day(2026, 5, 1)
        let older = meta(tag: front, date: target, updated: day(2026, 5, 1))
        let newer = meta(tag: front, date: target.addingTimeInterval(7200), updated: day(2026, 5, 2))
        let metadata = [older, newer]

        let picked = photo(for: front, on: target, in: metadata, calendar: cal)
        XCTAssertEqual(picked?.id, newer.id)
    }

    func test_photoForTagOnDay_nilWhenAbsent() {
        let front = tag("Front", order: 0)
        let metadata = [meta(tag: front, date: day(2026, 5, 1), updated: day(2026, 5, 1))]
        XCTAssertNil(photo(for: front, on: day(2026, 6, 1), in: metadata, calendar: cal))
    }

    func test_indexWeightsByDay_keepsLatestUpdatedPerDay() {
        let d = day(2026, 5, 1)
        let stale = weight(180, date: d, updated: day(2026, 5, 1))
        let fresh = weight(182, date: d.addingTimeInterval(3600), updated: day(2026, 5, 2))
        let index = indexWeightsByDay([stale, fresh], calendar: cal)
        XCTAssertEqual(index[cal.startOfDay(for: d)]?.weightLb, 182)
        XCTAssertEqual(index.count, 1)
    }

    func test_dateRangeWindows_splitsLongSpanIntoContiguousCappedWindows() {
        let from = day(2025, 1, 1)
        let to = day(2026, 6, 1)   // ~516 days
        let windows = dateRangeWindows(from: from, to: to, maxDays: 366, calendar: cal)

        XCTAssertEqual(windows.count, 2)
        // Each window within the cap.
        for w in windows {
            let span = cal.dateComponents([.day], from: w.start, to: w.end).day ?? 0
            XCTAssertLessThanOrEqual(span, 365)   // maxDays - 1
        }
        // Contiguous and fully covering.
        XCTAssertEqual(windows.first?.start, from)
        XCTAssertEqual(windows.last?.end, to)
        let gap = cal.dateComponents([.day], from: windows[0].end, to: windows[1].start).day
        XCTAssertEqual(gap, 1)
    }

    func test_dateRangeWindows_singleDayAndReversed() {
        let d = day(2026, 5, 1)
        XCTAssertEqual(dateRangeWindows(from: d, to: d, calendar: cal).count, 1)
        XCTAssertTrue(dateRangeWindows(from: day(2026, 6, 1), to: day(2026, 5, 1), calendar: cal).isEmpty)
    }
}
