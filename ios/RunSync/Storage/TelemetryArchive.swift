import Foundation

struct LocalArchiveIssue: Equatable, Sendable {
    enum Category: String, Equatable, Sendable {
        case invalidEnvelope
        case invalidAcknowledgement
    }

    let runID: UUID
    let fileName: String
    let lineNumber: Int
    let category: Category
}

struct TelemetryArchiveScan: Equatable, Sendable {
    let pendingEnvelopes: [TelemetryEnvelope]
    let issues: [LocalArchiveIssue]
    let quarantined: [TelemetryQuarantineRecord]
}

struct TelemetryQuarantineRecord: Codable, Equatable, Sendable {
    let envelopeID: UUID
    let runID: UUID
    let category: String
    let serverCode: TelemetryServerErrorCode?
    let statusCode: Int
    let quarantinedAt: Date
    let appVersion: String
}

actor TelemetryArchive {
    private let rootURL: URL
    private let storageRootURL: URL
    private let fileManager: FileManager
    private let uploadFenceGate: TelemetryUploadFenceGate?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        rootURL: URL? = nil,
        storageRootURL: URL? = nil,
        fileManager: FileManager = .default,
        uploadFenceGate: TelemetryUploadFenceGate? = nil
    ) {
        self.fileManager = fileManager
        self.uploadFenceGate = uploadFenceGate
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

    func appendAcknowledgements(
        _ identifiers: [UUID],
        runID: UUID,
        fence: TelemetryUploadFence
    ) throws -> Bool {
        guard !identifiers.isEmpty else { return true }
        guard let uploadFenceGate else { return false }
        let appended: Void? = try uploadFenceGate.withCurrentFence(fence) { () -> Void in
            let directory = try prepareRunDirectory(runID)
            let fileURL = directory.appendingPathComponent("server-acks.ndjson")
            for identifier in identifiers {
                var data = Data("{\"id\":\"\(identifier.uuidString)\"}".utf8)
                data.append(0x0A)
                try append(data, to: fileURL)
            }
        }
        return appended != nil
    }

    func envelopes(runID: UUID) throws -> [TelemetryEnvelope] {
        try scanEnvelopes(runID: runID).values
    }

    func acknowledgedIDs(runID: UUID) throws -> Set<UUID> {
        try scanAcknowledgements(runID: runID).values
    }

    func pendingEnvelopes() throws -> [TelemetryEnvelope] {
        try scanPendingEnvelopes().pendingEnvelopes
    }

    func scanPendingEnvelopes() throws -> TelemetryArchiveScan {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return TelemetryArchiveScan(pendingEnvelopes: [], issues: [], quarantined: [])
        }
        let directories = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var pending: [TelemetryEnvelope] = []
        var issues: [LocalArchiveIssue] = []
        let quarantined = try quarantineRecords()
        let quarantinedIDs = Set(quarantined.map(\.envelopeID))
        for directory in directories {
            guard let runID = UUID(uuidString: directory.lastPathComponent) else { continue }
            let acknowledgementScan = try scanAcknowledgements(runID: runID)
            let envelopeScan = try scanEnvelopes(runID: runID)
            pending.append(contentsOf: envelopeScan.values.filter {
                !acknowledgementScan.values.contains($0.id) && !quarantinedIDs.contains($0.id)
            })
            issues.append(contentsOf: envelopeScan.issues)
            issues.append(contentsOf: acknowledgementScan.issues)
        }
        pending.sort(by: Self.isOrderedBefore)
        return TelemetryArchiveScan(pendingEnvelopes: pending, issues: issues, quarantined: quarantined)
    }

    func quarantine(_ record: TelemetryQuarantineRecord) throws {
        let directory = quarantineDirectory()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try writeMetadata(record, to: directory.appendingPathComponent("\(record.envelopeID.uuidString).json"))
    }

    func releaseAllQuarantine() throws {
        let directory = quarantineDirectory()
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    func releaseQuarantineFromOlderAppVersions(currentAppVersion: String) throws {
        for record in try quarantineRecords() where record.appVersion != currentAppVersion {
            let url = quarantineDirectory().appendingPathComponent("\(record.envelopeID.uuidString).json")
            try fileManager.removeItem(at: url)
        }
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

    func hasTelemetryFiles() -> Bool {
        fileManager.fileExists(atPath: rootURL.path)
            || fileManager.fileExists(atPath: storageRootURL.appendingPathComponent("session-state.json").path)
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

    private func quarantineDirectory() -> URL {
        rootURL.appendingPathComponent("Quarantine", isDirectory: true)
    }

    private func quarantineRecords() throws -> [TelemetryQuarantineRecord] {
        let directory = quarantineDirectory()
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .map { try decoder.decode(TelemetryQuarantineRecord.self, from: Data(contentsOf: $0)) }
        .sorted { $0.envelopeID.uuidString < $1.envelopeID.uuidString }
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

    private func scanEnvelopes(runID: UUID) throws -> (values: [TelemetryEnvelope], issues: [LocalArchiveIssue]) {
        let fileName = "samples.ndjson"
        let fileURL = runDirectory(runID).appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: fileURL.path) else { return ([], []) }
        var values: [TelemetryEnvelope] = []
        var issues: [LocalArchiveIssue] = []
        for line in completeLines(in: try Data(contentsOf: fileURL)) {
            do {
                values.append(try decoder.decode(TelemetryEnvelope.self, from: line.data))
            } catch {
                issues.append(LocalArchiveIssue(
                    runID: runID,
                    fileName: fileName,
                    lineNumber: line.number,
                    category: .invalidEnvelope
                ))
            }
        }
        return (values, issues)
    }

    private func scanAcknowledgements(runID: UUID) throws -> (values: Set<UUID>, issues: [LocalArchiveIssue]) {
        struct Acknowledgement: Decodable { let id: UUID }
        let fileName = "server-acks.ndjson"
        let fileURL = runDirectory(runID).appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: fileURL.path) else { return ([], []) }
        var values: Set<UUID> = []
        var issues: [LocalArchiveIssue] = []
        for line in completeLines(in: try Data(contentsOf: fileURL)) {
            do {
                values.insert(try decoder.decode(Acknowledgement.self, from: line.data).id)
            } catch {
                issues.append(LocalArchiveIssue(
                    runID: runID,
                    fileName: fileName,
                    lineNumber: line.number,
                    category: .invalidAcknowledgement
                ))
            }
        }
        return (values, issues)
    }

    private func completeLines(in data: Data) -> [(number: Int, data: Data)] {
        var lines: [(Int, Data)] = []
        var lineStart = data.startIndex
        var lineNumber = 1
        while let newline = data[lineStart...].firstIndex(of: 0x0A) {
            lines.append((lineNumber, Data(data[lineStart..<newline])))
            lineStart = data.index(after: newline)
            lineNumber += 1
        }
        return lines
    }

    private nonisolated static func isOrderedBefore(_ lhs: TelemetryEnvelope, _ rhs: TelemetryEnvelope) -> Bool {
        if lhs.phoneReceivedAt != rhs.phoneReceivedAt {
            return lhs.phoneReceivedAt < rhs.phoneReceivedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func defaultRootURL(fileManager: FileManager) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport
            .appendingPathComponent("RunSync", isDirectory: true)
            .appendingPathComponent("Runs", isDirectory: true)
    }
}
