# Google OAuth Login (iOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the manual API-key + base-URL setup with a Google sign-in flow that uses `ASWebAuthenticationSession` against the backend, persists an opaque session token in Keychain, and sends `Authorization: Bearer <token>` on every API call.

**Architecture:** Single-user gate now, multi-user-ready. iOS opens `<baseURL>/auth/google/start` in `ASWebAuthenticationSession`; backend handles the OAuth handshake and 302s back to `diettracker://auth?token=…&email=…`. Token + email stored in Keychain. New `AuthSession` `@Observable` owns auth state; `AppSettings` shrinks to a thin holder of the build-embedded base URL. Hard cutover — `?user_key=` and `X-API-Key` are dropped entirely.

**Tech Stack:** Swift 5.9, SwiftUI, iOS 17+, `@Observable`, `ASWebAuthenticationSession`, `URLSession`, Keychain (`kSecClassGenericPassword`), xcodegen, xcconfig.

**Spec:** `docs/superpowers/specs/2026-05-09-google-oauth-login-ios-design.md`

---

## File Structure

| Action | Path | Responsibility |
|---|---|---|
| Modify | `DietTracker/Config/Constants.swift` | Drops `userKey`, `Defaults.baseURL`. Adds `baseURL: URL` (from Info.plist) + new Keychain identifiers. |
| Create | `DietTracker/Config/BuildConfig.xcconfig` | Pulls `DIET_TRACKER_BASE_URL` from env into Info.plist `BaseURL`. |
| Modify | `DietTracker/Config/KeychainStore.swift` | Parameterize on `(service, account)`. |
| Modify | `DietTracker/State/AppSettings.swift` | Shrink to a thin holder; drop URL/key fields, `isConfigured`, `makeClient`. |
| Create | `DietTracker/State/AuthSession.swift` | Auth state machine; bootstrap, sign-in, sign-out, callback handling, `makeClient()`. |
| Create | `DietTracker/Networking/AuthCallbackParser.swift` | Pure parser: callback URL → `(token, email)` or error. |
| Create | `DietTracker/Models/WhoAmI.swift` | Codable DTO for `/auth/whoami`. |
| Modify | `DietTracker/Networking/DietTrackerError.swift` | Add `.signInCancelled`, `.signInFailed(reason:)`; renames `.notConfigured` → `.notSignedIn` (cleanup task). |
| Modify | `DietTracker/Networking/DietTrackerClient.swift` | `init(baseURL:sessionToken:)`; `Authorization: Bearer`; drop every `?user_key=`. Add `whoami()`, `logout()`. |
| Create | `DietTracker/Views/Auth/LoginView.swift` | Single-screen "Continue with Google". |
| Modify | `DietTracker/Views/RootView.swift` | Gate on `auth.isSignedIn`; bootstrap on `.task`. |
| Modify | `DietTracker/Views/SettingsView.swift` | Drop URL/key fields; show email + Sign Out. |
| Modify | `DietTracker/DietTrackerApp.swift` | Instantiate `AuthSession` and inject. |
| Modify | `DietTracker/State/{DayMacro,Week,Month,Year,Meals,ContainersList,ContainerEdit}Model.swift` | Take `auth: AuthSession?` instead of `settings: AppSettings?`. |
| Modify | `DietTracker/Views/{DayMacro,Week,Month,Year,Meals,MealDetail}View.swift` + `Views/Prep/*` | Pass `auth` to models; use `auth.makeClient()` for photo requests. |
| Modify | `project.yml` | Reference `BuildConfig.xcconfig`; add Run Script verifying `BaseURL` is non-empty. |
| Modify | `DietTrackerTests/DietTrackerClientTests.swift` | Bearer header asserts; drop `user_key=` query asserts; add `/auth/whoami` + `/auth/logout` tests. |
| Modify | `DietTrackerTests/ContainerClientTests.swift` | Same: Bearer; no `user_key=`. |
| Create | `DietTrackerTests/AuthCallbackParserTests.swift` | Parser tests. |
| Create | `DietTrackerTests/AuthSessionTests.swift` | Bootstrap, callback, sign-out, handleUnauthorized. |
| Create | `DietTrackerTests/KeychainStoreTests.swift` | Round-trip; parameterized. |
| Create | `DietTrackerTests/Fixtures/whoami.json` | Whoami fixture. |

---

## Common Commands

Build (full):
```bash
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Test (all):
```bash
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

Single test:
```bash
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:DietTrackerTests/CLASS/method
```

Regenerate project (after `project.yml` edits):
```bash
xcodegen generate
```

Set the build URL (every shell that builds):
```bash
export DIET_TRACKER_BASE_URL="https://your-server.example.com"
```

---

## Phase 1 — Foundation (additive, zero behavior change)

### Task 1: Generalize KeychainStore to (service, account)

**Files:**
- Modify: `DietTracker/Config/KeychainStore.swift`
- Create: `DietTrackerTests/KeychainStoreTests.swift`

Goal: `KeychainStore.read/write/delete` take `(service:, account:)`. Keep a no-arg convenience that uses the legacy `Constants.Keychain.service/account` so `AppSettings` continues to compile until later tasks remove it.

- [ ] **Step 1: Write failing test**

Create `DietTrackerTests/KeychainStoreTests.swift`:

```swift
import XCTest
@testable import DietTracker

final class KeychainStoreTests: XCTestCase {
    private let service = "com.khxsh.diettracker.test"
    private let account = "kc-test-\(UUID().uuidString)"

    override func tearDown() {
        _ = KeychainStore.delete(service: service, account: account)
        super.tearDown()
    }

    func testWriteThenReadRoundTrip() {
        XCTAssertTrue(KeychainStore.write("hello", service: service, account: account))
        XCTAssertEqual(KeychainStore.read(service: service, account: account), "hello")
    }

    func testWriteOverwrites() {
        _ = KeychainStore.write("a", service: service, account: account)
        _ = KeychainStore.write("b", service: service, account: account)
        XCTAssertEqual(KeychainStore.read(service: service, account: account), "b")
    }

    func testDeleteRemovesValue() {
        _ = KeychainStore.write("x", service: service, account: account)
        XCTAssertTrue(KeychainStore.delete(service: service, account: account))
        XCTAssertNil(KeychainStore.read(service: service, account: account))
    }

    func testDeleteOfMissingItemReturnsTrue() {
        XCTAssertTrue(KeychainStore.delete(service: service, account: "nope-\(UUID().uuidString)"))
    }

    func testReadOfMissingItemReturnsNil() {
        XCTAssertNil(KeychainStore.read(service: service, account: "nope-\(UUID().uuidString)"))
    }
}
```

- [ ] **Step 2: Run tests; expect compile failure**

```bash
xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:DietTrackerTests/KeychainStoreTests
```

Expected: compile error — `KeychainStore` doesn't accept those parameters yet.

- [ ] **Step 3: Update `KeychainStore`**

Replace `DietTracker/Config/KeychainStore.swift`:

```swift
import Foundation
import Security

enum KeychainStore {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    @discardableResult
    static func write(_ value: String, service: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // Legacy convenience used by AppSettings until the cutover task removes it.
    static func read() -> String? {
        read(service: Constants.Keychain.service, account: Constants.Keychain.account)
    }

    @discardableResult
    static func write(_ value: String) -> Bool {
        write(value, service: Constants.Keychain.service, account: Constants.Keychain.account)
    }

    @discardableResult
    static func delete() -> Bool {
        delete(service: Constants.Keychain.service, account: Constants.Keychain.account)
    }
}
```

- [ ] **Step 4: Run tests; expect pass**

```bash
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:DietTrackerTests/KeychainStoreTests
```

Expected: 5 tests pass.

- [ ] **Step 5: Run full test suite to confirm no regressions**

```bash
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add DietTracker/Config/KeychainStore.swift DietTrackerTests/KeychainStoreTests.swift
git commit -m "refactor(keychain): parameterize on (service, account)"
```

---

### Task 2: Add new error cases for sign-in

**Files:**
- Modify: `DietTracker/Networking/DietTrackerError.swift`

