import Foundation
import Observation
import AuthenticationServices

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
    /// Holds the in-flight ASWebAuthenticationSession so it isn't deallocated
    /// before the system delivers the callback URL.
    private var activeWebAuthSession: ASWebAuthenticationSession?

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
        _ = clearStored()
        state = .signedOut
    }

    func signOut() async {
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
        print("[AuthSession] signInWithGoogle url=\(url.absoluteString) scheme=\(Constants.Auth.callbackScheme)")
        do {
            let callback = try await startWebAuth(
                url: url,
                callbackScheme: Constants.Auth.callbackScheme,
                presentationAnchor: presentationAnchor
            )
            print("[AuthSession] callback received: \(callback.absoluteString)")
            handleSignInCallback(url: callback)
        } catch let asError as ASWebAuthenticationSessionError where asError.code == .canceledLogin {
            print("[AuthSession] user cancelled (canceledLogin)")
            state = .signedOut
        } catch let asError as ASWebAuthenticationSessionError {
            print("[AuthSession] ASWebAuth error: code=\(asError.code.rawValue) desc=\(asError.localizedDescription)")
            state = .error(.signInFailed(reason: "aswebauth_\(asError.code.rawValue)"))
        } catch let dtError as DietTrackerError {
            print("[AuthSession] DietTracker error: \(dtError)")
            state = .error(dtError)
        } catch {
            print("[AuthSession] unknown sign-in error: \(error)")
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
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let callback = callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: DietTrackerError.signInFailed(reason: "invalid_callback"))
                }
            }
            session.presentationContextProvider = SignInPresentationContextProvider(anchor: presentationAnchor)
            session.prefersEphemeralWebBrowserSession = false
            self.activeWebAuthSession = session
            print("[AuthSession] starting ASWebAuthenticationSession (canStart=\(session.canStart))")
            if !session.start() {
                print("[AuthSession] session.start() returned false")
                guard !didResume else { return }
                didResume = true
                self.activeWebAuthSession = nil
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
