import Foundation

public struct SyncedServerProfiles: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let profiles: [ServerConfiguration]
    public let selectedProfileID: UUID?
    public let updatedAt: Date

    public init(
        schemaVersion: Int = 1,
        profiles: [ServerConfiguration],
        selectedProfileID: UUID?,
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.selectedProfileID = selectedProfileID
        self.updatedAt = updatedAt
    }
}

public enum ICloudProfileStore {
    public static let key = "MacRelay.shared.serverProfiles.v1"

    public static func synchronize() {
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    public static func load() -> SyncedServerProfiles? {
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: key),
              let payload = try? JSONDecoder().decode(SyncedServerProfiles.self, from: data),
              payload.schemaVersion == 1,
              !payload.profiles.isEmpty
        else { return nil }
        return payload
    }

    public static func publish(profiles: [ServerConfiguration], selectedProfileID: UUID?) {
        guard !profiles.isEmpty else { return }
        if let existing = load(),
           existing.profiles == profiles,
           existing.selectedProfileID == selectedProfileID {
            return
        }

        let payload = SyncedServerProfiles(profiles: profiles, selectedProfileID: selectedProfileID)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let store = NSUbiquitousKeyValueStore.default
        store.set(data, forKey: key)
        store.synchronize()
    }
}