Goal: additive — `.signInCancelled` and `.signInFailed(reason: String)`. Existing call sites untouched. (`.notConfigured` is renamed to `.notSignedIn` only in the final cleanup task; until then it stays.)

- [ ] **Step 1: Update `DietTrackerError.swift`**

Replace the file:

```swift
import Foundation

enum DietTrackerError: Error, Equatable {
    case notConfigured
    case unauthorized
    case notFound
    case payloadTooLarge
    case network(URLError)
    case decoding(String)
    case server(status: Int)
    case signInCancelled
    case signInFailed(reason: String)

    static func == (lhs: DietTrackerError, rhs: DietTrackerError) -> Bool {
        switch (lhs, rhs) {
        case (.notConfigured, .notConfigured),
             (.unauthorized, .unauthorized),
             (.notFound, .notFound),
             (.payloadTooLarge, .payloadTooLarge),
             (.signInCancelled, .signInCancelled):
            return true
        case let (.network(a), .network(b)):
            return a.code == b.code
        case let (.decoding(a), .decoding(b)):
            return a == b
        case let (.server(a), .server(b)):
            return a == b
        case let (.signInFailed(a), .signInFailed(b)):
            return a == b
        default:
            return false
        }
    }

    var userMessage: String {
        switch self {
        case .notConfigured:    return "Set the server URL and API key in Settings."
        case .unauthorized:     return "Sign in again."
        case .notFound:         return "No data for this date."
        case .payloadTooLarge:  return "That image is too large. Try a smaller photo."
        case .network:          return "Network error. Check your connection."
        case .decoding:         return "Couldn't read the server response."
        case .server(let s):    return "Server error (\(s)). Try again."
        case .signInCancelled:  return "Sign-in cancelled."
        case .signInFailed(let reason):
            switch reason {
            case "access_denied":         return "Sign-in cancelled."
            case "not_allowed":           return "This Google account isn't allowed on this server."
            case "invalid_state":         return "Sign-in expired, please try again."
            case "invalid_callback":      return "Sign-in failed. Please try again."
            case "keychain_write_failed": return "Couldn't save sign-in. Check device storage."
            default:                      return "Something went wrong. Please try again."
            }
        }
    }
}
```

- [ ] **Step 2: Run full test suite**

```bash
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

Expected: all green (additive change).

- [ ] **Step 3: Commit**

```bash
git add DietTracker/Networking/DietTrackerError.swift
git commit -m "feat(error): add signInCancelled + signInFailed cases"
```

---

### Task 3: WhoAmI model

**Files:**
- Create: `DietTracker/Models/WhoAmI.swift`
- Create: `DietTrackerTests/Fixtures/whoami.json`

- [ ] **Step 1: Add fixture**

Create `DietTrackerTests/Fixtures/whoami.json`:

```json
{
  "email": "khashzd@gmail.com",
  "expires_at": "2026-08-07T12:00:00Z"
}
```

- [ ] **Step 2: Write failing test**

Add to a new `DietTrackerTests/WhoAmITests.swift`:

```swift
import XCTest
@testable import DietTracker

final class WhoAmITests: XCTestCase {
    func testDecodesFromFixture() throws {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(forResource: "whoami", withExtension: "json")!
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder.dietTrackerDefault()
        let result = try decoder.decode(WhoAmI.self, from: data)
        XCTAssertEqual(result.email, "khashzd@gmail.com")
        XCTAssertEqual(
            result.expiresAt.timeIntervalSince1970,
            ISO8601DateFormatter().date(from: "2026-08-07T12:00:00Z")!.timeIntervalSince1970,
            accuracy: 1
        )
    }
}
```

- [ ] **Step 3: Verify test fails (compile error: `WhoAmI` undefined)**

```bash
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:DietTrackerTests/WhoAmITests
```

Expected: compile error.

- [ ] **Step 4: Implement `WhoAmI`**

Create `DietTracker/Models/WhoAmI.swift`:

```swift
import Foundation

struct WhoAmI: Decodable, Equatable {
    let email: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case email
        case expiresAt = "expires_at"
    }
}
```

- [ ] **Step 5: Run test; expect pass**

```bash
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:DietTrackerTests/WhoAmITests
```

Expected: pass.

- [ ] **Step 6: Wire fixture into the test bundle by regenerating**

```bash
xcodegen generate
```

(xcodegen picks up new files under the test target by directory glob; if it doesn't, ensure `DietTrackerTests/Fixtures/whoami.json` is included in the bundle's resources — `project.yml` `sources: - path: DietTrackerTests` already covers it.)

- [ ] **Step 7: Commit**

```bash
git add DietTracker/Models/WhoAmI.swift DietTrackerTests/WhoAmITests.swift DietTrackerTests/Fixtures/whoami.json
git commit -m "feat(models): WhoAmI DTO"
```

---

### Task 4: AuthCallbackParser

**Files:**
- Create: `DietTracker/Networking/AuthCallbackParser.swift`
- Create: `DietTrackerTests/AuthCallbackParserTests.swift`

Pure URL parser — no networking, no state. Returns `Result<(token, email), DietTrackerError>` so unit tests can exercise every branch without ASWebAuth.

- [ ] **Step 1: Write failing tests**

Create `DietTrackerTests/AuthCallbackParserTests.swift`:

```swift
import XCTest
@testable import DietTracker

final class AuthCallbackParserTests: XCTestCase {
    func testParsesTokenAndEmail() {
        let url = URL(string: "diettracker://auth?token=abc123&email=khashzd%40gmail.com")!
        switch AuthCallbackParser.parse(url) {
        case .success(let creds):
            XCTAssertEqual(creds.token, "abc123")
            XCTAssertEqual(creds.email, "khashzd@gmail.com")
        case .failure(let e):
            XCTFail("Expected success, got \(e)")
        }
    }

    func testNotAllowedError() {
        let url = URL(string: "diettracker://auth?error=not_allowed")!
        switch AuthCallbackParser.parse(url) {
        case .success: XCTFail("Expected failure")
        case .failure(let e): XCTAssertEqual(e, .signInFailed(reason: "not_allowed"))
        }
    }

    func testAccessDeniedError() {
        let url = URL(string: "diettracker://auth?error=access_denied")!
        if case .failure(let e) = AuthCallbackParser.parse(url) {
            XCTAssertEqual(e, .signInFailed(reason: "access_denied"))
        } else { XCTFail() }
    }

    func testInvalidStateError() {
        let url = URL(string: "diettracker://auth?error=invalid_state")!
        if case .failure(let e) = AuthCallbackParser.parse(url) {
            XCTAssertEqual(e, .signInFailed(reason: "invalid_state"))
        } else { XCTFail() }
    }

    func testServerError() {
        let url = URL(string: "diettracker://auth?error=server_error")!
        if case .failure(let e) = AuthCallbackParser.parse(url) {
            XCTAssertEqual(e, .signInFailed(reason: "server_error"))
        } else { XCTFail() }
    }

    func testMissingTokenIsInvalidCallback() {
        let url = URL(string: "diettracker://auth?email=foo%40bar.com")!
        if case .failure(let e) = AuthCallbackParser.parse(url) {
            XCTAssertEqual(e, .signInFailed(reason: "invalid_callback"))
        } else { XCTFail() }
    }

    func testMissingEmailIsInvalidCallback() {
        let url = URL(string: "diettracker://auth?token=abc")!
        if case .failure(let e) = AuthCallbackParser.parse(url) {
            XCTAssertEqual(e, .signInFailed(reason: "invalid_callback"))
        } else { XCTFail() }
    }

    func testEmptyQueryIsInvalidCallback() {
        let url = URL(string: "diettracker://auth")!
        if case .failure(let e) = AuthCallbackParser.parse(url) {
            XCTAssertEqual(e, .signInFailed(reason: "invalid_callback"))
        } else { XCTFail() }
    }
}
```

- [ ] **Step 2: Run; expect compile failure**

```bash
xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:DietTrackerTests/AuthCallbackParserTests
```

- [ ] **Step 3: Implement parser**

Create `DietTracker/Networking/AuthCallbackParser.swift`:

```swift
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
```

- [ ] **Step 4: Run; expect pass**

```bash
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:DietTrackerTests/AuthCallbackParserTests
```

Expected: 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add DietTracker/Networking/AuthCallbackParser.swift DietTrackerTests/AuthCallbackParserTests.swift
git commit -m "feat(auth): AuthCallbackParser pure URL parser"
```

