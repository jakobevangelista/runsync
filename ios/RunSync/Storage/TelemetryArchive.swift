import Foundation

actor TelemetryArchive {
    private let rootURL: URL
    private let storageRootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        rootURL: URL? = nil,
        storageRootURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let resolvedRoot = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
        self.rootURL = resolvedRoot
        self.storageRootURL = storageRootURL ?? (rootURL == nil ? resolvedRoot.deletingLastPathComponent() : resolvedRoot)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSince1970)
        }
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid timestamp")
        }
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
        let fileURL = directory.appendingPathComponent("server-acks.ndjson")
        for identifier in identifiers {
            var data = Data("{\"id\":\"\(identifier.uuidString)\"}".utf8)
            data.append(0x0A)
            try append(data, to: fileURL)
        }
    }

    func envelopes(runID: UUID) throws -> [TelemetryEnvelope] {
        let fileURL = runDirectory(runID).appendingPathComponent("samples.ndjson")
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        return completeLines(in: try Data(contentsOf: fileURL)).compactMap {
            try? decoder.decode(TelemetryEnvelope.self, from: $0)
        }
    }

    func acknowledgedIDs(runID: UUID) throws -> Set<UUID> {
        struct Acknowledgement: Decodable { let id: UUID }
        var values: Set<UUID> = []
        let fileURL = runDirectory(runID).appendingPathComponent("server-acks.ndjson")
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let identifiers = completeLines(in: try Data(contentsOf: fileURL)).compactMap {
            try? decoder.decode(Acknowledgement.self, from: $0).id
        }
        values.formUnion(identifiers)
        return values
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

    func latestEnvelope(runID: UUID) throws -> TelemetryEnvelope? {
        try envelopes(runID: runID).last
    }

    func containsEnvelope(_ envelopeID: UUID, runID: UUID) throws -> Bool {
        try envelopes(runID: runID).contains { $0.id == envelopeID }
    }

    func currentSession() throws -> ActivitySessionState? {
        let url = storageRootURL.appendingPathComponent("session-state.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(ActivitySessionState.self, from: Data(contentsOf: url))
    }

    func writeCurrentSession(_ session: ActivitySessionState) throws {
        try writeMetadata(session, to: storageRootURL.appendingPathComponent("session-state.json"))
    }

    func deleteCurrentSession() throws {
        let url = storageRootURL.appendingPathComponent("session-state.json")
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func runMetadata(runID: UUID) throws -> ActivityRunMetadata? {
        let url = runDirectory(runID).appendingPathComponent("metadata.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(ActivityRunMetadata.self, from: Data(contentsOf: url))
    }

    func writeRunMetadata(_ metadata: ActivityRunMetadata) throws {
        let directory = try prepareRunDirectory(metadata.localRunID)
        try writeMetadata(metadata, to: directory.appendingPathComponent("metadata.json"))
    }

    func closeRun(_ closure: PendingSessionClosure) throws {
        guard var metadata = try runMetadata(runID: closure.localRunID) else { return }
        metadata.closedAt = closure.closedAt
        metadata.closingReason = closure.closingReason
        metadata.implicitEndUsed = closure.closingReason == .implicitTimerReset
        try writeRunMetadata(metadata)
    }

    func deleteAll() throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.removeItem(at: rootURL)
        }
        try deleteCurrentSession()
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

        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        try truncatePartialTail(handle)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func writeMetadata<T: Encodable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        let data = try encoder.encode(value)
        try data.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private func truncatePartialTail(_ handle: FileHandle) throws {
        let end = try handle.seekToEnd()
        guard end > 0 else { return }
        try handle.seek(toOffset: end - 1)
        if try handle.read(upToCount: 1)?.first == 0x0A { return }

        var offset = end
        let chunkSize: UInt64 = 4_096
        while offset > 0 {
            let start = offset > chunkSize ? offset - chunkSize : 0
            try handle.seek(toOffset: start)
            let chunk = try handle.read(upToCount: Int(offset - start)) ?? Data()
            if let newline = chunk.lastIndex(of: 0x0A) {
                try handle.truncate(atOffset: start + UInt64(newline) + 1)
                return
            }
            offset = start
        }
        try handle.truncate(atOffset: 0)
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
