import Foundation
import Observation

@Observable
final class AppSettings {
    var baseURLString: String {
        didSet { UserDefaults.standard.set(baseURLString, forKey: Constants.Defaults.baseURL) }
    }
    var apiKey: String {
        didSet {
            keychainWriteFailed = !KeychainStore.write(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// True if the most recent Keychain write didn't succeed. Surfaced in Settings.
    private(set) var keychainWriteFailed: Bool = false

    init() {
        self.baseURLString = UserDefaults.standard.string(forKey: Constants.Defaults.baseURL) ?? ""
        self.apiKey = KeychainStore.read() ?? ""
    }

    var isConfigured: Bool {
        guard let url = normalizedBaseURL else { return false }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.scheme != nil && !trimmedKey.isEmpty
    }

    private var normalizedBaseURL: URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URL(string: withScheme)
    }

    func makeClient() -> DietTrackerClient? {
        guard let url = normalizedBaseURL else { return nil }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }
        return DietTrackerClient(baseURL: url, apiKey: trimmedKey)
    }
}
