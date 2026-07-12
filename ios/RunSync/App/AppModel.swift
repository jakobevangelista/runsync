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
    @Published var mockStatus = "Ready"
    @Published var lastSampleAt: Date?
    @Published var currentRunID: UUID?
    @Published var receivedCount = 0
    @Published var invalidMessageCount = 0
    @Published var archiveFailureCount = 0
    @Published var mockFailureCount = 0
    @Published var mockFailureInjection = false
    @Published var captureEnabled = false
    @Published var diagnosticEvents: [String] = []

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
        mockStatus = "Current"
        if receivedCount == 1 || receivedCount.isMultiple(of: 10) {
            record("Received telemetry q=\(result.envelope.sample.sequence), total=\(receivedCount)")
        }
    }

    func rejectedMessage() {
        invalidMessageCount += 1
        record("Rejected Garmin message, total=\(invalidMessageCount)")
    }

    func ingestFailed(_ error: Error) {
        record("Ingest failed: \(String(describing: error))")
        if error is MockSinkFailure {
            mockFailureCount += 1
            mockStatus = "Injected failure"
        } else {
            archiveFailureCount += 1
            archiveStatus = "Write error"
        }
    }

    func telemetryDeleted() {
        lastSampleAt = nil
        currentRunID = nil
        receivedCount = 0
        activityStatus = "Waiting"
        archiveStatus = "Ready"
        mockStatus = "Ready"
        record("Deleted local telemetry")
    }
}
