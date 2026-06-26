import Foundation

extension Double {
    /// The value with trailing ".0" stripped for compact display.
    /// - Returns: An integer string when the value is finite and whole, otherwise a
    ///   one-decimal-place string (which also renders non-finite values without trapping).
    var clean: String {
        (isFinite && self == rounded()) ? String(Int(self)) : String(format: "%.1f", self)
    }

    /// The value, interpreted as a count of minutes, formatted compactly as hours and minutes.
    /// - Returns: "45m" when under an hour, otherwise "1h 5m" (the leading "0h" is dropped).
    var asDurationFromMinutes: String {
        let total = Int(rounded())
        let hours = total / 60
        let minutes = total % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    /// The value, interpreted as a count of minutes, formatted with days, hours, and minutes.
    /// Used for the Year Trends headline where totals can span multiple days.
    /// Always emits minutes; days and hours are omitted when zero.
    /// - Returns: E.g. "2d 3h 40m" for 3820 minutes, or "45m" for 45 minutes.
    var asDurationWithDays: String {
        let total = Int(rounded())
        let days = total / (60 * 24)
        let remaining = total % (60 * 24)
        let hours = remaining / 60
        let mins = remaining % 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        parts.append("\(mins)m")
        return parts.joined(separator: " ")
    }
}
