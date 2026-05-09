import Foundation

enum Constants {
    static let baseURL: URL = {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "BaseURL") as? String) ?? ""
        guard
            !raw.isEmpty,
            let url = URL(string: raw),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host,
            !host.isEmpty
        else {
            fatalError(#"BaseURL must be an absolute http(s) URL with a host — got "\#(raw)". Set DIET_TRACKER_BASE_URL before xcodegen."#)
        }
        return url
    }()

    enum Keychain {
        static let sessionService = "com.khxsh.diettracker.session"
        static let sessionAccount = "default"

        // Legacy API-key item identifiers, kept here ONLY so a one-shot deletion
        // in AuthSession.init can clean up old installs. Reference is removed in
        // the next release.
        static let legacyService = "com.khxsh.diettracker.apikey"
        static let legacyAccount = "default"
    }

    enum Auth {
        static let callbackScheme = "diettracker"
        static let startPath = "/auth/google/start"
    }
}
