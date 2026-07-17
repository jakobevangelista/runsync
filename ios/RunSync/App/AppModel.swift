import Foundation
import OSLog

@MainActor
final class AppModel: ObservableObject {
    private let logger = Logger(subsystem: "com.jakobevangelista.runsync", category: "diagnostics")

    @Published var authorizationStatus = "Action required"
    @Published var watchStatus = "Disconnected"
    @Published var fieldStatus = "Unknown"
    @Published var activityStatus = "Waiting"
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
    @Published var diagnosticEvents: [String] = []
    private var lastRejectionSignature: String?

    func record(_ event: String) {
        logger.notice("\(event, privacy: .public)")
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        diagnosticEvents.insert("\(timestamp)  \(event)", at: 0)
        diagnosticEvents = Array(diagnosticEvents.prefix(20))
    }

    func received(_ result: IngestResult) {
        receivedCount += 1
        lastSampleAt = result.envelope.phoneReceivedAt
        currentRunID = result.envelope.localRunID
        activityStatus = result.envelope.sample.state.label
        archiveStatus = "Healthy"
        updateServerStatus(result.serverStatus)
        if receivedCount == 1 || receivedCount.isMultiple(of: 10) {
            record("Received telemetry q=\(result.envelope.sample.sequence), total=\(receivedCount)")
        }
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
}
