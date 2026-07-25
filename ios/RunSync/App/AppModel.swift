import Foundation
import OSLog

struct GarminDeviceOption: Identifiable, Equatable {
    let id: UUID
    let name: String
}

@MainActor
final class AppModel: ObservableObject {
    private let logger = Logger(subsystem: "com.jakobevangelista.runsync", category: "diagnostics")
    private let diagnosticRecorder: GarminDiagnosticRecorder
    private var lastReceiptDiagnostic: (receivedAt: Date, sequence: Int)?
    private var lastReceiptCheckpointAt: Date?

    @Published var authorizationStatus = "Action required"
    @Published var watchStatus = "Disconnected"
    @Published var fieldStatus = "Unknown"
    @Published var activityStatus = "Waiting"
    @Published var runSyncSessionStatus = "None"
    @Published var archiveStatus = "Ready"
    @Published var serverStatus = "Not configured"
    @Published var connectivityStatus = "Unknown"
    @Published var serverBaseURL = ""
    @Published var serverTokenConfigured = false
    @Published var serverConfigurationStatus = ""
    @Published var pendingUploadCount = 0
    @Published var oldestPendingAge: TimeInterval?
    @Published var lastUploadAt: Date?
    @Published var lastAcknowledgementAt: Date?
    @Published var lastSampleAt: Date?
    @Published var lastArchiveAt: Date?
    @Published var localArchiveIssueCount = 0
    @Published var quarantineCount = 0
    @Published var lastQuarantinedEnvelopeID: UUID?
    @Published var lastQuarantineCategory: String?
    @Published var currentRunID: UUID?
    @Published var receivedCount = 0
    @Published var invalidMessageCount = 0
    @Published var archiveFailureCount = 0
    @Published var captureEnabled = false
    @Published var authorizedDevices: [GarminDeviceOption] = []
    @Published var selectedCaptureDeviceID: UUID?
    @Published var droppedReceiptCount = 0
    @Published var recoveryInProgress = false
    @Published var recoveryResult: GarminRecoveryResult?
    @Published var diagnosticEvents: [String] = []
    @Published var watchBuildID: String?
    @Published var watchTransportTimeoutCount: Int?
    @Published var watchTransportErrorCount: Int?
    @Published var watchTransportExceptionCount: Int?
    @Published var watchTransportConsecutiveFailures: Int?
    @Published var watchTransportLastOutcome: WatchTransportOutcome?
    private var lastRejectionSignature: String?
    private var lastQuarantineSignature: String?

    init(diagnosticRecorder: GarminDiagnosticRecorder = GarminDiagnosticRecorder()) {
        self.diagnosticRecorder = diagnosticRecorder
        diagnosticEvents = diagnosticRecorder.loadRecentSummaries(limit: 20)
        persistDiagnostic("process_started")
    }

    func record(_ event: String) {
        logger.notice("\(event, privacy: .public)")
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        diagnosticEvents.insert("\(timestamp)  \(event)", at: 0)
        diagnosticEvents = Array(diagnosticEvents.prefix(20))
    }

    func persistDiagnostic(_ event: String, details: [String: String] = [:]) {
        diagnosticRecorder.record(event: event, details: details)
    }

    func received(_ result: IngestResult, callbackOrdinal: UInt64? = nil) {
        receivedCount += 1
        lastSampleAt = result.phoneReceivedAt
        if result.observationReason != .nonSelectedDevice {
            activityStatus = result.sample.state.label
            updateWatchDiagnostics(from: result.sample)
        }
        currentRunID = result.session?.localRunID
        runSyncSessionStatus = sessionLabel(result.session)
        if result.envelope != nil { archiveStatus = "Healthy" }
        updateServerStatus(result.serverStatus)
        if let reason = result.boundaryReason {
            record("Activity boundary: \(reason.rawValue)")
        }
        if receivedCount == 1 || receivedCount.isMultiple(of: 10) {
            let ordinal = callbackOrdinal.map { ", receipt=\($0)" } ?? ""
            record("Received telemetry q=\(result.sample.sequence)\(ordinal), total=\(receivedCount)")
        }
        recordReceiptDiagnostic(result, callbackOrdinal: callbackOrdinal)
    }

    func restoreSession(_ session: ActivitySessionState?) {
        currentRunID = session?.localRunID
        runSyncSessionStatus = sessionLabel(session)
        if let session {
            activityStatus = session.lastActivityState.label
            record("Restored activity session \(session.localRunID.uuidString.prefix(8))")
        }
    }

