/// AuthSession: Google-OAuth backed auth state for the iOS client.
/// Manages the signed-in lifecycle, persists session tokens in Keychain, drives
/// ASWebAuthenticationSession for sign-in, and produces authenticated clients
/// (PulseClient, ProgressPhotoClient) used elsewhere in the app.
/// Role: top-level observable injected into the SwiftUI environment.
import Foundation
import Observation
import AuthenticationServices
import os.log

private let authDiagLog = Logger(subsystem: "com.pulseapp.pulse", category: "AuthDiag")

/// Observable session manager that owns auth state, token storage, and OAuth orchestration.
@Observable
final class AuthSession {
    /// Discrete states of the sign-in lifecycle.
    enum State: Equatable {
        case signedOut
        case signingIn
        case signedIn(email: String)
        case error(PulseError)
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

    /// Initializes the session, restoring any token from Keychain and cleaning up legacy API-key items.
    /// Inputs:
    ///   - baseURL: backend base URL used for OAuth and API calls.
    ///   - keychainService: Keychain service name for the session item.
    ///   - keychainAccount: Keychain account name for the session item.
    ///   - urlSession: URLSession used for whoami/logout and authenticated clients.
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

    /// Completes sign-in from an OAuth callback URL.
    /// Parses the one-time exchange code, redeems it (with the PKCE verifier)
    /// for a bearer session over TLS, and persists the session — or surfaces an
    /// error. The token is never read from the callback URL itself.
    /// Inputs:
    ///   - url: callback URL delivered by ASWebAuthenticationSession.
    ///   - codeVerifier: the PKCE verifier generated when this sign-in started.
    func completeSignIn(url: URL, codeVerifier: String) async {
        switch AuthCallbackParser.parse(url) {
        case .failure(let err):
            state = .error(err)
        case .success(let code):
            do {
                let creds = try await exchangeCodeForSession(code: code, codeVerifier: codeVerifier)
                let stored = StoredSession(token: creds.token, email: creds.email)
                if writeStored(stored) {
                    state = .signedIn(email: creds.email)
                } else {
                    state = .error(.signInFailed(reason: "keychain_write_failed"))
                }
            } catch let err as PulseError {
                state = .error(err)
            } catch {
                state = .error(.signInFailed(reason: "exchange_failed"))
            }
        }
    }

    /// Redeems a one-time exchange code at `/auth/google/exchange` for a session.
    /// Inputs:
    ///   - code: the one-time code delivered via the OAuth callback URL.
    ///   - codeVerifier: the PKCE verifier proving this app initiated the flow.
    /// Outputs: the issued bearer `token` and the authenticated `email`.
    /// Exceptions: `PulseError.network` on transport failure;
    /// `PulseError.signInFailed(reason: "exchange_rejected")` on a 4xx
    /// rejection (bad/expired code or verifier); `PulseError.server` on other
    /// non-2xx; `PulseError.decoding` is surfaced as a thrown decode error.
    private func exchangeCodeForSession(
        code: String,
        codeVerifier: String
    ) async throws -> (token: String, email: String) {
        let url = baseURL.appendingPathComponent(Constants.Auth.exchangePath)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: ["code": code, "code_verifier": codeVerifier]
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch let urlError as URLError {
            throw PulseError.network(urlError)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PulseError.server(status: -1)
        }
        switch http.statusCode {
        case 200..<300: break
        case 400, 401, 403: throw PulseError.signInFailed(reason: "exchange_rejected")
        default: throw PulseError.server(status: http.statusCode)
        }
        return try Self.decodeExchange(data)
    }

    /// Decodes a successful `/auth/google/exchange` response body.
    /// Inputs:
    ///   - data: response body bytes.
    /// Outputs: the issued `token` and `email`.
    /// Exceptions: `PulseError.decoding` when the body cannot be decoded.
    private static func decodeExchange(_ data: Data) throws -> (token: String, email: String) {
        do {
            let decoded = try JSONDecoder().decode(ExchangeResponse.self, from: data)
            return (decoded.token, decoded.email)
        } catch {
            throw PulseError.decoding(String(describing: error))
        }
    }

    /// Validates a stored token at app launch with a whoami call, clearing it on 401.
    /// Network/server failures are non-fatal — the optimistic signed-in state is kept.
    func bootstrap() async {
        guard let token = storedToken else { return }
        let client = PulseClient(
            baseURL: baseURL,
            sessionToken: token,
            session: urlSession
        )
        do {
            _ = try await client.whoami()
            // 200 → no-op; sliding TTL handled server-side.
        } catch PulseError.unauthorized {
            handleUnauthorized()
        } catch {
            // Network/server errors are non-fatal — keep optimistic sign-in.
        }
    }

    /// Clears Keychain and per-session caches in response to a 401 from any caller.
    func handleUnauthorized() {
        authDiagLog.notice("handleUnauthorized: clearing Keychain")
        _ = clearStored()
        state = .signedOut
        onSessionCleared?()
    }

