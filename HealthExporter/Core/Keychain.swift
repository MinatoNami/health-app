import Foundation
import Security

/// Keychain-backed storage for the upload credential.
///
/// The bearer token used to be part of `sync-settings.json`. A file-backed
/// store is the right home for anchors and preferences, but not for a
/// credential that grants write access to a health archive: the file is
/// readable by anything that can read the app container, and a plaintext secret
/// on disk survives in ways a Keychain item does not.
///
/// `ThisDeviceOnly` is not incidental. The default accessibility syncs items to
/// iCloud Keychain, and App Store Review Guideline 5.1.3 prohibits health
/// information — including anything that unlocks it — leaving the device that
/// way. `AfterFirstUnlock` rather than `WhenUnlocked` because background sync
/// runs while the screen is locked.
final class Keychain {
    static let shared = Keychain()

    enum Account: String {
        case bearerToken = "sink.bearer-token"
    }

    private let service: String

    private init() {
        self.service = (Bundle.main.bundleIdentifier ?? "com.lionelchong.HealthExporter") + ".secrets"
    }

    // MARK: - Access

    var bearerToken: String {
        get { string(for: .bearerToken) ?? "" }
        set { set(newValue, for: .bearerToken) }
    }

    func string(for account: Account) -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                Log.shared.warn("keychain", "Read failed for \(account.rawValue): OSStatus \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func set(_ value: String, for account: Account) -> Bool {
        guard !value.isEmpty else { return delete(account) }
        guard let data = value.data(using: .utf8) else { return false }

        let query = baseQuery(for: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        // Update first: SecItemAdd fails with errSecDuplicateItem once a value
        // exists, so add-then-update would silently keep the stale token.
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        if updated != errSecItemNotFound {
            Log.shared.error("keychain", "Update failed for \(account.rawValue): OSStatus \(updated)")
            return false
        }

        var insert = query
        insert.merge(attributes) { _, new in new }
        let added = SecItemAdd(insert as CFDictionary, nil)
        if added != errSecSuccess {
            Log.shared.error("keychain", "Write failed for \(account.rawValue): OSStatus \(added)")
        }
        return added == errSecSuccess
    }

    @discardableResult
    func delete(_ account: Account) -> Bool {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(for account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }
}
