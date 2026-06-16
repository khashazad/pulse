// PulseTests/Support/AuthSessionStub.swift
import Foundation
@testable import Pulse

/// Test-only factory producing a signed-in `AuthSession` backed by a stub
/// `URLSession`. Mirrors the keychain-write-then-construct mechanism every
/// model/store test uses (see `ViewModelLoadTests`, `ReachableBranchTests`):
/// the init reads the seeded token from its dedicated keychain slot and lands
/// in `.signedIn`, so `makeClient()` returns a client over the stub session.
extension AuthSession {
    /// Builds a signed-in session over a stub `URLSession`.
    /// Inputs:
    ///   - session: the stub `URLSession` the produced client should use.
    ///   - keychainService: keychain service name for the seeded session item.
    ///   - keychainAccount: keychain account name for the seeded session item.
    /// Outputs: a signed-in `AuthSession` whose `makeClient()` uses `session`.
    static func signedInStub(
        session: URLSession,
        keychainService: String,
        keychainAccount: String
    ) -> AuthSession {
        _ = KeychainStore.write(
            #"{"token":"tok","email":"k@e.com"}"#,
            service: keychainService,
            account: keychainAccount
        )
        return AuthSession(
            baseURL: URL(string: "https://example.test")!,
            keychainService: keychainService,
            keychainAccount: keychainAccount,
            urlSession: session
        )
    }
}
