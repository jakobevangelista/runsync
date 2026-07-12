import Foundation

enum InstallationIdentity {
    private static let key = "RunSyncInstallationID"

    static func loadOrCreate(defaults: UserDefaults = .standard) -> UUID {
        if let value = defaults.string(forKey: key), let identifier = UUID(uuidString: value) {
            return identifier
        }

        let identifier = UUID()
        defaults.set(identifier.uuidString, forKey: key)
        return identifier
    }
}
