import Foundation

enum Constants {
    static let userKey = "khash"   // removed in cleanup task

    static let baseURL: URL = {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "BaseURL") as? String,
            !raw.isEmpty,
            let url = URL(string: raw)
        else {
            fatalError("BaseURL missing from Info.plist — set DIET_TRACKER_BASE_URL before xcodegen")
        }
        return url
    }()

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
