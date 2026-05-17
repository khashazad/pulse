/// Thin Keychain Services wrapper for DietTracker.
/// Provides synchronous `read` / `write` / `delete` helpers over
/// `kSecClassGenericPassword` items keyed by `(service, account)`. Used by
/// `AuthSession` to persist the session token and to clean up legacy API-key
/// entries. UTF-8 string payloads only.
import Foundation
import Security

/// Stateless namespace exposing CRUD operations against the iOS Keychain for
/// generic-password items storing UTF-8 string values.
enum KeychainStore {
    /// Reads the string value stored at `(service, account)`.
    ///
    /// Inputs:
    /// - `service`: Keychain `kSecAttrService` identifier.
    /// - `account`: Keychain `kSecAttrAccount` identifier.
    ///
    /// Outputs: the decoded UTF-8 string, or `nil` if the item is missing or
    /// cannot be decoded.
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

    /// Upserts `value` at `(service, account)`, inserting with
    /// `kSecAttrAccessibleAfterFirstUnlock` if the item does not yet exist.
    ///
    /// Inputs:
    /// - `value`: UTF-8 string to persist.
    /// - `service`: Keychain `kSecAttrService` identifier.
    /// - `account`: Keychain `kSecAttrAccount` identifier.
    ///
    /// Outputs: `true` on successful update or insert, `false` otherwise.
    @discardableResult
    static func write(_ value: String, service: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Per Apple's docs, `kSecAttrAccessible` is an attribute of the item set at
        // insert time. Including it in `SecItemUpdate`'s attrs can produce spurious
        // failures, so the update payload is the data only.
        let attrs: [String: Any] = [kSecValueData as String: data]
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

    /// Deletes the item at `(service, account)` if present.
    ///
    /// Inputs:
    /// - `service`: Keychain `kSecAttrService` identifier.
    /// - `account`: Keychain `kSecAttrAccount` identifier.
    ///
    /// Outputs: `true` if the item was removed or was already absent, `false`
    /// on any other Keychain failure.
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


}
