// PulseTests/WeightBackfillTests.swift
/// Unit tests for WeightBackfill.defaultBackfillDate — the date the weight
/// screen's "+" preselects when backfilling a missed day.
import Testing
import Foundation
@testable import Pulse

struct WeightBackfillTests {
    private let cal = Calendar.current
    private let today = Calendar.current.startOfDay(for: Date())

    /// Returns the start-of-day a given number of days from today.
    /// - Parameter offset: Days from today; negative values are in the past.
    /// - Returns: The start-of-day `Date` `offset` days from today.
    private func day(_ offset: Int) -> Date {
        cal.date(byAdding: .day, value: offset, to: today)!
    }

    /// Builds a fixed-weight entry on the day a given number of days from today.
    /// - Parameter offset: Days from today; negative values are in the past.
    /// - Returns: A `WeightEntry` dated `offset` days from today.
    private func entry(_ offset: Int) -> WeightEntry {
        WeightEntry(id: UUID(), date: day(offset), weightLb: 180,
                    sourceUnit: .lb, createdAt: Date(), updatedAt: Date())
    }

    private var lower: Date { day(-89) }

    @Test func emptyEntriesReturnsYesterday() {
        let result = WeightBackfill.defaultBackfillDate(entries: [], today: today, lowerBound: lower)
        #expect(cal.isDate(result, inSameDayAs: day(-1)))
    }

    @Test func loggedYesterdayReturnsDayBefore() {
        let entries = (-1 ... 0).map { entry($0) } // today + yesterday logged
        // yesterday IS logged here, day(-2) is the most recent gap
        let result = WeightBackfill.defaultBackfillDate(entries: entries, today: today, lowerBound: lower)
        #expect(cal.isDate(result, inSameDayAs: day(-2)))
    }

    @Test func everyPastDayLoggedReturnsYesterday() {
        let entries = (-89 ... 0).map { entry($0) } // whole window logged
        let result = WeightBackfill.defaultBackfillDate(entries: entries, today: today, lowerBound: lower)
        #expect(cal.isDate(result, inSameDayAs: day(-1)))
    }

    @Test func singleGapReturnsThatDay() {
        // everything logged except day(-3)
        let entries = (-89 ... 0).filter { $0 != -3 }.map { entry($0) }
        let result = WeightBackfill.defaultBackfillDate(entries: entries, today: today, lowerBound: lower)
        #expect(cal.isDate(result, inSameDayAs: day(-3)))
    }

    @Test func returnsMostRecentGapWhenMultiple() {
        // gaps at day(-2) and day(-5); expect the most recent (-2)
        let entries = (-89 ... 0).filter { $0 != -2 && $0 != -5 }.map { entry($0) }
        let result = WeightBackfill.defaultBackfillDate(entries: entries, today: today, lowerBound: lower)
        #expect(cal.isDate(result, inSameDayAs: day(-2)))
    }

    @Test func allPastDaysLoggedReturnsYesterday() {
        // today is the only unlogged day; every past day is logged → yesterday
        let entries = (-89 ... -1).map { entry($0) }
        let result = WeightBackfill.defaultBackfillDate(entries: entries, today: today, lowerBound: lower)
        #expect(cal.isDate(result, inSameDayAs: day(-1)))
    }

    @Test func walkStartsAtYesterdayNotToday() {
        // Both today and yesterday are unlogged; everything older is logged.
        // The walk must begin at yesterday and return it — never today, even
        // though today is the more recent gap.
        let entries = (-89 ... -2).map { entry($0) }
        let result = WeightBackfill.defaultBackfillDate(entries: entries, today: today, lowerBound: lower)
        #expect(cal.isDate(result, inSameDayAs: day(-1)))
    }
}
