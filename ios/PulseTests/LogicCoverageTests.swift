// PulseTests/LogicCoverageTests.swift
/// Pure-logic unit tests for under-covered non-view code: PeriodIntakeModel
/// bucketing, WeightTrendsModel regression math, DateOnly encode/decode/fallback,
/// Meal/MealSummary totals, PulseError
/// userMessage mapping, and CameraCaptureView's coordinator delegate. These are
/// deterministic and need no run-loop pump; network-dependent paths use the
/// shared `StubURLProtocol` with a dedicated test keychain slot.
import XCTest
import UIKit
@testable import Pulse

// MARK: - PeriodIntakeModel bucketing

/// Verifies the static weekly / monthly bucketing helpers that drive the
/// month and year period-summary charts (averages over logged days, current
/// bucket marking, and chronological ordering).
final class PeriodIntakeBucketTests: XCTestCase {
    /// Builds a `DailyLog` directly (no JSON round-trip) so the test stays
    /// independent of the device timezone used by `DateOnly`'s formatters.
    /// - Parameters:
    ///   - date: the log's calendar day instant.
    ///   - kcal: total calories for the day.
    ///   - entries: number of entries; 0 marks an unlogged day.
    /// - Returns: a `DailyLog` value.
    private func log(_ date: Date, kcal: Int, entries: Int = 1) -> DailyLog {
        let json = """
        {"date":"2026-01-01","total_calories":\(kcal),
         "total_protein_g":0.0,"total_carbs_g":0.0,"total_fat_g":0.0,"entry_count":\(entries)}
        """
        let decoded = try! JSONDecoder.pulseDefault().decode(DailyLog.self, from: json.data(using: .utf8)!)
        // Replace the placeholder date with the exact instant the test wants.
        return DailyLog(
            date: date, totalCalories: decoded.totalCalories,
            totalProteinG: decoded.totalProteinG, totalCarbsG: decoded.totalCarbsG,
            totalFatG: decoded.totalFatG, entryCount: decoded.entryCount
        )
    }

    /// Verifies weekly buckets average only logged days, label sequentially,
    /// and mark the bucket containing `today` as current.
    func test_weeklyBuckets_averagesLoggedDaysAndMarksCurrent() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Toronto")!
        let today = cal.date(from: DateComponents(year: 2026, month: 5, day: 20))!
        // Two days in the current week (one logged, one not) + one day two weeks back.
        let logs = [
            log(cal.date(from: DateComponents(year: 2026, month: 5, day: 18))!, kcal: 2000, entries: 2),
            log(cal.date(from: DateComponents(year: 2026, month: 5, day: 19))!, kcal: 0, entries: 0),
            log(cal.date(from: DateComponents(year: 2026, month: 5, day: 6))!, kcal: 1000, entries: 1)
        ]
        let buckets = PeriodIntakeModel.weeklyBuckets(logs, today: today, calendar: cal)
        XCTAssertEqual(buckets.count, 2, "two distinct week-start groups expected")
        XCTAssertEqual(buckets.map(\.label), ["W1", "W2"])
        // Earlier week sorts first; the current week (today's) is the later one.
        XCTAssertFalse(buckets[0].isCurrent)
        XCTAssertTrue(buckets[1].isCurrent)
        // The current week averages only the single logged day (2000), ignoring the 0-entry day.
        XCTAssertEqual(buckets[1].avgKcalPerDay, 2000)
        XCTAssertEqual(buckets[0].avgKcalPerDay, 1000)
    }

    /// Verifies an empty input yields no buckets.
    func test_weeklyBuckets_emptyInputYieldsNoBuckets() {
        XCTAssertTrue(PeriodIntakeModel.weeklyBuckets([]).isEmpty)
    }

    /// Verifies monthly buckets group by calendar month, average logged days,
    /// label with localized short month symbols, and mark the current month.
    func test_monthlyBuckets_groupsByMonthAndMarksCurrent() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Toronto")!
        let today = cal.date(from: DateComponents(year: 2026, month: 5, day: 20))!
        let logs = [
            log(cal.date(from: DateComponents(year: 2026, month: 5, day: 1))!, kcal: 2000, entries: 1),
            log(cal.date(from: DateComponents(year: 2026, month: 5, day: 2))!, kcal: 1000, entries: 1),
            log(cal.date(from: DateComponents(year: 2026, month: 5, day: 3))!, kcal: 9999, entries: 0),
            log(cal.date(from: DateComponents(year: 2026, month: 3, day: 15))!, kcal: 1500, entries: 1)
        ]
        let buckets = PeriodIntakeModel.monthlyBuckets(logs, today: today, calendar: cal)
        XCTAssertEqual(buckets.count, 2)
        // March sorts before May.
        XCTAssertEqual(buckets.map(\.label), [cal.shortMonthSymbols[2], cal.shortMonthSymbols[4]])
        XCTAssertEqual(buckets[0].avgKcalPerDay, 1500)
        // May averages the two logged days (2000+1000)/2, ignoring the 0-entry day.
        XCTAssertEqual(buckets[1].avgKcalPerDay, 1500)
        XCTAssertTrue(buckets[1].isCurrent)
        XCTAssertFalse(buckets[0].isCurrent)
    }
}

