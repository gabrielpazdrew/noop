// Fork-only (phone-hub). Foundation + Security only: compiled into NOOPiOS AND NOOPiOSHubTests.
import Foundation
import Security

/// The phone's hub token, one generic-password Keychain item. Accessible after first unlock and
/// this device only (never iCloud Keychain, never a backup), so a Bluetooth wake on a locked phone
/// can still upload. The token is never logged, never put in UserDefaults, never shown again after
/// it is saved. Same delete-then-add shape as upstream's OuraTokenStore / AIKeyStore.
enum HubKeychain {
    static let service = "noop.hub"
    static let account = "phone-token"
    static let maxTokenLength = 4096

    static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func addAttributes(for data: Data) -> [String: Any] {
        var attrs = baseQuery()
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attrs[kSecAttrSynchronizable as String] = false
        return attrs
    }

    /// Trims the paste; nil if empty, too long, or with whitespace inside (a bad paste).
    static func normalizedToken(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= maxTokenLength,
              t.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return t
    }

    /// Store (or replace) the token. False if the paste is invalid or the Keychain write fails.
    @discardableResult
    static func saveToken(_ raw: String) -> Bool {
        guard let token = normalizedToken(raw) else { return false }
        SecItemDelete(baseQuery() as CFDictionary)
        return SecItemAdd(addAttributes(for: Data(token.utf8)) as CFDictionary, nil) == errSecSuccess
    }

    /// The token for HubClient (T4.1). nil if none is stored.
    static func readToken() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func deleteToken() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// True when a token is stored. Does not read the token's bytes.
    static var hasToken: Bool {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
