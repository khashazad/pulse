import Foundation
import Observation

@Observable
final class AuthSession {
    enum State: Equatable {
        case signedOut
        case signingIn
        case signedIn(email: String)
        case error(DietTrackerError)
    }

    private(set) var state: State

    var email: String? {
        if case .signedIn(let e) = state { return e } else { return nil }
    }

    var isSignedIn: Bool {
        if case .signedIn = state { return true } else { return false }
    }

    private let baseURL: URL
    private let keychainService: String
    private let keychainAccount: String
    private let urlSession: URLSession

    init(
        baseURL: URL,
        keychainService: String = Constants.Keychain.sessionService,
        keychainAccount: String = Constants.Keychain.sessionAccount,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.urlSession = urlSession
        if let stored = Self.readStored(service: keychainService, account: keychainAccount) {
            self.state = .signedIn(email: stored.email)
        } else {
            self.state = .signedOut
        }
    }

    func handleSignInCallback(url: URL) {
        switch AuthCallbackParser.parse(url) {
        case .success(let creds):
            let stored = StoredSession(token: creds.token, email: creds.email)
            if writeStored(stored) {
                state = .signedIn(email: creds.email)
            } else {
                state = .error(.signInFailed(reason: "keychain_write_failed"))
            }
        case .failure(let err):
            state = .error(err)
        }
    }

    // MARK: - storage

    private struct StoredSession: Codable {
        let token: String
        let email: String
    }

    private static func readStored(service: String, account: String) -> StoredSession? {
        guard
            let raw = KeychainStore.read(service: service, account: account),
            let data = raw.data(using: .utf8),
            let stored = try? JSONDecoder().decode(StoredSession.self, from: data)
        else { return nil }
        return stored
    }

    private func writeStored(_ stored: StoredSession) -> Bool {
        guard
            let data = try? JSONEncoder().encode(stored),
            let raw = String(data: data, encoding: .utf8)
        else { return false }
        return KeychainStore.write(raw, service: keychainService, account: keychainAccount)
    }

    @discardableResult
    private func clearStored() -> Bool {
        KeychainStore.delete(service: keychainService, account: keychainAccount)
    }

    fileprivate var storedToken: String? {
        Self.readStored(service: keychainService, account: keychainAccount)?.token
    }
}