// MARK: - WeightTrendsModel regression line

/// Verifies the pure least-squares `regressionLine(for:unit:)` helper: the
/// minimum-point guard, unit conversion of the fitted endpoints, and the
/// slope/intercept of a known-answer line.
final class WeightTrendsRegressionTests: XCTestCase {
    /// Builds `count` weight entries one day apart starting at `start`, with
    /// pound values produced by `value(index)`.
    /// - Parameters:
    ///   - count: number of entries.
    ///   - start: date of the first (index 0) entry.
    ///   - value: maps an index to a weight in pounds.
    /// - Returns: chronologically ascending weight entries.
    private func entries(count: Int, start: Date, value: (Int) -> Double) -> [WeightEntry] {
        (0..<count).map { i in
            WeightEntry(
                id: UUID(),
                date: start.addingTimeInterval(TimeInterval(i) * 86_400),
                weightLb: value(i),
                sourceUnit: .lb,
                createdAt: start,
                updatedAt: start
            )
        }
    }

    /// Verifies fewer than 8 points returns nil (not enough signal to fit).
    func test_regressionLine_returnsNilUnderEightPoints() {
        let e = entries(count: 7, start: Date(timeIntervalSince1970: 0)) { Double(180 + $0) }
        XCTAssertNil(WeightTrendsModel.regressionLine(for: e, unit: .lb))
    }

    /// Verifies a perfectly linear series recovers its slope: 0.5 lb/day over
    /// 10 points means endY = startY + 0.5 * 9.
    func test_regressionLine_recoversPerfectSlope() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let e = entries(count: 10, start: start) { 180.0 + 0.5 * Double($0) }
        let line = try XCTUnwrap(WeightTrendsModel.regressionLine(for: e, unit: .lb))
        XCTAssertEqual(line.startY, 180.0, accuracy: 0.0001)
        XCTAssertEqual(line.endY, 180.0 + 0.5 * 9, accuracy: 0.0001)
        XCTAssertEqual(line.startDate, start)
        XCTAssertEqual(line.endDate, e.last!.date)
    }

    /// Verifies the endpoints are emitted in the requested display unit (kg),
    /// i.e. the fit runs on converted y-values.
    func test_regressionLine_convertsToDisplayUnit() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let e = entries(count: 10, start: start) { _ in 200.0 }  // flat 200 lb
        let line = try XCTUnwrap(WeightTrendsModel.regressionLine(for: e, unit: .kg))
        let expectedKg = WeightFormatter.fromLb(200.0, to: .kg)
        XCTAssertEqual(line.startY, expectedKg, accuracy: 0.0001)
        XCTAssertEqual(line.endY, expectedKg, accuracy: 0.0001)
    }
}

