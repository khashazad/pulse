# Google OAuth Login — iOS

**Status:** Design
**Date:** 2026-05-09
**Companion spec:** `dietracker-server/docs/superpowers/specs/2026-05-09-google-oauth-login-server-design.md`

## Goal

Replace the manual API-key + base-URL setup with a Google sign-in flow. After first sign-in, the app stays signed in across launches until the user signs out or the session is revoked server-side. Single-user today; designed so multi-user is a clean future change.

## Scope

In: login screen, Google sign-in via `ASWebAuthenticationSession` against the backend, session-token storage in Keychain, `Authorization: Bearer` on every API call, sign-out from Settings, build-time injection of the server URL.

Out: native Google Sign-In SDK, refresh tokens, biometric re-auth, multiple accounts on device, account switcher.

## Non-goals

- No `?user_key=` on any iOS request after this lands.
- No URL or API-key fields in the app UI.
- No backwards compatibility with the old `X-API-Key` flow.

## Contract with the backend

The iOS side depends on this contract; the server spec owns it.

- **Sign-in start:** iOS opens `<baseURL>/auth/google/start` in `ASWebAuthenticationSession` with callback scheme `diettracker`.
- **Callback success:** server redirects to `diettracker://auth?token=<opaque>&email=<urlenc>`.
- **Callback failure:** server redirects to `diettracker://auth?error=<code>` where `<code>` ∈ `{access_denied, not_allowed, invalid_state, invalid_callback, server_error}`. iOS owns the user-facing copy for each.
- **Session use:** every non-`/auth/*` request carries `Authorization: Bearer <token>`. No query-string identity.
- **Whoami:** `GET /auth/whoami` returns `{ "email": string, "expires_at": ISO-8601 }`. Used on cold start to validate the cached token.
- **Sign-out:** `POST /auth/logout` with the Bearer token. 204 on success. iOS clears local state regardless of result.
- **Token semantics:** opaque server-issued string, sliding TTL renewed on every authenticated request server-side. iOS treats the token as opaque.

## Architecture

```
┌────────────────────┐         build-time            ┌──────────────────┐
│ DIET_TRACKER_      │ ───── xcodegen / xcconfig ───▶│ Info.plist       │
│ BASE_URL (env)     │                               │ BaseURL key      │
└────────────────────┘                               └────────┬─────────┘
                                                              │ runtime
                                                              ▼
┌──────────────────┐  reads BaseURL  ┌──────────────────────────────────┐
│ AppSettings      │◀───────────────▶│ Constants.baseURL                │
└─────────┬────────┘                 └──────────────────────────────────┘
          │
          ▼
┌──────────────────┐  Keychain     ┌──────────────────────────────────┐
│ AuthSession      │◀────────────▶ │ com.khxsh.diettracker.session    │
│ (@Observable)    │   {token,     │   (single JSON blob)             │
│                  │    email}     └──────────────────────────────────┘
│  state machine   │
│  signInWithGoogle│  ASWebAuthenticationSession ──▶ backend /auth/*
│  signOut         │
│  bootstrap       │
│  makeClient      │ ─────▶ DietTrackerClient(baseURL, sessionToken)
└──────────────────┘
```

## Components

### `Config/BuildConfig.xcconfig` (new)

```
DIET_TRACKER_BASE_URL = ${DIET_TRACKER_BASE_URL}
INFOPLIST_KEY_BaseURL = $(DIET_TRACKER_BASE_URL)
```

`project.yml` references this xcconfig for both Debug and Release. xcodegen interpolates `${DIET_TRACKER_BASE_URL}` from the shell at generation time. CI/local must `export DIET_TRACKER_BASE_URL=https://…` before `xcodegen generate`. Missing/empty value is a build failure (we add a Run Script phase that fails the build if the resolved Info.plist value is empty).

### `Config/Constants.swift` (modified)

```swift
enum Constants {
    static let baseURL: URL = {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "BaseURL") as? String,
            !raw.isEmpty,
            let url = URL(string: raw)
        else {
            fatalError("BaseURL missing from Info.plist — set DIET_TRACKER_BASE_URL before xcodegen")
        }
        return url
    }()

    enum Keychain {
        static let sessionService = "com.khxsh.diettracker.session"
        static let account = "default"
    }
}
```

`Constants.userKey` is removed.

### `Config/KeychainStore.swift` (refactored)

Generalized to accept `(service, account)` per call. Keeps the same API shape (`read`, `write`, `delete`) but parameterized. The session blob is JSON `{ "token": String, "email": String }`. `write` and `delete` are atomic from the app's perspective — no half-written state where one of token/email is set and the other isn't.

### `State/AppSettings.swift` (shrunk)

Removes `baseURLString`, `apiKey`, `keychainWriteFailed`, `isConfigured`, `makeClient`, `normalizedBaseURL`. Becomes a thin holder that exposes `baseURL: URL` (delegates to `Constants.baseURL`) plus a place for future static config (theme, etc.). Kept as a type so future settings have a home.

