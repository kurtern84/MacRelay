import Foundation
import Security

enum KeychainStore {
    private static let service = "no.varion.MacRelay.NickServ"
    private static let ircPassService = "no.varion.MacRelay.IRCPass"

    static func password(for profileID: UUID) -> String {
        read(service: service, profileID: profileID)
    }

    @discardableResult
    static func setPassword(_ password: String, for profileID: UUID) -> Bool {
        write(password, service: service, profileID: profileID)
    }

    static func removePassword(for profileID: UUID) {
        remove(service: service, profileID: profileID)
    }

    static func ircPassword(for profileID: UUID) -> String {
        read(service: ircPassService, profileID: profileID)
    }

    @discardableResult
    static func setIRCPassword(_ password: String, for profileID: UUID) -> Bool {
        write(password, service: ircPassService, profileID: profileID)
    }

    static func removeIRCPassword(for profileID: UUID) {
        remove(service: ircPassService, profileID: profileID)
    }

    private static func read(service: String, profileID: UUID) -> String {
        if let value = read(query: sharedIdentity(service: service, profileID: profileID)) {
            return value
        }

        let legacy = read(query: legacyIdentity(service: service, profileID: profileID)) ?? ""
        if !legacy.isEmpty {
            _ = writeShared(legacy, service: service, profileID: profileID)
        }
        return legacy
    }

    private static func write(_ value: String, service: String, profileID: UUID) -> Bool {
        if value.isEmpty {
            remove(service: service, profileID: profileID)
            return true
        }

        let sharedResult = writeShared(value, service: service, profileID: profileID)
        let localResult = writeLegacy(value, service: service, profileID: profileID)
        return sharedResult || localResult
    }

    private static func read(query identity: [String: Any]) -> String? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeShared(_ value: String, service: String, profileID: UUID) -> Bool {
        let identity = sharedIdentity(service: service, profileID: profileID)
        SecItemDelete(identity as CFDictionary)
        var item = identity
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func writeLegacy(_ value: String, service: String, profileID: UUID) -> Bool {
        let identity = legacyIdentity(service: service, profileID: profileID)
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = Data(value.utf8)
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    private static func remove(service: String, profileID: UUID) {
        SecItemDelete(sharedIdentity(service: service, profileID: profileID) as CFDictionary)
        SecItemDelete(legacyIdentity(service: service, profileID: profileID) as CFDictionary)
    }

    private static func sharedIdentity(service: String, profileID: UUID) -> [String: Any] {
        // The shared group is first in each target's keychain-access-groups entitlement,
        // so Keychain Services selects the correctly signed team-prefixed group by default.
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecAttrSynchronizable as String: true
        ]
    }

    private static func legacyIdentity(service: String, profileID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString
        ]
    }
}