---

## Phase 2 — Network cutover

### Task 5: Switch DietTrackerClient to Bearer auth + drop user_key

**Files:**
- Modify: `DietTracker/Networking/DietTrackerClient.swift`
- Modify: `DietTracker/State/AppSettings.swift` (compile-fix only — `makeClient` passes the existing `apiKey` field as `sessionToken`)
- Modify: `DietTrackerTests/DietTrackerClientTests.swift`
- Modify: `DietTrackerTests/ContainerClientTests.swift`

Goal: Single commit cutover of the network layer. After this, every iOS request uses `Authorization: Bearer <token>` and there's no `?user_key=`. UX still uses the old "user pastes a token" Settings UI temporarily — that's swapped out in later tasks.

- [ ] **Step 1: Rewrite DietTrackerClient**

Replace `DietTracker/Networking/DietTrackerClient.swift`:

```swift
import Foundation

actor DietTrackerClient {
    private let baseURL: URL
    private let sessionToken: String
    private let session: URLSession
    private let decoder: JSONDecoder

    init(baseURL: URL, sessionToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.sessionToken = sessionToken
        self.session = session
        self.decoder = JSONDecoder.dietTrackerDefault()
    }

    // MARK: - read endpoints

    func summary(date: Date) async throws -> DailySummary {
        let url = try makeURL(path: "/summary/\(DateOnly.string(from: date))", query: [])
        return try await fetch(url: url)
    }

    func logs(from: Date, to: Date) async throws -> LogsList {
        let url = try makeURL(
            path: "/logs",
            query: [
                URLQueryItem(name: "from", value: DateOnly.string(from: from)),
                URLQueryItem(name: "to", value: DateOnly.string(from: to)),
            ]
        )
        return try await fetch(url: url)
    }

    func meals() async throws -> [MealSummary] {
        let url = try makeURL(path: "/meals", query: [])
        let envelope: MealsListResponse = try await fetch(url: url)
        return envelope.meals
    }

    func meal(id: UUID) async throws -> Meal {
        let url = try makeURL(path: "/meals/\(id.uuidString.lowercased())", query: [])
        return try await fetch(url: url)
    }

    // MARK: - containers

    func listContainers() async throws -> [Container] {
        let url = try makeURL(path: "/containers", query: [])
        let list: ContainersList = try await fetch(url: url)
        return list.containers
    }

    func getContainer(id: UUID) async throws -> Container {
        let url = try makeURL(path: "/containers/\(id.uuidString.lowercased())", query: [])
        return try await fetch(url: url)
    }

    func createContainer(name: String, tareWeightG: Double) async throws -> Container {
        let url = try makeURL(path: "/containers", query: [])
        let body: [String: Any] = ["name": name, "tare_weight_g": tareWeightG]
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        return try await sendJSON(url: url, method: "POST", body: data)
    }

    func updateContainer(id: UUID, name: String?, tareWeightG: Double?) async throws -> Container {
        var fields: [String: Any] = [:]
        if let name { fields["name"] = name }
        if let tareWeightG { fields["tare_weight_g"] = tareWeightG }
        let url = try makeURL(path: "/containers/\(id.uuidString.lowercased())", query: [])
        let data = try JSONSerialization.data(withJSONObject: fields, options: [])
        return try await sendJSON(url: url, method: "PATCH", body: data)
    }

    func deleteContainer(id: UUID) async throws {
        let url = try makeURL(path: "/containers/\(id.uuidString.lowercased())", query: [])
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        applyAuth(&req)
        try await sendNoBody(request: req)
    }

    func uploadContainerPhoto(id: UUID, jpegData: Data) async throws {
        let url = try makeURL(path: "/containers/\(id.uuidString.lowercased())/photo", query: [])
        let boundary = "----DietTrackerBoundary\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        applyAuth(&req)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.multipartBody(
            boundary: boundary,
            fieldName: "file",
            filename: "photo.jpg",
            mimeType: "image/jpeg",
            data: jpegData
        )
        try await sendNoBody(request: req)
    }

    func deleteContainerPhoto(id: UUID) async throws {
        let url = try makeURL(path: "/containers/\(id.uuidString.lowercased())/photo", query: [])
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        applyAuth(&req)
        try await sendNoBody(request: req)
    }

    nonisolated func containerPhotoRequest(id: UUID, size: ContainerPhotoSize) -> URLRequest {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("/containers/\(id.uuidString.lowercased())/photo"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "size", value: size.rawValue)]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        return req
    }

    // MARK: - auth endpoints

    func whoami() async throws -> WhoAmI {
        let url = try makeURL(path: "/auth/whoami", query: [])
        return try await fetch(url: url)
    }

    func logout() async throws {
        let url = try makeURL(path: "/auth/logout", query: [])
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyAuth(&req)
        try await sendNoBody(request: req)
    }

    // MARK: - private helpers

    private func makeURL(path: String, query: [URLQueryItem]) throws -> URL {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw DietTrackerError.notConfigured
        }
        comps.queryItems = query.isEmpty ? nil : query
        guard let url = comps.url else { throw DietTrackerError.notConfigured }
        return url
    }

    private func applyAuth(_ req: inout URLRequest) {
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
    }

    private func fetch<T: Decodable>(url: URL) async throws -> T {
        var req = URLRequest(url: url)
        applyAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await sendDecoded(request: req)
    }

    private func sendJSON<T: Decodable>(url: URL, method: String, body: Data) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = method
        applyAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body
        return try await sendDecoded(request: req)
    }

    private func sendDecoded<T: Decodable>(request: URLRequest) async throws -> T {
        let (data, http) = try await raw(request: request)
        try mapStatus(http.statusCode)
        do {
            return try decoder.decode(T.self, from: data)
        } catch let decodingError {
            throw DietTrackerError.decoding(String(describing: decodingError))
        }
    }

    private func sendNoBody(request: URLRequest) async throws {
        let (_, http) = try await raw(request: request)
        try mapStatus(http.statusCode)
    }

    private func raw(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DietTrackerError.server(status: -1)
            }
            return (data, http)
        } catch let urlError as URLError {
            throw DietTrackerError.network(urlError)
        }
    }

    private func mapStatus(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw DietTrackerError.unauthorized
        case 404:      throw DietTrackerError.notFound
        case 413:      throw DietTrackerError.payloadTooLarge
        default:       throw DietTrackerError.server(status: status)
        }
    }

    private static func multipartBody(
        boundary: String,
        fieldName: String,
        filename: String,
        mimeType: String,
        data: Data
    ) -> Data {
        var body = Data()
        let lineBreak = "\r\n"
        body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        body.append(data)
        body.append("\(lineBreak)--\(boundary)--\(lineBreak)".data(using: .utf8)!)
        return body
    }
}
```

- [ ] **Step 2: Update `AppSettings.makeClient` to pass new param name**

Edit `DietTracker/State/AppSettings.swift` lines 36–41:

Replace:
```swift
    func makeClient() -> DietTrackerClient? {
        guard let url = normalizedBaseURL else { return nil }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }
        return DietTrackerClient(baseURL: url, apiKey: trimmedKey)
    }
```

with:
```swift
    func makeClient() -> DietTrackerClient? {
        guard let url = normalizedBaseURL else { return nil }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }
        return DietTrackerClient(baseURL: url, sessionToken: trimmedKey)
    }
```

- [ ] **Step 3: Update DietTrackerClientTests**

Replace the body of `DietTrackerTests/DietTrackerClientTests.swift` (keep the `StubURLProtocol` class at the top intact):