    func receiptQueueOverflowed(total: Int) {
        archiveFailureCount += 1
        droppedReceiptCount = total
        archiveStatus = "Capture stopped"
        record("Capture disabled: ordered receipt queue overflow; dropped=\(total)")
    }

    func capturePausedForReconciliation() {
        archiveStatus = "Reconciliation required"
        record("Capture disabled: local session state requires reconciliation")
    }

    func rejectedMessage(reason: String, shape: String) {
        invalidMessageCount += 1
        let signature = "\(reason)|\(shape)"
        if signature != lastRejectionSignature || invalidMessageCount == 1 || invalidMessageCount.isMultiple(of: 10) {
            let event = "Rejected Garmin message: \(reason), shape=[\(shape)], total=\(invalidMessageCount)"
            record(event)
            persistDiagnostic("decoder_rejection", details: [
                "reason": reason,
                "shape": shape,
                "total": "\(invalidMessageCount)"
            ])
        }
        lastRejectionSignature = signature
    }

    func invalidWatchDiagnostic(_ warning: GarminDecodeWarning, sequence: Int?) {
        persistDiagnostic("invalid_watch_diagnostic", details: [
            "key": warning.diagnosticKey,
            "watchSequence": sequence.map(String.init) ?? "unknown"
        ])
    }

    func ingestFailed(_ error: Error) {
        record("Ingest failed: \(String(describing: error))")
        archiveFailureCount += 1
        archiveStatus = "Write error"
    }

    func telemetryDeleted() {
        lastSampleAt = nil
        currentRunID = nil
        receivedCount = 0
        activityStatus = "Waiting"
        runSyncSessionStatus = "None"
        archiveStatus = "Ready"
        serverStatus = "Not configured"
        pendingUploadCount = 0
        oldestPendingAge = nil
        lastUploadAt = nil
        lastAcknowledgementAt = nil
        lastArchiveAt = nil
        localArchiveIssueCount = 0
        quarantineCount = 0
        lastQuarantinedEnvelopeID = nil
        lastQuarantineCategory = nil
        lastQuarantineSignature = nil
        recoveryResult = nil
        watchBuildID = nil
        watchTransportTimeoutCount = nil
        watchTransportErrorCount = nil
        watchTransportExceptionCount = nil
        watchTransportConsecutiveFailures = nil
        watchTransportLastOutcome = nil
        lastReceiptDiagnostic = nil
        lastReceiptCheckpointAt = nil
        diagnosticRecorder.deleteAll()
        diagnosticEvents = []
        record("Deleted local telemetry")
    }

    func updateServerStatus(_ status: ServerUploadStatus) {
        serverStatus = status.state
        connectivityStatus = status.connectivity.label
        pendingUploadCount = status.pendingCount
        oldestPendingAge = status.oldestPendingAge
        lastUploadAt = status.lastUploadAt
        lastAcknowledgementAt = status.lastAcknowledgementAt
        lastSampleAt = status.lastWatchReceiptAt ?? lastSampleAt
        lastArchiveAt = status.lastArchiveAt ?? lastArchiveAt
        watchBuildID = status.watchBuildID ?? watchBuildID
        watchTransportTimeoutCount = status.watchTransportTimeoutCount ?? watchTransportTimeoutCount
        watchTransportErrorCount = status.watchTransportErrorCount ?? watchTransportErrorCount
        watchTransportExceptionCount = status.watchTransportExceptionCount ?? watchTransportExceptionCount
        watchTransportConsecutiveFailures = status.watchTransportConsecutiveFailures ?? watchTransportConsecutiveFailures
        watchTransportLastOutcome = status.watchTransportLastOutcome ?? watchTransportLastOutcome
        localArchiveIssueCount = status.localArchiveIssueCount
        quarantineCount = status.quarantineCount
        lastQuarantinedEnvelopeID = status.lastQuarantinedEnvelopeID
        lastQuarantineCategory = status.lastSafeErrorCategory
        if let envelopeID = status.lastQuarantinedEnvelopeID, status.quarantineCount > 0 {
            let category = status.lastSafeErrorCategory ?? "rejected_envelope"
            let signature = "\(envelopeID.uuidString)|\(category)"
            if signature != lastQuarantineSignature {
                record("Quarantined envelope \(envelopeID.uuidString.prefix(8)); category=\(category)")
                lastQuarantineSignature = signature
            }
        }
        if status.localArchiveIssueCount > 0 {
            archiveStatus = "Corruption detected (\(status.localArchiveIssueCount))"
        }
    }

