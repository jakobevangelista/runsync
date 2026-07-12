import Foundation

actor TelemetryArchive {
    private let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? Self.defaultRootURL(fileManager: fileManager)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func append(_ envelope: TelemetryEnvelope) throws {
        let directory = try prepareRunDirectory(envelope.localRunID)
        var data = try encoder.encode(envelope)
        data.append(0x0A)
        try append(data, to: directory.appendingPathComponent("samples.ndjson"))
    }

    func appendAcknowledgements(_ identifiers: [UUID], runID: UUID) throws {
        guard !identifiers.isEmpty else { return }
        let directory = try prepareRunDirectory(runID)
        let fileURL = directory.appendingPathComponent("mock-acks.ndjson")
        for identifier in identifiers {
            var data = Data("{\"id\":\"\(identifier.uuidString)\"}".utf8)
            data.append(0x0A)
            try append(data, to: fileURL)
        }
    }

    func envelopes(runID: UUID) throws -> [TelemetryEnvelope] {
        let fileURL = runDirectory(runID).appendingPathComponent("samples.ndjson")
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        return try completeLines(in: Data(contentsOf: fileURL)).map { try decoder.decode(TelemetryEnvelope.self, from: $0) }
    }

    func acknowledgedIDs(runID: UUID) throws -> Set<UUID> {
        let fileURL = runDirectory(runID).appendingPathComponent("mock-acks.ndjson")
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }

        struct Acknowledgement: Decodable { let id: UUID }
        let values = try completeLines(in: Data(contentsOf: fileURL)).map {
            try decoder.decode(Acknowledgement.self, from: $0).id
        }
        return Set(values)
    }

    func pendingEnvelopes() throws -> [TelemetryEnvelope] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let directories = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var pending: [TelemetryEnvelope] = []
        for directory in directories {
            guard let runID = UUID(uuidString: directory.lastPathComponent) else { continue }
            let acknowledged = try acknowledgedIDs(runID: runID)
            pending.append(contentsOf: try envelopes(runID: runID).filter { !acknowledged.contains($0.id) })
        }
        return pending.sorted { $0.phoneReceivedAt < $1.phoneReceivedAt }
    }

    func deleteAll() throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.removeItem(at: rootURL)
        }
    }

    private func prepareRunDirectory(_ runID: UUID) throws -> URL {
        let directory = runDirectory(runID)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        return directory
    }

    private func runDirectory(_ runID: UUID) -> URL {
        rootURL.appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    private func append(_ data: Data, to fileURL: URL) throws {
        if !fileManager.fileExists(atPath: fileURL.path) {
            guard fileManager.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func completeLines(in data: Data) -> [Data] {
        let bytes: [UInt8] = Array(data)
        var lines: [Data] = bytes
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .map { Data($0) }
        if !data.isEmpty, data.last != 0x0A, !lines.isEmpty {
            lines.removeLast()
        }
        return lines
    }

    private static func defaultRootURL(fileManager: FileManager) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport
            .appendingPathComponent("RunSync", isDirectory: true)
            .appendingPathComponent("Runs", isDirectory: true)
    }
}
