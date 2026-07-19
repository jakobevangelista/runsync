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
    let sample: TelemetrySample
    let phoneReceivedAt: Date
    let envelope: TelemetryEnvelope?
    let session: ActivitySessionState?
    let boundaryReason: ActivityBoundaryReason?
    let observationReason: ActivityObservationReason?
    let acknowledgedIDs: [UUID]
    let serverStatus: ServerUploadStatus
}

enum TelemetryUploadState: Equatable, Sendable {
    case notConfigured
    case idle
    case current
    case submitting
    case waitingForConnectivity
    case backingOff
    case blocked(String)

    var label: String {
        switch self {
        case .notConfigured: "Not configured"
        case .idle: "Ready"
        case .current: "Current"
        case .submitting: "Uploading"
        case .waitingForConnectivity: "Waiting for connection"
        case .backingOff: "Backing off"
        case .blocked(let reason): reason
        }
    }
}

enum ConnectivityState: String, Equatable, Sendable {
    case unknown
    case satisfied
    case unsatisfied
    case requiresConnection
}

enum ConnectivityInterface: String, Equatable, Sendable {
    case wifi
    case cellular
    case wiredEthernet
    case other
    case unavailable
}

struct ConnectivityStatus: Equatable, Sendable {
    var state: ConnectivityState
    var interface: ConnectivityInterface
    var isExpensive: Bool
    var isConstrained: Bool

    static let unknown = ConnectivityStatus(
        state: .unknown,
        interface: .unavailable,
        isExpensive: false,
        isConstrained: false
    )

    var label: String {
        guard state == .satisfied else {
            switch state {
            case .unknown: return "Unknown"
            case .unsatisfied: return "Unsatisfied"
            case .requiresConnection: return "Requires connection"
            case .satisfied: break
            }
            return "Online"
        }
        var details = [interface.rawValue]
        if isExpensive { details.append("expensive") }
        if isConstrained { details.append("constrained") }
        return "Online (\(details.joined(separator: ", ")))"
    }
}

struct ServerUploadStatus: Equatable, Sendable {
    var uploadState: TelemetryUploadState
    var connectivity: ConnectivityStatus
    var pendingCount: Int
    var oldestPendingAge: TimeInterval?
    var lastWatchReceiptAt: Date?
    var lastArchiveAt: Date?
    var lastAttemptAt: Date?
    var lastAcknowledgementAt: Date?
    var localArchiveIssueCount: Int
    var quarantineCount: Int
    var lastQuarantinedEnvelopeID: UUID?
    var lastSafeErrorCategory: String?

    var state: String { uploadState.label }
    var lastUploadAt: Date? { lastAttemptAt }

    static let notConfigured = ServerUploadStatus(
        uploadState: .notConfigured,
        connectivity: .unknown,
        pendingCount: 0,
        oldestPendingAge: nil,
        lastWatchReceiptAt: nil,
        lastArchiveAt: nil,
        lastAttemptAt: nil,
        lastAcknowledgementAt: nil,
        localArchiveIssueCount: 0,
        quarantineCount: 0,
        lastQuarantinedEnvelopeID: nil,
        lastSafeErrorCategory: nil
    )
}
