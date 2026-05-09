import Foundation

enum DietTrackerError: Error, Equatable {
    case notConfigured
    case unauthorized
    case notFound
    case payloadTooLarge
    case network(URLError)
    case decoding(String)
    case server(status: Int)

    static func == (lhs: DietTrackerError, rhs: DietTrackerError) -> Bool {
        switch (lhs, rhs) {
        case (.notConfigured, .notConfigured),
             (.unauthorized, .unauthorized),
             (.notFound, .notFound),
             (.payloadTooLarge, .payloadTooLarge):
            return true
        case let (.network(a), .network(b)):
            return a.code == b.code
        case let (.decoding(a), .decoding(b)):
            return a == b
        case let (.server(a), .server(b)):
            return a == b
        default:
            return false
        }
    }

    var userMessage: String {
        switch self {
        case .notConfigured:    return "Set the server URL and API key in Settings."
        case .unauthorized:     return "API key rejected. Check Settings."
        case .notFound:         return "No data for this date."
        case .payloadTooLarge:  return "That image is too large. Try a smaller photo."
        case .network:          return "Network error. Check your connection."
        case .decoding:         return "Couldn't read the server response."
        case .server(let s):    return "Server error (\(s)). Try again."
        }
    }
}
