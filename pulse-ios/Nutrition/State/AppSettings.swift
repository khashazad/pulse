import Foundation
import Observation

@Observable
final class AppSettings {
    var baseURLString: String {
        didSet { UserDefaults.standard.set(baseURLString, forKey: Constants.Defaults.baseURL) }
    }
    var apiKey: String {
        didSet { KeychainStore.write(apiKey) }
    }

    init() {
        self.baseURLString = UserDefaults.standard.string(forKey: Constants.Defaults.baseURL) ?? ""
        self.apiKey = KeychainStore.read() ?? ""
    }

    var isConfigured: Bool {
        !baseURLString.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var normalizedBaseURL: URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URL(string: withScheme)
    }

    func makeClient() -> NutritionClient? {
        guard isConfigured, let url = normalizedBaseURL else { return nil }
        return NutritionClient(baseURL: url, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
