import Foundation
import Security

/// Thin Keychain wrapper. API keys live here and nowhere else — never in
/// UserDefaults, never in exported files, never in logs.
///
/// Accessibility contract (round 17):
/// every item is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
///   - `AfterFirstUnlock` (not `WhenUnlocked`) because the 45 s sync loop
///     and in-flight background translation requests run while a
///     classroom continues in the locked background — tokens and the AI
///     key must stay readable there;
///   - `ThisDeviceOnly` because no secret should ever ride an iTunes /
///     iCloud backup onto a different device — restoring on new hardware
///     means signing in again, which is the honest tradeoff.
/// `set` migrates the accessibility of existing items in the same atomic
/// `SecItemUpdate` call that writes the value, and `upgradeAccessibility`
/// performs the one-time migration for items whose VALUE has not changed.
struct KeychainStore: Sendable {
    let service: String

    init(service: String = "com.livetranslate.ios") {
        self.service = service
    }

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        case dataConversion

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                return "Keychain operation failed (status \(status))."
            case .dataConversion:
                return "Keychain value could not be converted to UTF-8 data."
            }
        }
    }

    /// The accessibility every item of this store must carry. Computed —
    /// a stored static CFString is not concurrency-safe under Swift 6.
    private static var accessibility: CFString {
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }

    func set(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.dataConversion }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        // One atomic update: the value AND the accessibility migrate
        // together (an item written by an older build keeps its value and
        // gains ThisDeviceOnly in the same call).
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: Self.accessibility,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = Self.accessibility
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    func get(forKey key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataConversion
        }
        return string
    }

    func delete(forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// One-time accessibility migration for items this app owns: reads
    /// nothing, writes no value — only bumps `kSecAttrAccessible` to
    /// `AfterFirstUnlockThisDeviceOnly`. Idempotent; a locked device
    /// simply reports an error which the caller retries on a later
    /// launch. Never deletes an item.
    func upgradeAccessibility(forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let attrs = result as? [String: Any] else {
            return status == errSecItemNotFound // absent = nothing to do
        }
        if attrs[kSecAttrAccessible as String] as? String == Self.accessibility {
            return true
        }
        let update: [String: Any] = [
            kSecAttrAccessible as String: Self.accessibility,
        ]
        return SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess
    }
}
