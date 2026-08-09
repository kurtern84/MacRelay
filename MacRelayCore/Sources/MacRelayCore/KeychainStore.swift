import Foundation
import Security

public enum KeychainStore {
    public static func read(service: String, account: String) -> String {
        if let value = read(query: sharedIdentity(service: service, account: account)) {
            return value
        }

        let legacy = read(query: legacyIdentity(service: service, account: account)) ?? ""
        if !legacy.isEmpty {
            writeShared(legacy, service: service, account: account)
        }
        return legacy
    }

    public static func write(_ value: String, service: String, account: String) {
        if value.isEmpty {
            SecItemDelete(sharedIdentity(service: service, account: account) as CFDictionary)
            SecItemDelete(legacyIdentity(service: service, account: account) as CFDictionary)
            return
        }

        writeShared(value, service: service, account: account)
        writeLegacy(value, service: service, account: account)
    }

    private static func read(query identity: [String: Any]) -> String? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeShared(_ value: String, service: String, account: String) {
        let identity = sharedIdentity(service: service, account: account)
        SecItemDelete(identity as CFDictionary)
        var item = identity
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func writeLegacy(_ value: String, service: String, account: String) {
        let identity = legacyIdentity(service: service, account: account)
        let attributes = [kSecValueData as String: Data(value.utf8)]
        if SecItemUpdate(identity as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = Data(value.utf8)
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    private static func sharedIdentity(service: String, account: String) -> [String: Any] {
        // The shared group is first in each target's keychain-access-groups entitlement,
        // so Keychain Services selects the correctly signed team-prefixed group by default.
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true
        ]
    }

    private static func legacyIdentity(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
