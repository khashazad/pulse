import Foundation

struct Container: Codable, Equatable, Identifiable {
    let id: UUID
    let userKey: String
    let name: String
    let normalizedName: String
    let tareWeightG: Double
    let hasPhoto: Bool
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userKey = "user_key"
        case name
        case normalizedName = "normalized_name"
        case tareWeightG = "tare_weight_g"
        case hasPhoto = "has_photo"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct ContainersList: Codable, Equatable {
    let containers: [Container]
}

struct ContainerPhotoStatus: Codable, Equatable {
    let hasPhoto: Bool

    enum CodingKeys: String, CodingKey {
        case hasPhoto = "has_photo"
    }
}

enum ContainerPhotoSize: String {
    case thumb
    case full
}
