/// Compile-time and Info.plist-derived constants for Pulse.
/// Exposes the validated backend `baseURL`, keychain identifiers (current and
/// legacy), and OAuth callback configuration. Acts as the single source of
/// truth for environment and identifier strings consumed across the app.
import Foundation

/// Namespace for app-wide constants. Failures at load time (invalid `BaseURL`)
/// halt the process via `fatalError` to surface misconfiguration immediately.
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
            fatalError(#"BaseURL must be an absolute http(s) URL with a host — got "\#(raw)". Set PULSE_BASE_URL before xcodegen."#)
        }
        return url
    }()

    /// Keychain service/account identifiers used by `KeychainStore` to persist
    /// the session token and to one-shot delete legacy API-key items.
    enum Keychain {
        static let sessionService = "com.khxsh.diettracker.session"
        static let sessionAccount = "default"

        // Legacy API-key item identifiers, kept here ONLY so a one-shot deletion
        // in AuthSession.init can clean up old installs. Reference is removed in
        // the next release.
        static let legacyService = "com.khxsh.diettracker.apikey"
        static let legacyAccount = "default"
    }

    /// Configuration for the Google OAuth round-trip: the custom URL scheme the
    /// backend redirects back to and the server-side start path.
    enum Auth {
        static let callbackScheme = "diettracker"
        static let startPath = "/auth/google/start"
    }
}
