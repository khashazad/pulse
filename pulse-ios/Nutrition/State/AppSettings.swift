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
            && URL(string: baseURLString) != nil
    }

    func makeClient() -> NutritionClient? {
        guard isConfigured, let url = URL(string: baseURLString) else { return nil }
        return NutritionClient(baseURL: url, apiKey: apiKey)
    }
}