```swift
import XCTest
@testable import DietTracker

final class StubURLProtocol: URLProtocol {
    static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class DietTrackerClientTests: XCTestCase {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(forResource: name, withExtension: "json")!
        return try Data(contentsOf: url)
    }

    private func makeClient() -> DietTrackerClient {
        DietTrackerClient(
            baseURL: URL(string: "https://example.test")!,
            sessionToken: "session-abc",
            session: makeSession()
        )
    }

    override func tearDown() {
        StubURLProtocol.responder = nil
        super.tearDown()
    }

    func testSummaryRequestSendsBearerAndNoUserKey() async throws {
        let summaryJSON = try loadFixture("summary")
        var capturedRequest: URLRequest?
        StubURLProtocol.responder = { req in
            capturedRequest = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, summaryJSON)
        }

        let date = DateOnly.formatter.date(from: "2026-05-06")!
        let summary = try await makeClient().summary(date: date)

        XCTAssertEqual(summary.target.calories, 2200)
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer session-abc")
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "X-API-Key"))
        XCTAssertEqual(capturedRequest?.url?.path, "/summary/2026-05-06")
        XCTAssertNil(capturedRequest?.url?.query)
    }

    func testLogsRequestUsesFromAndToParamsWithoutUserKey() async throws {
        let logsJSON = try loadFixture("logs")
        var capturedURL: URL?
        StubURLProtocol.responder = { req in
            capturedURL = req.url
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, logsJSON)
        }
        let from = DateOnly.formatter.date(from: "2026-04-30")!
        let to = DateOnly.formatter.date(from: "2026-05-06")!
        let list = try await makeClient().logs(from: from, to: to)

        XCTAssertEqual(list.logs.count, 7)
        XCTAssertEqual(capturedURL?.path, "/logs")
        let q = capturedURL?.query ?? ""
        XCTAssertTrue(q.contains("from=2026-04-30"))
        XCTAssertTrue(q.contains("to=2026-05-06"))
        XCTAssertFalse(q.contains("user_key"))
    }

    func test401MapsToUnauthorized() async throws {
        StubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let date = DateOnly.formatter.date(from: "2026-05-06")!
        do {
            _ = try await makeClient().summary(date: date)
            XCTFail("Expected unauthorized error")
        } catch let error as DietTrackerError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func test404MapsToNotFound() async throws {
        StubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let date = DateOnly.formatter.date(from: "2026-05-06")!
        do {
            _ = try await makeClient().summary(date: date)
            XCTFail("Expected notFound error")
        } catch let error as DietTrackerError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testWhoAmIDecodes() async throws {
        let whoami = try loadFixture("whoami")
        var capturedURL: URL?
        var capturedAuth: String?
        StubURLProtocol.responder = { req in
            capturedURL = req.url
            capturedAuth = req.value(forHTTPHeaderField: "Authorization")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, whoami)
        }
        let result = try await makeClient().whoami()
        XCTAssertEqual(result.email, "khashzd@gmail.com")
        XCTAssertEqual(capturedURL?.path, "/auth/whoami")
        XCTAssertEqual(capturedAuth, "Bearer session-abc")
    }

    func testLogoutSendsPostWithBearer() async throws {
        var captured: URLRequest?
        StubURLProtocol.responder = { req in
            captured = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        try await makeClient().logout()
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.path, "/auth/logout")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-abc")
    }
}
```

- [ ] **Step 4: Update ContainerClientTests**

Open `DietTrackerTests/ContainerClientTests.swift`. Update the `makeClient` helper at lines 18–22 from:

```swift
    private func makeClient() -> DietTrackerClient {
        DietTrackerClient(
            baseURL: URL(string: "https://example.test")!,
            apiKey: "k",
```

to:

```swift
    private func makeClient() -> DietTrackerClient {
        DietTrackerClient(
            baseURL: URL(string: "https://example.test")!,
            sessionToken: "session-k",
```

Then update the assertions:
- Line 42 — replace `XCTAssertEqual(captured?.url?.query, "user_key=khash")` with `XCTAssertNil(captured?.url?.query)`.
- Line 43 — replace `XCTAssertEqual(captured?.value(forHTTPHeaderField: "X-API-Key"), "k")` with `XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")`.
- Line 136 — replace `XCTAssertEqual(req.value(forHTTPHeaderField: "X-API-Key"), "k")` with `XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer session-k")`.
- Line 139 — replace `XCTAssertTrue(req.url?.query?.contains("user_key=khash") ?? false)` with `XCTAssertTrue(req.url?.query?.contains("size=") ?? false)` and `XCTAssertFalse(req.url?.query?.contains("user_key") ?? true)`.

(If any other test in this file asserts `user_key` or `X-API-Key`, apply the same pattern.)

- [ ] **Step 5: Run all tests**

```bash
xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

Expected: all green. The app currently builds with bearer transport (still using the user-pasted token from Settings).

- [ ] **Step 6: Commit**

```bash
git add DietTracker/Networking/DietTrackerClient.swift DietTracker/State/AppSettings.swift DietTrackerTests/DietTrackerClientTests.swift DietTrackerTests/ContainerClientTests.swift
git commit -m "refactor(net): switch DietTrackerClient to Bearer auth, drop user_key"
```

---

## Phase 3 — AuthSession + UX cutover

### Task 6: Add Constants for new Keychain identifiers

**Files:**
- Modify: `DietTracker/Config/Constants.swift`

Goal: Reserve the new Keychain identifiers used by `AuthSession`. Don't remove any existing constant yet — the cleanup task does that.

- [ ] **Step 1: Update Constants**

Replace `DietTracker/Config/Constants.swift`:

```swift
import Foundation

enum Constants {
    static let userKey = "khash"   // removed in cleanup task

    enum Defaults {
        static let baseURL = "diettracker.baseURL"   // removed in cleanup task
    }

    enum Keychain {
        // Legacy API-key item (cleanup task removes references and proactively deletes the item once on launch).
        static let service = "com.khxsh.diettracker.apikey"
        static let account = "default"

        // New session blob written by AuthSession.
        static let sessionService = "com.khxsh.diettracker.session"
        static let sessionAccount = "default"
    }

    enum Auth {
        static let callbackScheme = "diettracker"
        static let startPath = "/auth/google/start"
    }
}
```

- [ ] **Step 2: Run all tests**

```bash
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

Expected: all green.

- [ ] **Step 3: Commit**

```bash
git add DietTracker/Config/Constants.swift
git commit -m "feat(constants): reserve session Keychain id + auth scheme"
```

---

### Task 7: AuthSession — init reads Keychain

**Files:**
- Create: `DietTracker/State/AuthSession.swift`
- Create: `DietTrackerTests/AuthSessionTests.swift`

Build AuthSession in slices. This task only covers `init` — reads Keychain optimistically.

- [ ] **Step 1: Write failing test**

Create `DietTrackerTests/AuthSessionTests.swift`:

```swift
import XCTest
@testable import DietTracker

final class AuthSessionTests: XCTestCase {
    private let testService = "com.khxsh.diettracker.session.test"
    private let testAccount = "auth-test-\(UUID().uuidString)"

    private func writeStoredSession(token: String, email: String) {
        let json = #"{"token":"\#(token)","email":"\#(email)"}"#
        _ = KeychainStore.write(json, service: testService, account: testAccount)
    }

    private func clearStoredSession() {
        _ = KeychainStore.delete(service: testService, account: testAccount)
    }

    override func tearDown() {
        clearStoredSession()
        super.tearDown()
    }

    func testInitWithStoredSessionStartsSignedIn() {
        writeStoredSession(token: "tok", email: "khashzd@gmail.com")
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount
        )
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertEqual(auth.email, "khashzd@gmail.com")
    }

    func testInitWithNoStoredSessionStartsSignedOut() {
        clearStoredSession()
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount
        )
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(auth.email)
    }

    func testInitWithCorruptedKeychainBlobStartsSignedOut() {
        _ = KeychainStore.write("not-json", service: testService, account: testAccount)
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount
        )
        XCTAssertFalse(auth.isSignedIn)
    }
}
```

- [ ] **Step 2: Run; expect compile failure**

```bash
xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:DietTrackerTests/AuthSessionTests
```

