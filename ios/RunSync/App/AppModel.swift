import Foundation
import OSLog

struct GarminDeviceOption: Identifiable, Equatable {
    let id: UUID
    let name: String
}

@MainActor
final class AppModel: ObservableObject {
    private let logger = Logger(subsystem: "com.jakobevangelista.runsync", category: "diagnostics")

    @Published var authorizationStatus = "Action required"
    @Published var watchStatus = "Disconnected"
    @Published var fieldStatus = "Unknown"
    @Published var activityStatus = "Waiting"
    @Published var runSyncSessionStatus = "None"
    @Published var archiveStatus = "Ready"
    @Published var serverStatus = "Not configured"
    @Published var serverBaseURL = ""
    @Published var serverTokenConfigured = false
    @Published var serverConfigurationStatus = ""
    @Published var pendingUploadCount = 0
    @Published var lastUploadAt: Date?
    @Published var lastAcknowledgementAt: Date?
    @Published var lastSampleAt: Date?
    @Published var currentRunID: UUID?
    @Published var receivedCount = 0
    @Published var invalidMessageCount = 0
    @Published var archiveFailureCount = 0
    @Published var captureEnabled = false
    @Published var authorizedDevices: [GarminDeviceOption] = []
    @Published var selectedCaptureDeviceID: UUID?
    @Published var diagnosticEvents: [String] = []
    private var lastRejectionSignature: String?

    func record(_ event: String) {
        logger.notice("\(event, privacy: .public)")
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        diagnosticEvents.insert("\(timestamp)  \(event)", at: 0)
        diagnosticEvents = Array(diagnosticEvents.prefix(20))
    }

    func received(_ result: IngestResult, callbackOrdinal: UInt64? = nil) {
        receivedCount += 1
        lastSampleAt = result.phoneReceivedAt
        if result.observationReason != .nonSelectedDevice {
            activityStatus = result.sample.state.label
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
    }

    func restoreSession(_ session: ActivitySessionState?) {
        currentRunID = session?.localRunID
        runSyncSessionStatus = sessionLabel(session)
        if let session {
            activityStatus = session.lastActivityState.label
            record("Restored activity session \(session.localRunID.uuidString.prefix(8))")
        }
    }

    func receiptQueueOverflowed() {
        archiveFailureCount += 1
        archiveStatus = "Capture stopped"
        record("Capture disabled: ordered receipt queue overflow")
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
            persistDecoderDiagnostic(event)
        }
        lastRejectionSignature = signature
    }

    private func persistDecoderDiagnostic(_ event: String) {
        let fileManager = FileManager.default
        guard let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let url = directory.appendingPathComponent("decoder-diagnostics.log")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 64 * 1024 {
                try? fileManager.removeItem(at: url)
            }
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let data = Data("\(timestamp) \(event)\n".utf8)
            if fileManager.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            logger.error("Could not persist decoder diagnostic")
        }
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
        lastUploadAt = nil
        lastAcknowledgementAt = nil
        record("Deleted local telemetry")
    }

    func updateServerStatus(_ status: ServerUploadStatus) {
        serverStatus = status.state
        pendingUploadCount = status.pendingCount
        lastUploadAt = status.lastUploadAt
        lastAcknowledgementAt = status.lastAcknowledgementAt
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
}
