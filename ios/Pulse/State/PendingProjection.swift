/// Pure helpers for the day view's "pending projection" — what a day's totals
/// would read if its pending (applied-but-unconfirmed) entries were confirmed.
/// Confirmed totals come from the server's `consumed` (which already excludes
/// pending); these helpers add the pending entries' macros back on top.
/// Role: shared, view-free math used by `DayMacroView`; unit-tested directly.
import Foundation

/// Sums the macro contributions of a set of food entries into one `MacroTotals`,
/// using the shared `MacroTotals.zero` seed and `+` operator (the single source
/// of truth for macro summation in `MacroScaling`).
/// Inputs:
///   - entries: the entries to sum (typically a day's pending entries).
/// Outputs: a `MacroTotals` with the summed calories and protein/carbs/fat grams
///   (`.zero` for an empty input).
func sumMacroTotals(_ entries: [FoodEntry]) -> MacroTotals {
    entries.reduce(.zero) { acc, entry in
        acc + MacroTotals(
            calories: entry.calories,
            proteinG: entry.proteinG,
            carbsG: entry.carbsG,
            fatG: entry.fatG
        )
    }
}

/// Projects confirmed totals forward by the macros of the given pending entries —
/// the day's totals as they would read once every pending entry is confirmed.
/// Inputs:
///   - consumed: the day's confirmed totals (server `consumed`, excludes pending).
///   - pending: the day's pending (unconfirmed) entries.
/// Outputs: the projected `MacroTotals`, or `nil` when there are no pending
///   entries (no projection to display).
func projectedTotals(consumed: MacroTotals, pending: [FoodEntry]) -> MacroTotals? {
    guard !pending.isEmpty else { return nil }
    return consumed + sumMacroTotals(pending)
}