- [ ] **Step 3: Implement initial `AuthSession`**

Create `DietTracker/State/AuthSession.swift`:

```swift
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
```

- [ ] **Step 4: Run; expect pass**

```bash
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:DietTrackerTests/AuthSessionTests
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add DietTracker/State/AuthSession.swift DietTrackerTests/AuthSessionTests.swift
git commit -m "feat(auth): AuthSession scaffold with stored-session init"
```

---

### Task 8: AuthSession — handle sign-in callback

**Files:**
- Modify: `DietTracker/State/AuthSession.swift`
- Modify: `DietTrackerTests/AuthSessionTests.swift`

- [ ] **Step 1: Add failing tests**

Append to `DietTrackerTests/AuthSessionTests.swift`:

```swift
extension AuthSessionTests {
    func testHandleCallbackSuccessSignsInAndPersists() {
        clearStoredSession()
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount
        )
        auth.handleSignInCallback(url: URL(string: "diettracker://auth?token=t1&email=khashzd%40gmail.com")!)
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertEqual(auth.email, "khashzd@gmail.com")
        // Persisted across a fresh AuthSession?
        let fresh = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount
        )
        XCTAssertTrue(fresh.isSignedIn)
        XCTAssertEqual(fresh.email, "khashzd@gmail.com")
    }

    func testHandleCallbackErrorTransitionsToError() {
        clearStoredSession()
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount
        )
        auth.handleSignInCallback(url: URL(string: "diettracker://auth?error=not_allowed")!)
        if case .error(let e) = auth.state {
            XCTAssertEqual(e, .signInFailed(reason: "not_allowed"))
        } else {
            XCTFail("Expected .error state, got \(auth.state)")
        }
        XCTAssertFalse(auth.isSignedIn)
    }
}
```

- [ ] **Step 2: Run; expect compile failure**

```bash
xcodebuild ... test -only-testing:DietTrackerTests/AuthSessionTests
```

(Use the standard test command above; abbreviated here for brevity.)

- [ ] **Step 3: Add `handleSignInCallback`**

Append to `AuthSession`:

```swift
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
```

- [ ] **Step 4: Run; expect pass**

- [ ] **Step 5: Commit**

```bash
git add DietTracker/State/AuthSession.swift DietTrackerTests/AuthSessionTests.swift
git commit -m "feat(auth): handleSignInCallback applies parsed credentials"
```

---

### Task 9: AuthSession — bootstrap (whoami)

**Files:**
- Modify: `DietTracker/State/AuthSession.swift`
- Modify: `DietTrackerTests/AuthSessionTests.swift`

`bootstrap()` calls `GET /auth/whoami` if Keychain has a token. 200 → no-op. 401 → clear Keychain, sign out. Network error → keep optimistic state.

- [ ] **Step 1: Add failing tests**

Append to `DietTrackerTests/AuthSessionTests.swift`:

```swift
extension AuthSessionTests {
    private func makeStubSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    func testBootstrapHappyPathStaysSignedIn() async {
        writeStoredSession(token: "tok", email: "khashzd@gmail.com")
        StubURLProtocol.responder = { req in
            let body = #"{"email":"khashzd@gmail.com","expires_at":"2026-08-07T12:00:00Z"}"#
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body.data(using: .utf8)!)
        }
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount,
            urlSession: makeStubSession()
        )
        await auth.bootstrap()
        XCTAssertTrue(auth.isSignedIn)
        StubURLProtocol.responder = nil
    }

    func testBootstrap401SignsOutAndClearsKeychain() async {
        writeStoredSession(token: "tok", email: "khashzd@gmail.com")
        StubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount,
            urlSession: makeStubSession()
        )
        await auth.bootstrap()
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(KeychainStore.read(service: testService, account: testAccount))
        StubURLProtocol.responder = nil
    }

    func testBootstrapNetworkErrorKeepsOptimisticSignedIn() async {
        writeStoredSession(token: "tok", email: "khashzd@gmail.com")
        StubURLProtocol.responder = { _ in
            // Simulate by returning an unparseable status code; raw() will throw .server(-1) → bootstrap ignores non-401.
            let resp = HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount,
            urlSession: makeStubSession()
        )
        await auth.bootstrap()
        XCTAssertTrue(auth.isSignedIn)
        StubURLProtocol.responder = nil
    }

    func testBootstrapWithNoStoredTokenIsNoOp() async {
        clearStoredSession()
        var hit = false
        StubURLProtocol.responder = { req in
            hit = true
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount,
            urlSession: makeStubSession()
        )
        await auth.bootstrap()
        XCTAssertFalse(hit)
        XCTAssertFalse(auth.isSignedIn)
        StubURLProtocol.responder = nil
    }
}
```

- [ ] **Step 2: Add `bootstrap()` and helpers to `AuthSession`**

Append to `AuthSession`:

```swift
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
```

- [ ] **Step 3: Run; expect pass**

- [ ] **Step 4: Commit**

```bash
git add DietTracker/State/AuthSession.swift DietTrackerTests/AuthSessionTests.swift
git commit -m "feat(auth): bootstrap revalidates stored token via whoami"
```

---

### Task 10: AuthSession — signOut

**Files:**
- Modify: `DietTracker/State/AuthSession.swift`
- Modify: `DietTrackerTests/AuthSessionTests.swift`

- [ ] **Step 1: Add failing tests**

Append:

```swift
extension AuthSessionTests {
    func testSignOutClearsLocalStateOn204() async {
        writeStoredSession(token: "tok", email: "khashzd@gmail.com")
        StubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount,
            urlSession: makeStubSession()
        )
        await auth.signOut()
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(KeychainStore.read(service: testService, account: testAccount))
        StubURLProtocol.responder = nil
    }

    func testSignOutClearsLocalStateOnServerError() async {
        writeStoredSession(token: "tok", email: "khashzd@gmail.com")
        StubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount,
            urlSession: makeStubSession()
        )
        await auth.signOut()
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(KeychainStore.read(service: testService, account: testAccount))
        StubURLProtocol.responder = nil
    }
}
```

- [ ] **Step 2: Add `signOut()`**

Append to `AuthSession`:

```swift
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
```

- [ ] **Step 3: Run; expect pass**

- [ ] **Step 4: Commit**

```bash
git add DietTracker/State/AuthSession.swift DietTrackerTests/AuthSessionTests.swift
git commit -m "feat(auth): signOut best-effort revoke + local clear"
```

---

### Task 11: AuthSession — makeClient + signInWithGoogle

**Files:**
- Modify: `DietTracker/State/AuthSession.swift`
- Modify: `DietTrackerTests/AuthSessionTests.swift`

`makeClient()` returns nil when not signed in. `signInWithGoogle()` wraps `ASWebAuthenticationSession`; we only test that it bails when the platform can't present (no presentation anchor in test env), and that a programmatic callback handler does the right thing — the ASWebAuth dance itself is covered by the AuthCallbackParser tests + manual smoke.

- [ ] **Step 1: Add tests**

Append:

```swift
extension AuthSessionTests {
    func testMakeClientNilWhenSignedOut() {
        clearStoredSession()
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount
        )
        XCTAssertNil(auth.makeClient())
    }

    func testMakeClientNonNilWhenSignedIn() {
        writeStoredSession(token: "tok", email: "khashzd@gmail.com")
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount
        )
        XCTAssertNotNil(auth.makeClient())
    }

    func testStartSignInURLBuildsCorrectly() {
        let auth = AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: testService,
            keychainAccount: testAccount
        )
        let url = auth.startSignInURL()
        XCTAssertEqual(url.absoluteString, "https://example.test/auth/google/start")
    }
}
```

- [ ] **Step 2: Add `makeClient`, `startSignInURL`, and `signInWithGoogle`**

Append to `AuthSession`:

```swift
    func makeClient() -> DietTrackerClient? {
        guard let token = storedToken else { return nil }
        return DietTrackerClient(baseURL: baseURL, sessionToken: token, session: urlSession)
    }

    func startSignInURL() -> URL {
        baseURL.appendingPathComponent(Constants.Auth.startPath)
    }
```

