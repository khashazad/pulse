import Foundation

extension Double {
    /// The value with trailing ".0" stripped for compact display.
    /// - Returns: An integer string when the value is whole, otherwise a one-decimal-place string.
    var clean: String {
        self == rounded() ? String(Int(self)) : String(format: "%.1f", self)
    }
}
