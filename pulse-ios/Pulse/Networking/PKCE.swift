/// PKCE (RFC 7636) helpers for the Google OAuth sign-in flow.
/// Generates a high-entropy code verifier and its S256 challenge so the app can
/// prove possession of the verifier when redeeming the server's one-time
/// exchange code. The challenge travels through the (interceptable) browser
/// redirect; the verifier never leaves the app, so a hijacked callback cannot
/// be redeemed.
import Foundation
import CryptoKit

/// Namespace for PKCE verifier/challenge generation.
enum PKCE {
    /// Generates a base64url-encoded code verifier from 32 random bytes.
    /// Outputs: a 43-character verifier drawn from the RFC 7636 unreserved set.
    static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Fall back to a non-CSPRNG source only if SecRandom fails; vanishingly
            // unlikely, and still high-entropy enough to avoid a hard crash here.
            bytes = (0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        }
        return base64URLEncode(Data(bytes))
    }

    /// Computes the S256 challenge for a verifier: base64url(SHA256(verifier)).
    /// Inputs:
    ///   - verifier: the code verifier returned by `generateCodeVerifier()`.
    /// Outputs: the base64url-encoded SHA-256 digest with padding stripped.
    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    /// Encodes data as unpadded base64url (RFC 4648 §5).
    /// Inputs:
    ///   - data: bytes to encode.
    /// Outputs: base64url string with `+`→`-`, `/`→`_`, and `=` removed.
    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
