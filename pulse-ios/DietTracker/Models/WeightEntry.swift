/// Wire models for weight tracking.
/// Defines the lb/kg display-unit enum, the canonical-in-pounds `WeightEntry`
/// record, and a `WeightUnit` extension that exposes the display-unit
/// `UserDefaults` key plus the default unit.
/// Consumed by the weight-logging UI and weight-history views.
import Foundation

/// Source unit the user entered a weight in; storage is always pounds.
enum WeightUnit: String, Codable, CaseIterable, Hashable {
    case lb
    case kg
}

/// One weight log row, stored canonically in pounds with the original entry unit.
struct WeightEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    let weightLb: Double
    let sourceUnit: WeightUnit
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case date = "log_date"
        case weightLb = "weight_lb"
        case sourceUnit = "source_unit"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// User-facing display preference helpers for `WeightUnit`.
extension WeightUnit {
    static let displayPreferenceKey = "weight_display_unit"
    static var defaultDisplayUnit: WeightUnit { .lb }
}
