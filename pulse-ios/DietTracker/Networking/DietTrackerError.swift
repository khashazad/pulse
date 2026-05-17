/// Domain error type for all diet-tracker networking and auth failures.
/// Defines `DietTrackerError`, its `Equatable` conformance, and a
/// `userMessage` mapping that the UI surfaces to the user. Centralizes
/// HTTP-status-to-error mapping and sign-in failure reason strings.
import Foundation

/// Errors emitted by the networking layer, auth flow, and decoding pipeline.
enum DietTrackerError: Error, Equatable {
    case notSignedIn
    case unauthorized
    case notFound
    case payloadTooLarge
    case network(URLError)
    case decoding(String)
    case server(status: Int)
    case signInCancelled
    case signInFailed(reason: String)

    /// Equality comparison that ignores associated-value differences except
    /// where they carry user-visible information (URL error code, decoding
    /// description, HTTP status, sign-in reason).
    /// Inputs:
    ///   - lhs: left-hand error.
    ///   - rhs: right-hand error.
    /// Outputs: `true` when both errors represent the same case and (where
    /// applicable) the same associated value.
    static func == (lhs: DietTrackerError, rhs: DietTrackerError) -> Bool {
        switch (lhs, rhs) {
        case (.notSignedIn, .notSignedIn),
             (.unauthorized, .unauthorized),
             (.notFound, .notFound),
             (.payloadTooLarge, .payloadTooLarge),
             (.signInCancelled, .signInCancelled):
            return true
        case let (.network(a), .network(b)):
            return a.code == b.code
        case let (.decoding(a), .decoding(b)):
            return a == b
        case let (.server(a), .server(b)):
            return a == b
        case let (.signInFailed(a), .signInFailed(b)):
            return a == b
        default:
            return false
        }
    }

    var userMessage: String {
        switch self {
        case .notSignedIn:      return "Sign in to continue."
        case .unauthorized:     return "Sign in again."
        case .notFound:         return "No data for this date."
        case .payloadTooLarge:  return "That image is too large. Try a smaller photo."
        case .network:          return "Network error. Check your connection."
        case .decoding:         return "Couldn't read the server response."
        case .server(let s):    return "Server error (\(s)). Try again."
        case .signInCancelled:  return "Sign-in cancelled."
        case .signInFailed(let reason):
            switch reason {
            case "access_denied":         return "Sign-in cancelled."
            case "not_allowed":           return "This Google account isn't allowed on this server."
            case "invalid_state":         return "Sign-in expired, please try again."
            case "invalid_callback":      return "Sign-in failed. Please try again."
            case "keychain_write_failed": return "Couldn't save sign-in. Check device storage."
            default:                      return "Sign-in failed (\(reason))."
            }
        }
    }
}
