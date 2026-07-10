/// Wire model bundling a single day's targets, consumed totals, remaining
/// macros, and the underlying food entries.
/// Returned by the day-summary endpoint and rendered on the home/today screen.
import Foundation

/// One day's targets, consumed/remaining macros, and the list of food entries.
struct DailySummary: Codable, Equatable {
    let date: Date              // YYYY-MM-DD
    let target: MacroTargets
    let consumed: MacroTotals
    let remaining: MacroTotals
    let entries: [FoodEntry]
    /// User flagged this day "ignore from stats" — averages/trends skip it.
    let excluded: Bool

    enum CodingKeys: String, CodingKey {
        case date, target, consumed, remaining, entries, excluded
    }

    /// Memberwise-style init retained so the day model can rebuild summaries
    /// (optimistic exclude toggle, entry removal) without decoding.
    init(
        date: Date, target: MacroTargets, consumed: MacroTotals,
        remaining: MacroTotals, entries: [FoodEntry], excluded: Bool = false
    ) {
        self.date = date
        self.target = target
        self.consumed = consumed
        self.remaining = remaining
        self.entries = entries
        self.excluded = excluded
    }

    /// Decodes a summary, defaulting `excluded` to `false` when the key is
    /// absent so older cached payloads (pre-exclusion field) still decode.
    /// Inputs:
    ///   - decoder: the decoder holding the keyed container.
    /// Exceptions: rethrows any decoding error for the required fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        target = try c.decode(MacroTargets.self, forKey: .target)
        consumed = try c.decode(MacroTotals.self, forKey: .consumed)
        remaining = try c.decode(MacroTotals.self, forKey: .remaining)
        entries = try c.decode([FoodEntry].self, forKey: .entries)
        excluded = try c.decodeIfPresent(Bool.self, forKey: .excluded) ?? false
    }
}
