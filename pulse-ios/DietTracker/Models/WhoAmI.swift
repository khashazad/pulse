import Foundation

struct WhoAmI: Decodable, Equatable {
    let email: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case email
        case expiresAt = "expires_at"
    }
}
