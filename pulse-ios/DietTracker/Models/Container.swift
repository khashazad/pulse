/// Wire models for user-defined food containers (tare-weighted vessels).
/// Defines the `Container` record, list envelope, photo presence flag, and
/// the photo-size enum used to request thumb vs full container photos.
/// Used by the containers feature for tare-weight tracking and photo display.
import Foundation

/// A user-defined container with a tare weight and optional photo.
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

/// Envelope for `GET /containers` returning the user's container list.
struct ContainersList: Codable, Equatable {
    let containers: [Container]
}

/// Response indicating whether a container currently has a photo attached.
struct ContainerPhotoStatus: Codable, Equatable {
    let hasPhoto: Bool

    enum CodingKeys: String, CodingKey {
        case hasPhoto = "has_photo"
    }
}

/// Size variant requested when fetching a container photo from the server.
enum ContainerPhotoSize: String {
    case thumb
    case full
}
