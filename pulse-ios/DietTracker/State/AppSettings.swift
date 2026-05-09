import Foundation
import Observation

@Observable
final class AppSettings {
    // Reserved for future static config (theme, units, etc.). Currently empty
    // because all auth state moved to AuthSession and the base URL is build-embedded.
    init() {}
}
