@preconcurrency import ConnectIQ
import Foundation

final class GarminDeviceStore {
    private let archiveURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RunSync", isDirectory: true)
        self.archiveURL = directory.appendingPathComponent("garmin-devices.archive")
    }

    func save(_ devices: [IQDevice]) throws {
        let directory = archiveURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let dictionary = NSMutableDictionary()
        for device in devices {
            dictionary[device.uuid.uuidString] = device
        }
        let data = try NSKeyedArchiver.archivedData(withRootObject: dictionary, requiringSecureCoding: true)
        try data.write(to: archiveURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func load() -> [IQDevice] {
        guard let data = try? Data(contentsOf: archiveURL),
              let dictionary = try? NSKeyedUnarchiver.unarchivedObject(
                ofClasses: [NSMutableDictionary.self, IQDevice.self, NSString.self, NSUUID.self],
                from: data
              ) as? NSDictionary else {
            return []
        }
        return dictionary.allValues.compactMap { $0 as? IQDevice }
    }
}
