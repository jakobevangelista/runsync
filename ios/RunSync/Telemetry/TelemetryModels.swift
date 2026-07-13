import Foundation

enum ActivityState: Int, Codable, Sendable {
    case waiting = 0
    case running = 1
    case paused = 2
    case stopped = 3
    case ended = 4

    var label: String {
        switch self {
        case .waiting: "Waiting"
        case .running: "Running"
        case .paused: "Paused"
        case .stopped: "Stopped"
        case .ended: "Ended"
        }
    }
}

enum GPSQuality: Int, Codable, Sendable {
    case unavailable = 0
    case lastKnown = 1
    case poor = 2
    case usable = 3
    case good = 4
}

struct TelemetrySample: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let sequence: Int
    let state: ActivityState
    let activityStartEpochSeconds: Int?
    let elapsedTimeMilliseconds: Int?
    let distanceDecimeters: Int?
    let speedMillimetersPerSecond: Int?
    let heartRateBPM: Int?
    let cadenceRPM: Int?
    let latitudeMicrodegrees: Int?
    let longitudeMicrodegrees: Int?
    let gpsQuality: GPSQuality?
    let altitudeDecimeters: Int?
    let totalAscentMeters: Int?
}

struct TelemetryEnvelope: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let installationID: UUID
    let localRunID: UUID
    let phoneReceivedAt: Date
    let garminDeviceIdentifier: UUID
    let appVersion: String
    let sample: TelemetrySample
}

struct IngestResult: Sendable {
    let envelope: TelemetryEnvelope
    let acknowledgedIDs: [UUID]
    let serverStatus: ServerUploadStatus
}

struct ServerUploadStatus: Equatable, Sendable {
    var state: String
    var pendingCount: Int
    var lastUploadAt: Date?
    var lastAcknowledgementAt: Date?

    static let notConfigured = ServerUploadStatus(
        state: "Not configured",
        pendingCount: 0,
        lastUploadAt: nil,
        lastAcknowledgementAt: nil
    )
}
