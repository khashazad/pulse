import Foundation
import Observation
import AuthenticationServices
import os.log

private let authDiagLog = Logger(subsystem: "com.khxsh.diettracker", category: "AuthDiag")

@Observable
final class AuthSession {
    enum State: Equatable {
        case signedOut
        case signingIn
        case signedIn(email: String)
        case error(DietTrackerError)
    }

    private(set) var state: State
    /// Invoked after sign-out or 401 handling so per-session caches can be cleared.
    var onSessionCleared: (() -> Void)?

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
    /// Holds the in-flight ASWebAuthenticationSession so it isn't deallocated
    /// before the system delivers the callback URL.
    private var activeWebAuthSession: ASWebAuthenticationSession?
    /// `presentationContextProvider` on ASWebAuthenticationSession is `weak`,
    /// so the provider must be retained somewhere or it gets deallocated
    /// before `start()` and ASWebAuth refuses to present.
    private var activeWebAuthContextProvider: ASWebAuthenticationPresentationContextProviding?

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
            authDiagLog.notice("init: Keychain HIT (email=\(stored.email, privacy: .public))")
            self.state = .signedIn(email: stored.email)
        } else {
            authDiagLog.notice("init: Keychain MISS")
            self.state = .signedOut
        }
        // One-shot cleanup of the previous API-key Keychain item; safe if absent.
        _ = KeychainStore.delete(
            service: Constants.Keychain.legacyService,
            account: Constants.Keychain.legacyAccount
        )
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

    func bootstrap() async {
        guard let token = storedToken else { return }
        let client = DietTrackerClient(
            baseURL: baseURL,
            sessionToken: token,
            session: urlSession
        )
        do {
            _ = try await client.whoami()
            // 200 → no-op; sliding TTL handled server-side.
        } catch DietTrackerError.unauthorized {
            handleUnauthorized()
        } catch {
            // Network/server errors are non-fatal — keep optimistic sign-in.
        }
    }

    func handleUnauthorized() {
        authDiagLog.notice("handleUnauthorized: clearing Keychain")
        _ = clearStored()
        state = .signedOut
        onSessionCleared?()
    }

    func signOut() async {
        authDiagLog.notice("signOut: user-initiated, clearing Keychain")
        if let token = storedToken {
            let client = DietTrackerClient(
                baseURL: baseURL,
                sessionToken: token,
                session: urlSession
            )
            // Best-effort revoke; ignore any failure.
            _ = try? await client.logout()
        }
        _ = clearStored()
        state = .signedOut
        onSessionCleared?()
    }

    func makeClient() -> DietTrackerClient? {
        guard let token = storedToken else { return nil }
        return DietTrackerClient(baseURL: baseURL, sessionToken: token, session: urlSession)
    }

    func startSignInURL() -> URL {
        baseURL.appendingPathComponent(Constants.Auth.startPath)
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

@MainActor
extension AuthSession {
    func signInWithGoogle(presentationAnchor: ASPresentationAnchor) async {
        state = .signingIn
        let url = startSignInURL()
        do {
            let callback = try await startWebAuth(
                url: url,
                callbackScheme: Constants.Auth.callbackScheme,
                presentationAnchor: presentationAnchor
            )
            handleSignInCallback(url: callback)
        } catch let asError as ASWebAuthenticationSessionError where asError.code == .canceledLogin {
            state = .signedOut
        } catch let asError as ASWebAuthenticationSessionError {
            state = .error(.signInFailed(reason: "aswebauth_\(asError.code.rawValue)"))
        } catch let dtError as DietTrackerError {
            state = .error(dtError)
        } catch {
            state = .error(.signInFailed(reason: "unknown:\(String(describing: type(of: error)))"))
        }
    }

    private func startWebAuth(
        url: URL,
        callbackScheme: String,
        presentationAnchor: ASPresentationAnchor
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            // The session must outlive this synchronous block — the system delivers
            // the callback later. Stash it on `self` so ARC keeps it alive.
            // Belt-and-braces single-resume: `session.start()` returning false should
            // not race with a later completion-handler invocation, but guard anyway.
            var didResume = false

            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { [weak self] callback, error in
                guard !didResume else { return }
                didResume = true
                self?.activeWebAuthSession = nil
                self?.activeWebAuthContextProvider = nil
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let callback = callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: DietTrackerError.signInFailed(reason: "invalid_callback"))
                }
            }
            // Retain BOTH the session and its presentation-context provider —
            // ASWebAuthenticationSession.presentationContextProvider is `weak`,
            // so an inline allocation gets deallocated before `start()` runs.
            let provider = SignInPresentationContextProvider(anchor: presentationAnchor)
            session.presentationContextProvider = provider
            session.prefersEphemeralWebBrowserSession = false
            self.activeWebAuthSession = session
            self.activeWebAuthContextProvider = provider
            if !session.start() {
                guard !didResume else { return }
                didResume = true
                self.activeWebAuthSession = nil
                self.activeWebAuthContextProvider = nil
                continuation.resume(throwing: DietTrackerError.signInFailed(reason: "session_start_returned_false"))
            }
        }
    }
}

private final class SignInPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    init(anchor: ASPresentationAnchor) { self.anchor = anchor }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}
