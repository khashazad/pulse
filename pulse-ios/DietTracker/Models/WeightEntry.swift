import Foundation

enum WeightUnit: String, Codable, CaseIterable, Hashable {
    case lb
    case kg
}

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

extension WeightUnit {
    static let displayPreferenceKey = "weight_display_unit"
    static var defaultDisplayUnit: WeightUnit { .lb }
}
