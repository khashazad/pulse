import Foundation

enum AuthCallbackParser {
    struct Credentials: Equatable {
        let token: String
        let email: String
    }

    static func parse(_ url: URL) -> Result<Credentials, DietTrackerError> {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []

        if let error = items.first(where: { $0.name == "error" })?.value, !error.isEmpty {
            return .failure(.signInFailed(reason: error))
        }

        guard
            let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty,
            let email = items.first(where: { $0.name == "email" })?.value, !email.isEmpty
        else {
            return .failure(.signInFailed(reason: "invalid_callback"))
        }
        return .success(Credentials(token: token, email: email))
    }
}