Then add the ASWebAuth wrapper in a separate extension at the bottom of the file:

```swift
import AuthenticationServices

@MainActor
extension AuthSession {
    func signInWithGoogle(presentationAnchor: ASPresentationAnchor) async {
        state = .signingIn
        let url = startSignInURL()
        do {
            let callback = try await Self.startWebAuth(
                url: url,
                callbackScheme: Constants.Auth.callbackScheme,
                presentationAnchor: presentationAnchor
            )
            handleSignInCallback(url: callback)
        } catch let asError as ASWebAuthenticationSessionError where asError.code == .canceledLogin {
            state = .signedOut
        } catch {
            state = .error(.signInFailed(reason: "invalid_callback"))
        }
    }

    private static func startWebAuth(
        url: URL,
        callbackScheme: String,
        presentationAnchor: ASPresentationAnchor
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callback, error in
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
            if !session.start() {
                continuation.resume(throwing: DietTrackerError.signInFailed(reason: "invalid_callback"))
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
```

- [ ] **Step 3: Run all tests**

```bash
xcodebuild ... test
```

Expected: green. The ASWebAuth dance itself isn't tested — only the URL it opens is.

- [ ] **Step 4: Commit**

```bash
git add DietTracker/State/AuthSession.swift DietTrackerTests/AuthSessionTests.swift
git commit -m "feat(auth): signInWithGoogle wraps ASWebAuthenticationSession"
```

---

### Task 12: Migrate State models from AppSettings to AuthSession

**Files (modify):**
- `DietTracker/State/DayMacroModel.swift`
- `DietTracker/State/WeekModel.swift`
- `DietTracker/State/MonthModel.swift`
- `DietTracker/State/YearModel.swift`
- `DietTracker/State/MealsModel.swift`
- `DietTracker/State/ContainersListModel.swift`
- `DietTracker/State/ContainerEditModel.swift`

Goal: every model that takes `settings: AppSettings` now takes `auth: AuthSession`. They call `auth?.makeClient()`. Behavior identical.

- [ ] **Step 1: Update `DayMacroModel.swift`**

Replace:

```swift
import Foundation
import Observation

@Observable
final class DayMacroModel {
    let date: Date
    private(set) var state: LoadState<DailySummary> = .idle
    private weak var auth: AuthSession?

    init(date: Date, auth: AuthSession) {
        self.date = date
        self.auth = auth
    }

    func load() async {
        guard let client = auth?.makeClient() else {
            state = .failed(.notConfigured)
            return
        }
        state = .loading
        do {
            let summary = try await client.summary(date: date)
            state = .loaded(summary)
        } catch let error as DietTrackerError {
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }
}
```

- [ ] **Step 2: Update `WeekModel.swift`**

Change `private weak var settings: AppSettings?` to `private weak var auth: AuthSession?`. Change `init(settings: AppSettings)` to `init(auth: AuthSession)`. Inside: `self.auth = auth`. Replace the `settings?.makeClient()` line with `auth?.makeClient()`. Leave the rest (static helpers, etc.) unchanged.

- [ ] **Step 3: Apply the same edits to `MonthModel.swift`, `YearModel.swift`, `MealsModel.swift`** (and `MealDetailModel` in the same file)**, `ContainersListModel.swift`, `ContainerEditModel.swift`**.

For `MealsModel.swift` both `MealsModel` and `MealDetailModel` need updates.

For `ContainerEditModel.swift`, change init signature `init(existing: Container? = nil, settings: AppSettings)` → `init(existing: Container? = nil, auth: AuthSession)`. Internal `settings.makeClient()` → `auth.makeClient()`.

For `ContainersListModel.swift`, both `load()` and `delete()` paths.