    private func sessionLabel(_ session: ActivitySessionState?) -> String {
        guard let session else { return "None" }
        let label: String
        switch session.phase {
        case .opening: label = "Opening"
        case .active: label = "Active"
        case .paused: label = "Paused"
        case .stopped: label = "Stopped"
        }
        return session.restoredAfterRelaunch ? "\(label) (restored)" : label
    }

    private func updateWatchDiagnostics(from sample: TelemetrySample) {
        watchBuildID = sample.watchBuildID ?? watchBuildID
        watchTransportTimeoutCount = sample.transportTimeoutCount ?? watchTransportTimeoutCount
        watchTransportErrorCount = sample.transportErrorCount ?? watchTransportErrorCount
        watchTransportExceptionCount = sample.transportExceptionCount ?? watchTransportExceptionCount
        watchTransportConsecutiveFailures = sample.transportConsecutiveFailures ?? watchTransportConsecutiveFailures
        watchTransportLastOutcome = sample.transportLastOutcome ?? watchTransportLastOutcome
    }

    private func recordReceiptDiagnostic(_ result: IngestResult, callbackOrdinal: UInt64?) {
        let previous = lastReceiptDiagnostic
        let gapMilliseconds = previous.map {
            max(0, Int(result.phoneReceivedAt.timeIntervalSince($0.receivedAt) * 1_000))
        }
        let sequenceDelta = previous.map { result.sample.sequence - $0.sequence }
        let shouldRecord: Bool
        let event: String
        if previous == nil {
            shouldRecord = true
            event = "first_valid_message"
        } else if let gapMilliseconds, gapMilliseconds > 10_000 {
            shouldRecord = true
            event = "receipt_gap"
        } else if let sequenceDelta, sequenceDelta < 0 || sequenceDelta > 1 {
            shouldRecord = true
            event = sequenceDelta < 0 ? "sequence_regression" : "sequence_jump"
        } else if lastReceiptCheckpointAt == nil || result.phoneReceivedAt.timeIntervalSince(lastReceiptCheckpointAt!) >= 60 {
            shouldRecord = true
            event = "receipt_checkpoint"
        } else {
            shouldRecord = false
            event = "receipt"
        }

        if shouldRecord {
            persistDiagnostic(event, details: [
                "callbackOrdinal": callbackOrdinal.map(String.init) ?? "unknown",
                "watchSequence": "\(result.sample.sequence)",
                "activityState": "\(result.sample.state.rawValue)",
                "watchBuildID": result.sample.watchBuildID ?? "unknown",
                "previousReceiptAgeMs": gapMilliseconds.map(String.init) ?? "none",
                "sequenceDelta": sequenceDelta.map(String.init) ?? "none",
                "transportTimeoutCount": result.sample.transportTimeoutCount.map(String.init) ?? "unknown",
                "transportErrorCount": result.sample.transportErrorCount.map(String.init) ?? "unknown",
                "transportExceptionCount": result.sample.transportExceptionCount.map(String.init) ?? "unknown",
                "transportConsecutiveFailures": result.sample.transportConsecutiveFailures.map(String.init) ?? "unknown",
                "transportLastOutcome": result.sample.transportLastOutcome.map { "\($0.rawValue)" } ?? "unknown"
            ])
            if event == "receipt_checkpoint" || event == "first_valid_message" {
                lastReceiptCheckpointAt = result.phoneReceivedAt
            }
        }
        lastReceiptDiagnostic = (result.phoneReceivedAt, result.sample.sequence)
    }
}

struct GarminDiagnosticRecord: Codable {
    let schemaVersion: Int
    let ordinal: UInt64
    let occurredAt: Date
    let systemUptimeSeconds: TimeInterval
    let processSessionID: UUID
    let iOSAppVersion: String
    let event: String
    let details: [String: String]
}

