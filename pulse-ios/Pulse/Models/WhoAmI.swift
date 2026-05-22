/// Wire model for the auth `whoami` response.
/// Reports the authenticated user's email and the session/token expiry timestamp.
/// Used during login bootstrap and to display the signed-in identity.
import Foundation

/// Authenticated identity returned by the `whoami` endpoint.
struct WhoAmI: Decodable, Equatable {
    let email: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case email
        case expiresAt = "expires_at"
    }
}