- [ ] **Step 4: Build (don't run tests yet — views still pass `settings:`)**

```bash
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: build will fail because views pass `settings:` to these models. That's the next task.

- [ ] **Step 5: Stage but don't commit yet** — combine with Task 13 since the build is broken between them.

---

### Task 13: Migrate Views to AuthSession

**Files (modify):**
- `DietTracker/Views/DayMacroView.swift`
- `DietTracker/Views/WeekView.swift`
- `DietTracker/Views/MonthView.swift`
- `DietTracker/Views/YearView.swift`
- `DietTracker/Views/MealsView.swift`
- `DietTracker/Views/MealDetailView.swift`
- `DietTracker/Views/Prep/ContainersListView.swift`
- `DietTracker/Views/Prep/ContainerEditView.swift`

Goal: every view that constructs one of the migrated models switches `settings: settings` → `auth: auth`. Photo-request paths use `auth.makeClient()`.

- [ ] **Step 1: `DayMacroView.swift`**

Find at line 5:

```swift
    @Environment(AppSettings.self) private var settings
```

Replace with:

```swift
    @Environment(AuthSession.self) private var auth
```

Find at line 29:

```swift
            if model == nil { model = DayMacroModel(date: date, settings: settings) }
```

Replace with:

```swift
            if model == nil { model = DayMacroModel(date: date, auth: auth) }
```

- [ ] **Step 2: Apply the same `settings` → `auth` substitution in `WeekView`, `MonthView`, `YearView`, `MealsView`, `MealDetailView`** (in MealDetailView line 35: `model = MealDetailModel(mealId: summary.id, auth: auth)`).

- [ ] **Step 3: `Prep/ContainersListView.swift`**

Two `@Environment(AppSettings.self) private var settings` declarations — at lines 4 and 103. Replace both with `@Environment(AuthSession.self) private var auth`.

Also lines 36 and 42 (`environment(settings)`) — change to `environment(auth)`.

Line 98 (`if model == nil { model = ContainersListModel(settings: settings) }`) — change to `model = ContainersListModel(auth: auth)`.

Line 128 (`if container.hasPhoto, let client = settings.makeClient()`) — change to `if container.hasPhoto, let client = auth.makeClient()`.

- [ ] **Step 4: `Prep/ContainerEditView.swift`**

Line 6 (`@Environment(AppSettings.self) private var settings`) → `@Environment(AuthSession.self) private var auth`.

Line 112 (`model = ContainerEditModel(existing: existing, settings: settings)`) → `model = ContainerEditModel(existing: existing, auth: auth)`.

Line 122 (`else if let id = model?.existingPhotoId, let client = settings.makeClient()`) → `else if let id = model?.existingPhotoId, let client = auth.makeClient()`.

- [ ] **Step 5: Build (don't run yet — RootView/SettingsView/App not yet migrated)**

```bash
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: still failing — `RootView`, `SettingsView`, `DietTrackerApp` haven't been touched.

- [ ] **Step 6: Continue to Task 14 without committing.**

---

### Task 14: Login + RootView + SettingsView + App rewire

**Files:**
- Create: `DietTracker/Views/Auth/LoginView.swift`
- Modify: `DietTracker/Views/RootView.swift`
- Modify: `DietTracker/Views/SettingsView.swift`
- Modify: `DietTracker/DietTrackerApp.swift`

This is the UX cutover. After this task: build green, app uses Google login.

- [ ] **Step 1: Create `LoginView.swift`**

Create `DietTracker/Views/Auth/LoginView.swift`:

```swift
import SwiftUI
import UIKit

struct LoginView: View {
    @Environment(AuthSession.self) private var auth

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Text("Diet Tracker")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.FG.primary)
                Text("Sign in to sync with your server.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.FG.tertiary)
                    .multilineTextAlignment(.center)
                Spacer()
                Button(action: signIn) {
                    HStack(spacing: 10) {
                        if isSigningIn {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(Theme.BG.primary)
                        } else {
                            Image(systemName: "g.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                            Text("Continue with Google")
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .foregroundStyle(Theme.BG.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.CTP.mauve)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(isSigningIn)
                .padding(.horizontal, 24)

                if case .error(let err) = auth.state {
                    Text(err.userMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.CTP.peach)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Spacer().frame(height: 40)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var isSigningIn: Bool {
        if case .signingIn = auth.state { return true } else { return false }
    }

    private func signIn() {
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene),
            let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        else { return }
        Task { @MainActor in
            await auth.signInWithGoogle(presentationAnchor: window)
        }
    }
}
```

- [ ] **Step 2: Replace `RootView.swift`**

```swift
import SwiftUI

struct RootView: View {
    @Environment(AuthSession.self) private var auth

    @State private var tab: DockTab = .log
    @State private var logPath = NavigationPath()
    @State private var mealsPath = NavigationPath()
    @State private var prepPath = NavigationPath()
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.BG.primary.ignoresSafeArea()

            Group {
                switch tab {
                case .log:
                    NavigationStack(path: $logPath) {
                        LogView(onOpenDate: { picked in
                            logPath.append(picked)
                        })
                        .toolbar { settingsButton }
                        .navigationDestination(for: Date.self) { date in
                            DayMacroView(date: date)
                                .toolbar { settingsButton }
                        }
                    }
                case .meals:
                    NavigationStack(path: $mealsPath) {
                        MealsView(onOpen: { summary in
                            mealsPath.append(summary)
                        })
                        .toolbar { settingsButton }
                        .navigationDestination(for: MealSummary.self) { summary in
                            MealDetailView(summary: summary)
                                .toolbar { settingsButton }
                        }
                    }
                case .prep:
                    NavigationStack(path: $prepPath) {
                        PrepView()
                            .toolbar { settingsButton }
                    }
                }
            }

            if dockVisible {
                FloatingDock(tab: $tab)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 4)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: .constant(!auth.isSignedIn && !showSettings)) {
            LoginView()
                .interactiveDismissDisabled()
        }
        .task {
            await auth.bootstrap()
        }
    }

    private var dockVisible: Bool {
        switch tab {
        case .log:   logPath.isEmpty
        case .meals: mealsPath.isEmpty
        case .prep:  prepPath.isEmpty
        }
    }

    @ToolbarContentBuilder
    private var settingsButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(Theme.CTP.mauve)
            }
        }
    }
}
```

- [ ] **Step 3: Replace `SettingsView.swift`**

```swift
import SwiftUI

struct SettingsView: View {
    @Environment(AuthSession.self) private var auth
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.secondary.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        section(header: "Account") {
                            row(label: "Email") {
                                Text(auth.email ?? "—")
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Theme.CTP.mauve)
                            }
                            Rectangle().fill(Theme.separator).frame(height: 0.5)
                            row(label: "Server") {
                                Text(Constants.baseURL.absoluteString)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(Theme.FG.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }

                        Button {
                            Task { @MainActor in
                                await auth.signOut()
                                dismiss()
                            }
                        } label: {
                            Text("Sign Out")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.CTP.peach)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .padding(.horizontal, 16)

                        section(header: "Theme") {
                            row(label: "Palette") {
                                HStack(spacing: 8) {
                                    HStack(spacing: 3) {
                                        ForEach([Theme.CTP.blue, Theme.CTP.mauve, Theme.CTP.pink, Theme.CTP.peach, Theme.CTP.green], id: \.self.description) { color in
                                            Circle().fill(color).frame(width: 10, height: 10)
                                        }
                                    }
                                    Text("Macchiato")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Theme.FG.primary)
                                }
                            }
                            Rectangle().fill(Theme.separator).frame(height: 0.5)
                            row(label: "Appearance") {
                                Text("Always dark")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.FG.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.BG.secondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.CTP.mauve)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func section<Content: View>(
        header: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.FG.secondary)
                    .padding(.horizontal, 16)
            }
            VStack(spacing: 0) { content() }
                .ctpCard()
                .padding(.horizontal, 16)
            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.FG.tertiary)
                    .padding(.horizontal, 20)
            }
        }
    }

    private func row<Trailing: View>(
        label: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.FG.primary)
                .frame(minWidth: 70, alignment: .leading)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

#Preview {
    SettingsView()
        .environment(AuthSession(baseURL: URL(string: "https://example.test")!))
}
```

(Note: this preview will start `.signedOut` because no Keychain entry; that's fine.)

- [ ] **Step 4: Replace `DietTrackerApp.swift`**

```swift
import SwiftUI

@main
struct DietTrackerApp: App {
    @State private var settings = AppSettings()
    @State private var auth = AuthSession(baseURL: Constants.baseURL)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(auth)
                .preferredColorScheme(.dark)
                .tint(Theme.tint)
        }
    }
}
```

(Constants.baseURL doesn't exist yet — Task 15 sets that up. We'll temporarily expose a stop-gap in Constants in this task only if the build fails before Task 15. To keep this task green, add this stub to `Constants` *now* and remove it in Task 15:)

In `DietTracker/Config/Constants.swift`, add temporarily inside `enum Constants`:

```swift
    /// Stop-gap until BuildConfig.xcconfig wiring lands in Task 15.
    static var baseURL: URL {
        URL(string: ProcessInfo.processInfo.environment["DIET_TRACKER_BASE_URL"] ?? "https://example.test")!
    }
```

- [ ] **Step 5: Run xcodegen + tests + build**

```bash
xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

Expected: green. (Test target uses no env var; the stop-gap fallback `https://example.test` keeps decoding tests happy.)

- [ ] **Step 6: Commit (combines Tasks 12, 13, 14)**

```bash
git add DietTracker/State/*.swift DietTracker/Views DietTracker/DietTrackerApp.swift DietTracker/Config/Constants.swift
git commit -m "feat(auth): cut UX over to AuthSession + LoginView"
```

---

### Task 15: Build-time URL injection via xcconfig

**Files:**
- Create: `DietTracker/Config/BuildConfig.xcconfig`
- Modify: `project.yml`
- Modify: `DietTracker/Config/Constants.swift`
- Modify: `DietTracker/Info.plist`

Goal: replace the env-fallback stop-gap with a real build-setting → Info.plist → `Bundle` chain.

- [ ] **Step 1: Create xcconfig**

Create `DietTracker/Config/BuildConfig.xcconfig`:

```
// Pulled from the shell via xcodegen; baked into Info.plist as BaseURL.
DIET_TRACKER_BASE_URL = ${DIET_TRACKER_BASE_URL}
INFOPLIST_KEY_BaseURL = $(DIET_TRACKER_BASE_URL)
```

xcodegen interpolates `${DIET_TRACKER_BASE_URL}` from the shell at generation time, baking the value into the build setting. Xcode then substitutes `$(DIET_TRACKER_BASE_URL)` into the Info.plist key at build time.

- [ ] **Step 2: Update `project.yml`**

Add to the `DietTracker` target (top-level keys, not under `settings.base`):

```yaml
    configFiles:
      Debug: DietTracker/Config/BuildConfig.xcconfig
      Release: DietTracker/Config/BuildConfig.xcconfig
    preBuildScripts:
      - name: Verify BaseURL
        script: |
          if [ -z "${DIET_TRACKER_BASE_URL}" ]; then
            echo "error: DIET_TRACKER_BASE_URL not set in environment at build time. Export it before xcodebuild."
            exit 1
          fi
        basedOnDependencyAnalysis: false
```

- [ ] **Step 3: Add the Info.plist key**

Edit `DietTracker/Info.plist` to add (inside the top-level `<dict>`):

```xml
<key>BaseURL</key>
<string>$(DIET_TRACKER_BASE_URL)</string>
```

(Place it near the other top-level entries; the exact position doesn't matter.)

- [ ] **Step 4: Replace the stop-gap `Constants.baseURL`**

Replace the temporary computed property in `Constants.swift` with:

```swift
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
```

- [ ] **Step 5: Regenerate + build**

```bash
export DIET_TRACKER_BASE_URL="https://your-server.example.com"
xcodegen generate
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: build green. Without the env var, the preBuildScripts step fails the build with a clear message.

- [ ] **Step 6: Tests**

The test target will read its own Info.plist, which doesn't define `BaseURL`. The fatalError would crash tests on first access. Two safe options; pick one:

- (a) Move the access to `AppSettings`/`AuthSession` only and ensure tests construct them with explicit `baseURL:` (already true for `AuthSession` tests). `Constants.baseURL` is then only read from `DietTrackerApp.swift`, which the test target doesn't execute.
- (b) Add the same `BaseURL` key to `DietTrackerTests/Info.plist`, with a test value `https://example.test`.

Use (b) for safety. Open `DietTrackerTests/Info.plist` and add:

```xml
<key>BaseURL</key>
<string>https://example.test</string>
```

Then run tests:

```bash
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

Expected: green.

- [ ] **Step 7: Commit**

```bash
git add DietTracker/Config/BuildConfig.xcconfig project.yml DietTracker/Info.plist DietTrackerTests/Info.plist DietTracker/Config/Constants.swift
git commit -m "feat(build): wire DIET_TRACKER_BASE_URL through xcconfig + Info.plist"
```

---

## Phase 4 — Cleanup

### Task 16: Drop legacy AppSettings fields, Constants, fixture leftovers

**Files:**
- Modify: `DietTracker/State/AppSettings.swift`
- Modify: `DietTracker/Config/Constants.swift`
- Modify: `DietTracker/Config/KeychainStore.swift`
- Modify: `DietTracker/Networking/DietTrackerError.swift`
- Modify: every remaining `*.swift` that references `.notConfigured`

Goal: hard cutover finishes — drop everything the new flow doesn't need; rename `.notConfigured` → `.notSignedIn`.

- [ ] **Step 1: Shrink `AppSettings.swift`**

Replace with:

```swift
import Foundation
import Observation

@Observable
final class AppSettings {
    // Reserved for future static config (theme, units, etc.). Currently empty
    // because all auth state moved to AuthSession and the base URL is build-embedded.
    init() {}
}
```

- [ ] **Step 2: Drop unused `Constants`**

Replace `Constants.swift`:

```swift
import Foundation

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
        static let sessionAccount = "default"

        // Legacy API-key item identifiers, kept here ONLY so a one-shot deletion
        // in AuthSession.init can clean up old installs. Reference is removed in
        // the next release.
        static let legacyService = "com.khxsh.diettracker.apikey"
        static let legacyAccount = "default"
    }

    enum Auth {
        static let callbackScheme = "diettracker"
        static let startPath = "/auth/google/start"
    }
}
```

- [ ] **Step 3: Drop the no-arg KeychainStore convenience**

Open `KeychainStore.swift` and delete the three legacy convenience methods (`read()`, `write(_:)`, `delete()` without parameters) at the bottom of the file.

- [ ] **Step 4: One-shot legacy Keychain delete in `AuthSession.init`**

Append at the end of `AuthSession.init`:

```swift
        // One-shot cleanup of the previous API-key Keychain item; safe if absent.
        _ = KeychainStore.delete(
            service: Constants.Keychain.legacyService,
            account: Constants.Keychain.legacyAccount
        )
```

- [ ] **Step 5: Rename `.notConfigured` → `.notSignedIn`**

Edit `DietTrackerError.swift`:
- Replace every occurrence of `notConfigured` with `notSignedIn` (case declaration, equality, userMessage).
- Update `userMessage`: `case .notSignedIn: return "Sign in to continue."`.

Update every model that throws/returns `.notConfigured`:
- `DayMacroModel.swift`, `WeekModel.swift`, `MonthModel.swift`, `YearModel.swift`, `MealsModel.swift` (both classes), `ContainersListModel.swift`, `ContainerEditModel.swift`. Replace `state = .failed(.notConfigured)` and `error = .notConfigured` with the new case.

Update `DietTrackerClient.swift` `makeURL` — its two `throw DietTrackerError.notConfigured` calls should also use `.notSignedIn` (those are URL-construction failures; rename for consistency).

- [ ] **Step 6: Run all tests**

```bash
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

Expected: green. If any test still references `.notConfigured` (none should after the rename), update it.

- [ ] **Step 7: Commit**

```bash
git add DietTracker DietTrackerTests
git commit -m "refactor(auth): drop legacy AppSettings/Constants; rename to notSignedIn"
```

---

### Task 17: Manual smoke + final verification

- [ ] **Step 1: Confirm `xcodegen generate` is clean**

```bash
xcodegen generate
```

Expected: no warnings about missing variables.

- [ ] **Step 2: Build for simulator with the env var unset**

```bash
unset DIET_TRACKER_BASE_URL
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: build fails on the preBuildScripts "Verify BaseURL" phase with a clear message.

- [ ] **Step 3: Build with the env var set**

```bash
export DIET_TRACKER_BASE_URL="https://your-server.example.com"
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: build green.

- [ ] **Step 4: Full test run**

```bash
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

Expected: green.

- [ ] **Step 5: Manual smoke (requires the server-side spec to be implemented and running with Google OAuth configured)**

In a paired iOS simulator, install and run the app:
1. First launch → `LoginView` appears (no Settings sheet behind it).
2. Tap "Continue with Google" → ASWebAuthenticationSession opens; complete the Google flow.
3. App lands on the Log tab with the day's data loaded.
4. Open Settings → email + server URL shown; "Sign Out" visible.
5. Tap Sign Out → returns to `LoginView`.
6. Sign in again → kill the app → re-launch → goes straight to Log tab (token persisted).
7. From the server, delete the session row → next API call → app drops back to `LoginView`.

If any step fails, file as a follow-up; do not regress earlier tasks.

- [ ] **Step 6: Final commit if any minor fixes were needed during smoke**

```bash
git status
# Address any leftover changes; commit if non-trivial.
```

---

## Self-review (verify before handing off to executor)

Spec coverage:

- [x] Build-time URL injection (env → xcconfig → Info.plist → Bundle): Tasks 15, 16
- [x] Hard cutover from `?user_key=` + `X-API-Key`: Task 5
- [x] AuthSession state machine (`.signedOut/.signingIn/.signedIn/.error`): Tasks 7–11
- [x] AuthCallbackParser pure helper with all documented error codes: Task 4
- [x] Keychain blob (token + email together, atomic): Task 7
- [x] Bootstrap with `whoami` + offline grace + 401 handling: Task 9
- [x] Sign-out best-effort revoke + local clear: Task 10
- [x] ASWebAuthenticationSession not registered as URL type: project.yml change in Task 15 only adds `configFiles`/`preBuildScripts`, no `CFBundleURLTypes`
- [x] LoginView, Settings rewire, RootView gate: Task 14
- [x] Models migrated to AuthSession: Task 12
- [x] Tests for client headers, callback parser, AuthSession, Keychain, WhoAmI: Tasks 1, 3, 4, 5, 7–11
- [x] Cleanup of legacy fields + notConfigured rename: Task 16
- [x] Manual smoke checklist: Task 17

Type/signature consistency:

- `KeychainStore.read/write/delete(service:account:)` consistent across Tasks 1, 7+.
- `AuthSession.makeClient()` returns `DietTrackerClient?`, returning `nil` when not signed in — used by all migrated models in Task 12.
- `AuthCallbackParser.parse(_:) -> Result<Credentials, DietTrackerError>` consistent across Tasks 4, 8.
- `DietTrackerClient.init(baseURL:sessionToken:)` consistent across Tasks 5, 7, 9–11.
- `Constants.Auth.callbackScheme` / `Constants.Auth.startPath` used in Tasks 6, 11.
- `Constants.Keychain.sessionService` / `sessionAccount` used in Tasks 6, 7+.
- `BaseURL` Info.plist key consistent across Tasks 14 (stop-gap), 15 (real), 16 (final).

No placeholders found.

---

## Open questions to resolve during implementation

These were left open in the spec; they're judgement calls the implementer should resolve in-task and surface in the PR description:

- ASWebAuthenticationSession presentation anchor on iOS 17 scene apps — Task 14 step 1 uses a "first foreground-active scene's key window" heuristic; verify on a real device, refine if needed.
- Whether the test target's Info.plist needs the `BaseURL` key (Task 15 step 6, option b). If you remove that, ensure no test path reaches `Constants.baseURL`.
- Token URL encoding from the server (base64url vs hex) — `AuthCallbackParser` accepts any non-empty string, so no iOS change required.
