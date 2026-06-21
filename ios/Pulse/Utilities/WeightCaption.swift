/// Shared weight lookup and caption formatting for progress-photo comparison
/// surfaces.
import Foundation

/// Resolves the weight logged on a date while preserving previous UI state
/// through transient errors.
/// - Parameters:
///   - date: date whose weight entry should be fetched.
///   - client: authenticated Pulse API client.
///   - keep: existing entry to preserve when the fetch fails for a reason other
///     than a genuine missing row.
/// - Returns: fetched weight, `nil` for `.notFound`, or `keep` for transient errors.
func fetchWeight(for date: Date, client: PulseClient, keep: WeightEntry?) async -> WeightEntry? {
    do {
        return try await client.getWeight(date: date)
    } catch PulseError.notFound {
        return nil
    } catch {
        return keep
    }
}

/// Builds the single-line date/weight caption shown under comparison columns.
/// - Parameters:
///   - date: comparison column date.
///   - weight: logged weight for the date, if any.
///   - unitRaw: persisted display-unit raw value.
/// - Returns: `"<Mon d> · <weight>"` or `"<Mon d> · no weight"`.
func weightCaption(date: Date, weight: WeightEntry?, unitRaw: String) -> String {
    let day = date.formatted(WeightCaptionFormat.dayFormat)
    let unit = WeightUnit(rawValue: unitRaw) ?? .lb
    if let weight {
        return "\(day) · \(WeightFormatter.display(lb: weight.weightLb, in: unit))"
    }
    return "\(day) · no weight"
}

private enum WeightCaptionFormat {
    /// Caption date style, cached so render paths do not rebuild the format style.
    static let dayFormat: Date.FormatStyle = .dateTime.month(.abbreviated).day()
}