// MARK: - DateOnly coding

/// Verifies the wire-format date helpers: `YYYY-MM-DD` round-trip, the naive
/// wall-clock encoder, and the decoder's three-tier fallback (date-only →
/// ISO-8601 fractional → ISO-8601 → throw).
final class DateOnlyCodingTests: XCTestCase {
    private struct Holder: Codable, Equatable { let at: Date }

    /// Decodes a JSON string `{"at": <raw>}` through `JSONDecoder.pulseDefault()`.
    /// - Parameter raw: the JSON value for `at` (already quoted/escaped as needed).
    /// - Returns: the decoded `Date`.
    /// - Throws: rethrows the decoder error when the value is unparseable.
    private func decodeAt(_ raw: String) throws -> Date {
        let data = "{\"at\": \(raw)}".data(using: .utf8)!
        return try JSONDecoder.pulseDefault().decode(Holder.self, from: data).at
    }

    /// Verifies `DateOnly.string(from:)` and `formatter.date(from:)` round-trip.
    func test_dateOnly_stringRoundTrips() {
        let date = DateOnly.formatter.date(from: "2026-05-29")!
        XCTAssertEqual(DateOnly.string(from: date), "2026-05-29")
    }

    /// `DateOnly.endOfDay` lands at 23:59 on the same calendar day (no midnight
    /// rollover) and sorts strictly after noon of that day.
    func test_dateOnly_endOfDayStaysOnSameDayAfterNoon() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Toronto")!
        let day = cal.date(from: DateComponents(year: 2026, month: 6, day: 20))!

        let eod = DateOnly.endOfDay(on: day, calendar: cal)
        let parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: eod)

        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 6)
        XCTAssertEqual(parts.day, 20)
        XCTAssertEqual(parts.hour, 23)
        XCTAssertEqual(parts.minute, 59)
        XCTAssertGreaterThan(eod, DateOnly.noon(on: day, calendar: cal))
    }

    /// Verifies the decoder accepts a bare `YYYY-MM-DD` string (first tier).
    func test_pulseDefaultDecoder_acceptsDateOnly() throws {
        let date = try decodeAt("\"2026-05-29\"")
        XCTAssertEqual(DateOnly.string(from: date), "2026-05-29")
    }

    /// Verifies the decoder accepts ISO-8601 with fractional seconds (second tier).
    func test_pulseDefaultDecoder_acceptsFractionalISO8601() throws {
        let date = try decodeAt("\"2026-05-29T08:30:00.500Z\"")
        XCTAssertEqual(date.timeIntervalSince1970, 1_780_043_400.5, accuracy: 0.001)
    }

    /// Verifies the decoder accepts plain ISO-8601 without fractional seconds (third tier).
    func test_pulseDefaultDecoder_acceptsPlainISO8601() throws {
        let date = try decodeAt("\"2026-05-29T08:30:00Z\"")
        XCTAssertEqual(date.timeIntervalSince1970, 1_780_043_400, accuracy: 0.001)
    }

    /// Verifies an unrecognized date string throws a `dataCorrupted` error.
    func test_pulseDefaultDecoder_throwsOnGarbage() {
        XCTAssertThrowsError(try decodeAt("\"not-a-date\"")) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
        }
    }

    /// Verifies `DateOnly.decode(from:)` (the single-value helper used by date-only
    /// DTO fields) parses a valid string and throws on an invalid one.
    func test_dateOnlyDecodeHelper_parsesAndThrows() throws {
        struct DayHolder: Decodable { let d: Date
            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                d = try DateOnly.decode(from: c.superDecoder())
            }
        }
        // Valid
        let good = "[\"2026-01-15\"]".data(using: .utf8)!
        XCTAssertEqual(DateOnly.string(from: try JSONDecoder().decode(DayHolder.self, from: good).d), "2026-01-15")
        // Invalid
        let bad = "[\"15/01/2026\"]".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(DayHolder.self, from: bad))
    }

    /// Verifies `JSONEncoder.pulseDefault()` emits a naive wall-clock datetime
    /// (no timezone offset) for an encoded `Date`.
    func test_pulseDefaultEncoder_emitsNaiveWallClock() throws {
        // 2026-05-29 12:00:00 in the device's current zone.
        let date = DateOnly.wallClockFormatter.date(from: "2026-05-29T12:00:00")!
        let data = try JSONEncoder.pulseDefault().encode(Holder(at: date))
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"2026-05-29T12:00:00\""), "got \(json)")
        XCTAssertFalse(json.contains("Z"), "wall-clock value must carry no offset: \(json)")
    }
}

