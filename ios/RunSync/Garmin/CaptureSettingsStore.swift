import Foundation

struct CaptureSettings: Equatable, Sendable {
    var captureEnabled: Bool
    var selectedDeviceID: UUID?
}

final class CaptureSettingsStore: @unchecked Sendable {
    private enum Key {
        static let captureEnabled = "capture.enabled"
        static let selectedDeviceID = "capture.selectedDeviceID"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> CaptureSettings {
        lock.withLock {
            CaptureSettings(
                captureEnabled: defaults.bool(forKey: Key.captureEnabled),
                selectedDeviceID: defaults.string(forKey: Key.selectedDeviceID).flatMap(UUID.init(uuidString:))
            )
        }
    }

    func setCaptureEnabled(_ enabled: Bool) {
        lock.withLock { defaults.set(enabled, forKey: Key.captureEnabled) }
    }

    func setSelectedDeviceID(_ deviceID: UUID?) {
        lock.withLock {
            if let deviceID {
                defaults.set(deviceID.uuidString, forKey: Key.selectedDeviceID)
            } else {
                defaults.removeObject(forKey: Key.selectedDeviceID)
            }
        }
    }
}