### `State/AuthSession.swift` (new)

```swift
@Observable
final class AuthSession {
    enum State: Equatable {
        case signedOut
        case signingIn
        case signedIn(email: String)
        case error(DietTrackerError)
    }

    private(set) var state: State
    var email: String? { if case .signedIn(let e) = state { return e } else { return nil } }
    var isSignedIn: Bool { if case .signedIn = state { return true } else { return false } }

    weak var settings: AppSettings?

    init(settings: AppSettings)            // reads Keychain → optimistic .signedIn(email) or .signedOut
    func bootstrap() async                  // GET /auth/whoami, see Data flow
    func signInWithGoogle() async           // ASWebAuthenticationSession dance
    func signOut() async                    // POST /auth/logout best-effort + clear local
    func handleUnauthorized()               // synchronous: clear Keychain, state = .signedOut
    func makeClient() -> DietTrackerClient? // nil iff .signedOut/.signingIn/.error
}
```

`signInWithGoogle` uses `ASWebAuthenticationSession` with `callbackURLScheme: "diettracker"`. The presentation context provider returns the active window scene's first window. `prefersEphemeralWebBrowserSession` is `false` so Google's "stay signed in" cookies persist across attempts. The completion handler parses the callback URL via a pure helper (`AuthCallbackParser.parse(_:) -> Result<(token: String, email: String), DietTrackerError>`) so unit tests don't need ASWebAuth.

### `Networking/DietTrackerClient.swift` (modified)

- `init(baseURL: URL, sessionToken: String)` replaces `init(baseURL:apiKey:)`.
- All requests set `Authorization: Bearer <token>`. `X-API-Key` header is removed.
- Every `URLQueryItem(name: "user_key", …)` is removed from every endpoint method.
- Adds `whoami() async throws -> WhoAmI` and `logout() async throws`.
- `DietTrackerError` adds `.signInCancelled`, `.signInFailed(reason: String)`. `.notConfigured` becomes `.notSignedIn` (the case is renamed; existing call sites are updated in the same change).
- 401 handling: when the client sees a 401 on any non-auth endpoint, it throws `.unauthorized`; the calling model's `LoadState` settles as `.failed(.unauthorized)`. `AuthSession` observes this via a callback wired in `init` (or via a `@MainActor` notification) and calls `handleUnauthorized()`.

### `Views/Auth/LoginView.swift` (new)

Single screen, dark theme, Catppuccin. Centered: app name, short tagline, big "Continue with Google" button (mauve, full-width with horizontal padding), inline error label below the button. Spinner replaces the button label while `state == .signingIn`. No URL field. No API-key field.

### `Views/RootView.swift` (modified)

- Drops `AppSettings` configuration gate.
- Adds `@Environment(AuthSession.self) private var auth`.
- `.sheet(isPresented: .constant(!auth.isSignedIn))` presents `LoginView` non-dismissibly when signed out.
- The settings sheet is still gear-icon driven from each tab's toolbar but is only reachable post-sign-in.
- On `.task`, calls `auth.bootstrap()`.

### `Views/SettingsView.swift` (modified)

- Removes the "Server" section entirely.
- "Account" section becomes: signed-in email (mono, mauve), server URL (mono, read-only, FG.tertiary), Sign Out button (peach background, white text). Sign Out triggers `auth.signOut()` and dismisses the sheet on success.
- Theme section unchanged.

### Existing models

`DayMacroModel`, `WeekModel`, `MonthModel`, `YearModel`, `MealsModel`, `MealDetailModel`, `ContainersListModel`, `ContainerEditModel`, `PrepModel`: change `weak var settings: AppSettings?` to `weak var auth: AuthSession?`; replace `settings?.makeClient()` with `auth?.makeClient()`. No other behavior change.

### `DietTrackerApp.swift` (entry point)

Constructs both `AppSettings` and `AuthSession(settings:)` and injects both into the environment. `RootView` reads the settings only for non-auth UI (currently nothing needs it post-cutover, but it stays in environment for the future).

### `project.yml` (modified)

- Adds `configFiles: { Debug: Config/BuildConfig.xcconfig, Release: Config/BuildConfig.xcconfig }`.
- Adds a build phase script that fails the build if `$(BaseURL)` resolves to empty.
- Does **not** register `diettracker` under `CFBundleURLTypes`. `ASWebAuthenticationSession` with `callbackURLScheme:` intercepts the redirect itself; registering the scheme via URL types can cause iOS to route the callback to the app delegate instead, breaking the completion handler.

## Data flow

**Cold start, token in Keychain:**
1. `AppSettings` and `AuthSession` initialize.
2. `AuthSession.init` reads Keychain → `state = .signedIn(email)` optimistically; `LoginView` does not appear.
3. `RootView.task` calls `auth.bootstrap()` → `GET /auth/whoami`.
   - 200 → no-op (server slid the TTL).
   - 401 → `handleUnauthorized()` clears Keychain, `state = .signedOut`, `LoginView` presents.
   - Network error → keep optimistic `.signedIn`; first authenticated API call will revalidate.