// MARK: - Meal / MealSummary totals

/// Verifies the macro-aggregation conveniences on `Meal` and `MealSummary`
/// decoded from fixture JSON.
final class MealTotalsTests: XCTestCase {
    /// Loads and decodes a `Meal` from the `meal_with_items` fixture.
    /// - Returns: the decoded `Meal`.
    /// - Throws: rethrows any decode error.
    private func loadMeal() throws -> Meal {
        let url = Bundle(for: Self.self).url(forResource: "meal_with_items", withExtension: "json")!
        return try JSONDecoder.pulseDefault().decode(Meal.self, from: Data(contentsOf: url))
    }

    /// Verifies `Meal.totals` sums each item's macros.
    func test_mealTotals_sumsItems() throws {
        let meal = try loadMeal()
        XCTAssertEqual(meal.items.count, 2)
        let totals = meal.totals
        XCTAssertEqual(totals.calories, 450)       // 320 + 130
        XCTAssertEqual(totals.proteinG, 28.0, accuracy: 0.001)  // 10 + 18
        XCTAssertEqual(totals.carbsG, 63.0, accuracy: 0.001)    // 54 + 9
        XCTAssertEqual(totals.fatG, 10.0, accuracy: 0.001)      // 6 + 4
        XCTAssertEqual(meal.aliases, ["morning bowl"])
        XCTAssertEqual(meal.notes, "Go-to morning meal")
    }

    /// Verifies `MealSummary.totals` reflects the server-supplied aggregates and
    /// that omitted `aliases` default to an empty array.
    func test_mealSummaryTotals_reflectAggregatesAndDefaultsAliases() throws {
        let json = #"{"id":"11111111-1111-1111-1111-111111111111","name":"Wrap","normalized_name":"wrap","notes":null,"item_count":3,"total_calories":600,"total_protein_g":40.0,"total_carbs_g":50.0,"total_fat_g":20.0}"#
        let summary = try JSONDecoder.pulseDefault().decode(MealSummary.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(summary.aliases, [], "missing aliases must default to empty")
        XCTAssertEqual(summary.totals.calories, 600)
        XCTAssertEqual(summary.totals.proteinG, 40.0, accuracy: 0.001)
        XCTAssertEqual(summary.itemCount, 3)
    }
}

// MARK: - PulseError userMessage

/// Verifies the user-facing message mapping for every `PulseError` case and
/// every named `signInFailed` reason branch (including the default fallthrough).
final class PulseErrorMessageTests: XCTestCase {
    /// Verifies the simple (non-associated) cases map to their copy.
    func test_userMessage_simpleCases() {
        XCTAssertEqual(PulseError.notSignedIn.userMessage, "Sign in to continue.")
        XCTAssertEqual(PulseError.unauthorized.userMessage, "Sign in again.")
        XCTAssertEqual(PulseError.notFound.userMessage, "No data for this date.")
        XCTAssertEqual(PulseError.payloadTooLarge.userMessage, "That image is too large. Try a smaller photo.")
        XCTAssertEqual(PulseError.signInCancelled.userMessage, "Sign-in cancelled.")
    }

    /// Verifies the associated-value cases embed their value in the message.
    func test_userMessage_associatedCases() {
        XCTAssertEqual(PulseError.network(URLError(.timedOut)).userMessage, "Network error. Check your connection.")
        XCTAssertEqual(PulseError.decoding("x").userMessage, "Couldn't read the server response.")
        XCTAssertEqual(PulseError.server(status: 503).userMessage, "Server error (503). Try again.")
    }

