/// AppSettings: app-wide static configuration container.
/// Holds future settings such as theme/units; currently empty because auth state
/// lives in AuthSession and the base URL is build-embedded.
/// Role: provided in the SwiftUI environment for screens that need global config.
import Foundation
import Observation

/// Observable container reserved for app-wide static configuration.
@Observable
final class AppSettings {
    // Reserved for future static config (theme, units, etc.). Currently empty
    // because all auth state moved to AuthSession and the base URL is build-embedded.
    /// Creates an empty settings container.
    init() {}
}
