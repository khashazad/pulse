/// Weekday-symbol helpers shared by the intake bar charts, so the 1-based
/// `.weekday` component → symbol-array index arithmetic lives in one place.
import Foundation

extension Calendar {
    /// Very-short weekday symbol (e.g. "M", "T") for the weekday of `date`.
    /// Inputs:
    ///   - date: the date whose weekday is wanted.
    /// Outputs: a one-letter localized weekday string.
    func veryShortWeekdaySymbol(for date: Date) -> String {
        let comp = component(.weekday, from: date)
        return veryShortWeekdaySymbols[(comp - 1) % veryShortWeekdaySymbols.count]
    }

    /// Abbreviated weekday symbol (e.g. "Wed") for the weekday of `date`.
    /// Inputs:
    ///   - date: the date whose weekday is wanted.
    /// Outputs: a short localized weekday string.
    func shortWeekdaySymbol(for date: Date) -> String {
        let comp = component(.weekday, from: date)
        return shortWeekdaySymbols[(comp - 1) % shortWeekdaySymbols.count]
    }
}