    /// User-initiated sign-out: best-effort server revoke, then clears Keychain and caches.
    func signOut() async {
        authDiagLog.notice("signOut: user-initiated, clearing Keychain")
        if let token = storedToken {
            let client = PulseClient(
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

    /// Builds an authenticated PulseClient using the stored session token, or nil if signed out.
    /// Outputs: authenticated client, or nil when no token is in Keychain.
    func makeClient() -> PulseClient? {
        guard let token = storedToken else { return nil }
        return PulseClient(baseURL: baseURL, sessionToken: token, session: urlSession)
    }

    /// Builds an authenticated ProgressPhotoClient using the stored session token, or nil if signed out.
    /// Outputs: authenticated photo client, or nil when no token is in Keychain.
    func makeProgressPhotoClient() -> ProgressPhotoClient? {
        guard let token = storedToken else { return nil }
        return ProgressPhotoClient(baseURL: baseURL, sessionToken: token, session: urlSession)
    }

    /// URL to open in ASWebAuthenticationSession to begin the OAuth flow.
    /// Outputs: fully qualified URL of the server's sign-in entry point.
    func startSignInURL() -> URL {
        baseURL.appendingPathComponent(Constants.Auth.startPath)
    }

    /// Builds the sign-in entry URL carrying the PKCE challenge query params.
    /// Inputs:
    ///   - codeChallenge: the S256 challenge for this sign-in attempt.
    /// Outputs: the start URL with `code_challenge`/`code_challenge_method`, or
    /// nil if URL composition fails.
    func signInURL(codeChallenge: String) -> URL? {
        guard var comps = URLComponents(url: startSignInURL(), resolvingAgainstBaseURL: false) else {
            return nil
        }
        comps.queryItems = [
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return comps.url
    }

    // MARK: - storage

    /// Codable record persisted in Keychain to remember the active session.
    private struct StoredSession: Codable {
        let token: String
        let email: String
    }

    /// Decoded body of a successful `/auth/google/exchange` response.
    private struct ExchangeResponse: Decodable {
        let token: String
        let email: String
    }

    /// Reads and decodes the stored session from Keychain.
    /// Inputs:
    ///   - service: Keychain service name.
    ///   - account: Keychain account name.
    /// Outputs: decoded StoredSession, or nil when missing/corrupt.
    private static func readStored(service: String, account: String) -> StoredSession? {
        guard
            let raw = KeychainStore.read(service: service, account: account),
            let data = raw.data(using: .utf8),
            let stored = try? JSONDecoder().decode(StoredSession.self, from: data)
        else { return nil }
        return stored
    }

    /// Encodes and writes a session record to Keychain.
    /// Inputs:
    ///   - stored: session record to persist.
    /// Outputs: true on success, false if encoding or Keychain write fails.
    private func writeStored(_ stored: StoredSession) -> Bool {
        guard
            let data = try? JSONEncoder().encode(stored),
            let raw = String(data: data, encoding: .utf8)
        else { return false }
        return KeychainStore.write(raw, service: keychainService, account: keychainAccount)
    }

    /// Deletes the Keychain-backed session record.
    /// Outputs: true when the item was removed (or did not exist).
    @discardableResult
    private func clearStored() -> Bool {
        KeychainStore.delete(service: keychainService, account: keychainAccount)
    }

    fileprivate var storedToken: String? {
        Self.readStored(service: keychainService, account: keychainAccount)?.token
    }
}

/// Main-actor extension that owns the ASWebAuthenticationSession lifecycle.
@MainActor
extension AuthSession {
    /// Drives the Google OAuth flow from start to callback handling.
    /// Inputs:
    ///   - presentationAnchor: window scene used to host the web-auth UI.
    func signInWithGoogle(presentationAnchor: ASPresentationAnchor) async {
        state = .signingIn
        let codeVerifier = PKCE.generateCodeVerifier()
        let codeChallenge = PKCE.challenge(for: codeVerifier)
        guard let url = signInURL(codeChallenge: codeChallenge) else {
            state = .error(.signInFailed(reason: "invalid_start_url"))
            return
        }
        do {
            let callback = try await startWebAuth(
                url: url,
                callbackScheme: Constants.Auth.callbackScheme,
                presentationAnchor: presentationAnchor
            )
            await completeSignIn(url: callback, codeVerifier: codeVerifier)
        } catch let asError as ASWebAuthenticationSessionError where asError.code == .canceledLogin {
            state = .signedOut
        } catch let asError as ASWebAuthenticationSessionError {
            state = .error(.signInFailed(reason: "aswebauth_\(asError.code.rawValue)"))
        } catch let dtError as PulseError {
            state = .error(dtError)
        } catch {
            state = .error(.signInFailed(reason: "unknown:\(String(describing: type(of: error)))"))
        }
    }

    /// Wraps ASWebAuthenticationSession in an async/await throwing call, retaining the
    /// session and its presentation-context provider so neither is deallocated mid-flow.
    /// Inputs:
    ///   - url: sign-in entry point URL.
    ///   - callbackScheme: custom URL scheme used by the callback.
    ///   - presentationAnchor: window scene used to host the web-auth UI.
    /// Outputs: the callback URL containing OAuth credentials.
    /// Exceptions: ASWebAuthenticationSessionError on user cancel or system failure;
    /// PulseError.signInFailed when the session yields no callback or fails to start.
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
                    continuation.resume(throwing: PulseError.signInFailed(reason: "invalid_callback"))
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
                continuation.resume(throwing: PulseError.signInFailed(reason: "session_start_returned_false"))
            }
        }
    }
}

/// Strongly-retained presentation-context provider for ASWebAuthenticationSession.
private final class SignInPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    /// Initializes the provider with the anchor to vend to ASWebAuth.
    /// Inputs:
    ///   - anchor: window scene to host the web-auth UI.
    init(anchor: ASPresentationAnchor) { self.anchor = anchor }
    /// Returns the stored presentation anchor for the given web-auth session.
    /// Inputs:
    ///   - session: the requesting ASWebAuthenticationSession.
    /// Outputs: the anchor captured at init time.
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}