    /// Verifies each named sign-in reason maps to its copy, and an unknown
    /// reason falls through to the parameterized default.
    func test_userMessage_signInReasons() {
        XCTAssertEqual(PulseError.signInFailed(reason: "access_denied").userMessage, "Sign-in cancelled.")
        XCTAssertEqual(PulseError.signInFailed(reason: "not_allowed").userMessage, "This Google account isn't allowed on this server.")
        XCTAssertEqual(PulseError.signInFailed(reason: "invalid_state").userMessage, "Sign-in expired, please try again.")
        XCTAssertEqual(PulseError.signInFailed(reason: "invalid_callback").userMessage, "Sign-in failed. Please try again.")
        XCTAssertEqual(PulseError.signInFailed(reason: "keychain_write_failed").userMessage, "Couldn't save sign-in. Check device storage.")
        XCTAssertEqual(PulseError.signInFailed(reason: "weird").userMessage, "Sign-in failed (weird).")
    }

    /// Verifies the custom `Equatable` conformance: same case + same payload is
    /// equal; differing payloads or cases are not.
    func test_equatable_comparesPayloadsWhereMeaningful() {
        XCTAssertEqual(PulseError.server(status: 500), PulseError.server(status: 500))
        XCTAssertNotEqual(PulseError.server(status: 500), PulseError.server(status: 404))
        XCTAssertEqual(PulseError.network(URLError(.timedOut)), PulseError.network(URLError(.timedOut)))
        XCTAssertNotEqual(PulseError.network(URLError(.timedOut)), PulseError.network(URLError(.badURL)))
        XCTAssertEqual(PulseError.decoding("a"), PulseError.decoding("a"))
        XCTAssertNotEqual(PulseError.decoding("a"), PulseError.decoding("b"))
        XCTAssertNotEqual(PulseError.notFound, PulseError.unauthorized)
    }
}

// MARK: - CameraCaptureView coordinator

/// Verifies the `CameraCaptureView` UIKit bridge coordinator's delegate
/// forwarding (capture with an image, capture with no image → cancel, and
/// explicit cancel). `makeUIViewController` / `updateUIViewController` are
/// covered by mounting the view in `ViewRenderExtraTests`.
final class CameraCaptureViewTests: XCTestCase {
    /// Verifies a finished pick carrying an original image forwards to `onCapture`.
    @MainActor
    func test_coordinator_forwardsCapturedImage() {
        var captured: UIImage?
        var cancelled = false
        let view = CameraCaptureView(onCapture: { captured = $0 }, onCancel: { cancelled = true })
        let coordinator = view.makeCoordinator()
        let img = UIImage()
        coordinator.imagePickerController(UIImagePickerController(), didFinishPickingMediaWithInfo: [.originalImage: img])
        XCTAssertNotNil(captured)
        XCTAssertFalse(cancelled)
    }

    /// Verifies a finished pick with no usable image falls back to `onCancel`.
    @MainActor
    func test_coordinator_missingImageCancels() {
        var captured: UIImage?
        var cancelled = false
        let view = CameraCaptureView(onCapture: { captured = $0 }, onCancel: { cancelled = true })
        let coordinator = view.makeCoordinator()
        coordinator.imagePickerController(UIImagePickerController(), didFinishPickingMediaWithInfo: [:])
        XCTAssertNil(captured)
        XCTAssertTrue(cancelled)
    }

    /// Verifies an explicit picker cancel forwards to `onCancel`.
    @MainActor
    func test_coordinator_explicitCancel() {
        var cancelled = false
        let view = CameraCaptureView(onCapture: { _ in }, onCancel: { cancelled = true })
        let coordinator = view.makeCoordinator()
        coordinator.imagePickerControllerDidCancel(UIImagePickerController())
        XCTAssertTrue(cancelled)
    }
}
