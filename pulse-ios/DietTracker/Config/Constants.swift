import Foundation

enum Constants {
    static let userKey = "khash"   // removed in cleanup task

    /// Stop-gap until BuildConfig.xcconfig wiring lands in Task 15.
    static var baseURL: URL {
        URL(string: ProcessInfo.processInfo.environment["DIET_TRACKER_BASE_URL"] ?? "https://example.test")!
    }

    enum Defaults {
        static let baseURL = "diettracker.baseURL"   // removed in cleanup task
    }

    enum Keychain {
        // Legacy API-key item (cleanup task removes references and proactively deletes the item once on launch).
        static let service = "com.khxsh.diettracker.apikey"
        static let account = "default"

        // New session blob written by AuthSession.
        static let sessionService = "com.khxsh.diettracker.session"
        static let sessionAccount = "default"
    }

    enum Auth {
        static let callbackScheme = "diettracker"
        static let startPath = "/auth/google/start"
    }
}
