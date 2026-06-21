// PulseTests/PhotoPairOrderingTests.swift
/// Tests for ordering two same-tag progress photos before opening the focused
/// pair comparison view.
import XCTest
@testable import Pulse

final class PhotoPairOrderingTests: XCTestCase {
    private let tagId = UUID()

    func test_orderedPair_returnsChronologicalPairRegardlessOfInputOrder() {
        let older = meta(date: "2026-05-01", updatedAt: "2026-05-01T09:00:00Z")
        let newer = meta(date: "2026-05-15", updatedAt: "2026-05-15T09:00:00Z")

        XCTAssertEqual(orderedPair(older, newer).older.id, older.id)
        XCTAssertEqual(orderedPair(older, newer).newer.id, newer.id)
        XCTAssertEqual(orderedPair(newer, older).older.id, older.id)
        XCTAssertEqual(orderedPair(newer, older).newer.id, newer.id)
    }

    func test_orderedPair_usesUpdatedAtTieBreakWhenDatesMatch() {
        let earlierUpdate = meta(date: "2026-05-01", updatedAt: "2026-05-01T09:00:00Z")
        let laterUpdate = meta(date: "2026-05-01", updatedAt: "2026-05-01T10:00:00Z")

        XCTAssertEqual(orderedPair(laterUpdate, earlierUpdate).older.id, earlierUpdate.id)
        XCTAssertEqual(orderedPair(earlierUpdate, laterUpdate).newer.id, laterUpdate.id)
    }

    private func meta(date: String, updatedAt: String) -> ProgressPhotoMetadata {
        ProgressPhotoMetadata(
            id: UUID(),
            date: DateOnly.formatter.date(from: date)!,
            tagId: tagId,
            mime: "image/jpeg",
            bytes: 1_024,
            sha256: UUID().uuidString,
            updatedAt: ISO8601DateFormatter().date(from: updatedAt)!
        )
    }
}