**Cold start, no token:** `state = .signedOut`, `LoginView` presents immediately.

**Sign-in:**
1. User taps "Continue with Google" → `state = .signingIn`.
2. `ASWebAuthenticationSession` opens `<baseURL>/auth/google/start`.
3. Backend → Google → backend callback → 302 to `diettracker://auth?…`.
4. ASWebAuth completion fires with the callback URL.
5. `AuthCallbackParser.parse`:
   - `(token, email)` → write Keychain, `state = .signedIn(email)`.
   - `error=<code>` → `state = .error(.signInFailed(code))`.
   - Malformed → `state = .error(.signInFailed("invalid_callback"))`.
6. User-cancellation (`ASWebAuthenticationSessionError.canceledLogin`) → `state = .signedOut` silently.

**API call:** view `.task` → model → `auth.makeClient()` → request with Bearer header → 200 decodes / 401 throws `.unauthorized` and triggers `handleUnauthorized()`.

**Sign-out:** Settings → `auth.signOut()` → POST `/auth/logout` (best-effort) → Keychain clear → `state = .signedOut` → Settings sheet dismisses → `LoginView` presents.

## Error handling

| Where | Failure | Behavior |
|---|---|---|
| `Bundle.BaseURL` missing/invalid | Build misconfig | `fatalError` at startup. |
| ASWebAuth dismissed by user | `canceledLogin` | `state = .signedOut`, no banner. |
| Callback `error=access_denied` | User refused on Google | "Sign-in cancelled." |
| Callback `error=not_allowed` | Email not allowlisted | "This Google account isn't allowed on this server." |
| Callback `error=invalid_state` | CSRF / cookie expired | "Sign-in expired, please try again." |
| Callback `error=server_error` | Backend bug | "Something went wrong. Please try again." |
| Callback malformed (no token, no error) | Backend bug or MITM | `.signInFailed("invalid_callback")`. |
| `/auth/whoami` 401 on bootstrap | Token expired/revoked | Clear Keychain, `.signedOut`. Silent. |
| `/auth/whoami` network failure | Offline | Keep optimistic `.signedIn`. |
| API call 401 | Token expired/revoked mid-session | `handleUnauthorized()`; in-flight `LoadState`s settle as `.failed(.unauthorized)`; `LoginView` re-presents. |
| `POST /auth/logout` fails | Network/server | Local sign-out still succeeds; logged not surfaced. |
| Keychain write fails | Device misconfig | `state = .error(.signInFailed("keychain_write_failed"))`; user can retry. |
| Keychain unreadable on launch | First-unlock race | Treat as `.signedOut`; bootstrap retries on next foreground. |

## Testing

`DietTrackerTests/` — `StubURLProtocol` + JSON fixtures, same pattern as today.

| Area | Test |
|---|---|
| `DietTrackerClient` headers | Every endpoint sends `Authorization: Bearer <token>` and **no** `user_key` query item. |
| `DietTrackerClient` 401 | 401 → throws `.unauthorized`. |
| `DietTrackerClient` whoami | Decodes `{email, expires_at}` from fixture; bad JSON → `.decoding`. |
| `DietTrackerClient` logout | Request shape correct; 204 → returns; 401 → throws `.unauthorized`. |
| `AuthCallbackParser.parse` | Token+email path; each documented `error=<code>`; missing token; malformed URL. |
| `AuthSession.bootstrap` | Token + 200 → state stable; token + 401 → cleared + signed out; token + network error → still signed in; no token → no network call. |
| `AuthSession.handleUnauthorized` | Idempotent; clears Keychain; emits state change once. |
| `AuthSession.signOut` | 204 / 500 / network error all clear local state; logout request shape correct. |
| `KeychainStore` | Round-trip read/write/delete with `(service, account)`; overwrite; delete-missing returns true. |

Manual smoke: real-device sign-in against staging; cold launch with valid token (skips login); cold launch after server-side session deletion (lands on login).

## Cutover

Hard cutover, single PR:

1. Backend ships its half (companion spec).
2. iOS PR removes API-key UI, adds login flow, drops `?user_key=`. On first launch after update, the user sees `LoginView` regardless of any leftover legacy Keychain item — old item is at a different service identifier and is ignored. (We do not actively delete it; it'll age out or be cleaned up at OS level. If we want belt-and-braces, a one-line `KeychainStore.delete(service: "com.khxsh.diettracker.apikey", account: "default")` runs once in `AuthSession.init`.)

## Open questions

- ASWebAuth presentation anchor on iOS 17+ scene-based apps — confirm the right `UIWindowScene` lookup at impl time; default of any-window has been flaky in past iOS releases.
- Should `LoginView` show the server URL anywhere? Argument for: helps debug "wrong build". Argument against: clutters the login screen. Lean: no on the login screen; show it in Settings only.