final class GarminDiagnosticRecorder: @unchecked Sendable {
    private let rootURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.jakobevangelista.runsync.garmin-diagnostics")
    private let lock = NSLock()
    private let dateProvider: @Sendable () -> Date
    private let uptimeProvider: @Sendable () -> TimeInterval
    private let appVersionProvider: @Sendable () -> String
    private let processSessionID = UUID()
    private let maxFileSize: Int
    private let maxPending: Int
    private var nextOrdinal: UInt64 = 0
    private var pending = 0
    private var overflowDropped = 0
    private var deleteGeneration: UInt64 = 0

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        maxFileSize: Int = 256 * 1024,
        maxPending: Int = 256,
        dateProvider: @escaping @Sendable () -> Date = { Date() },
        uptimeProvider: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        appVersionProvider: @escaping @Sendable () -> String = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        }
    ) {
        self.fileManager = fileManager
        self.maxFileSize = maxFileSize
        self.maxPending = maxPending
        self.dateProvider = dateProvider
        self.uptimeProvider = uptimeProvider
        self.appVersionProvider = appVersionProvider
        if let rootURL {
            self.rootURL = rootURL
        } else {
            self.rootURL = fileManager
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RunSync/Diagnostics", isDirectory: true)
        }
    }

    func record(event: String, details: [String: String] = [:]) {
        lock.lock()
        if pending >= maxPending {
            overflowDropped += 1
            lock.unlock()
            return
        }
        let generation = deleteGeneration
        let remainingCapacity = maxPending - pending
        if overflowDropped > 0 {
            let dropped = remainingCapacity == 1 ? overflowDropped + 1 : overflowDropped
            pending += 1
            nextOrdinal &+= 1
            enqueueLocked(
                makeRecord(
                    ordinal: nextOrdinal,
                    event: "diagnostic_queue_overflow",
                    details: ["dropped": "\(dropped)"]
                ),
                generation: generation
            )
            overflowDropped = 0
            if remainingCapacity == 1 {
                lock.unlock()
                return
            }
        }
        pending += 1
        nextOrdinal &+= 1
        enqueueLocked(makeRecord(ordinal: nextOrdinal, event: event, details: details), generation: generation)
        lock.unlock()
    }

    func loadRecentSummaries(limit: Int) -> [String] {
        let records = loadRecords(limit: limit)
        return records.reversed().map { record in
            let timestamp = record.occurredAt.formatted(date: .omitted, time: .standard)
            return "\(timestamp)  \(record.event)"
        }
    }

    func deleteAll() {
        lock.lock()
        deleteGeneration &+= 1
        overflowDropped = 0
        queue.async { [rootURL, fileManager] in
            if fileManager.fileExists(atPath: rootURL.path) {
                try? fileManager.removeItem(at: rootURL)
            }
        }
        lock.unlock()
    }

    func waitForPendingWrites() {
        queue.sync {}
    }

    #if DEBUG
    func performWithWriterBlockedForTesting(_ work: () -> Void) {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        queue.async {
            started.signal()
            release.wait()
        }
        started.wait()
        work()
        release.signal()
        queue.sync {}
    }
    #endif

    private func makeRecord(ordinal: UInt64, event: String, details: [String: String]) -> GarminDiagnosticRecord {
        GarminDiagnosticRecord(
            schemaVersion: 1,
            ordinal: ordinal,
            occurredAt: dateProvider(),
            systemUptimeSeconds: uptimeProvider(),
            processSessionID: processSessionID,
            iOSAppVersion: appVersionProvider(),
            event: event,
            details: details
        )
    }

    private func enqueueLocked(_ record: GarminDiagnosticRecord, generation: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            let shouldAppend = self.lock.withLock { generation == self.deleteGeneration }
            if shouldAppend {
                self.append(record)
            }
            self.lock.withLock {
                self.pending = max(0, self.pending - 1)
            }
        }
    }

    private func append(_ record: GarminDiagnosticRecord) {
        do {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            let active = rootURL.appendingPathComponent("garmin-events.ndjson")
            try rotateIfNeeded(active)
            var data = try JSONEncoder().encode(record)
            data.append(0x0A)
            if !fileManager.fileExists(atPath: active.path) {
                fileManager.createFile(
                    atPath: active.path,
                    contents: nil,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
                )
            }
            let handle = try FileHandle(forWritingTo: active)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Diagnostic persistence is best effort and must not affect capture.
        }
    }

    private func rotateIfNeeded(_ active: URL) throws {
        guard let size = try? active.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= maxFileSize else { return }
        let previous = rootURL.appendingPathComponent("garmin-events.1.ndjson")
        if fileManager.fileExists(atPath: previous.path) {
            try? fileManager.removeItem(at: previous)
        }
        try? fileManager.moveItem(at: active, to: previous)
    }

    private func loadRecords(limit: Int) -> [GarminDiagnosticRecord] {
        let urls = [
            rootURL.appendingPathComponent("garmin-events.1.ndjson"),
            rootURL.appendingPathComponent("garmin-events.ndjson")
        ]
        let decoder = JSONDecoder()
        var records: [GarminDiagnosticRecord] = []
        for url in urls where fileManager.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: 0x0A).suffix(limit) {
                if let record = try? decoder.decode(GarminDiagnosticRecord.self, from: Data(line)) {
                    records.append(record)
                }
            }
        }
        return Array(records.suffix(limit))
    }
}
