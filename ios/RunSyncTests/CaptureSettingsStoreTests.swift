import XCTest
@testable import RunSync

final class CaptureSettingsStoreTests: XCTestCase {
    func testDefaultsDisabledAndPersistsExplicitChoiceAndDevice() {
        let suiteName = "CaptureSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CaptureSettingsStore(defaults: defaults)

        XCTAssertEqual(store.load(), CaptureSettings(captureEnabled: false, selectedDeviceID: nil))
        let deviceID = UUID()
        store.setCaptureEnabled(true)
        store.setSelectedDeviceID(deviceID)

        let restored = CaptureSettingsStore(defaults: defaults).load()
        XCTAssertEqual(restored, CaptureSettings(captureEnabled: true, selectedDeviceID: deviceID))
    }
}
