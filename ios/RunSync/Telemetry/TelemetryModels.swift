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

enum WatchTransportOutcome: Int, Codable, Sendable {
    case none = 0
    case success = 1
    case error = 2
    case timeout = 3
    case exception = 4

    var label: String {
        switch self {
        case .none: "Unknown"
        case .success: "Success"
        case .error: "Error"
        case .timeout: "Timeout"
        case .exception: "Exception"
        }
    }
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
    let watchBuildID: String?
    let transportTimeoutCount: Int?
    let transportErrorCount: Int?
    let transportExceptionCount: Int?
    let transportConsecutiveFailures: Int?
    let transportLastOutcome: WatchTransportOutcome?

    init(
        protocolVersion: Int,
        sequence: Int,
        state: ActivityState,
        activityStartEpochSeconds: Int? = nil,
        elapsedTimeMilliseconds: Int? = nil,
        distanceDecimeters: Int? = nil,
        speedMillimetersPerSecond: Int? = nil,
        heartRateBPM: Int? = nil,
        cadenceRPM: Int? = nil,
        latitudeMicrodegrees: Int? = nil,
        longitudeMicrodegrees: Int? = nil,
        gpsQuality: GPSQuality? = nil,
        altitudeDecimeters: Int? = nil,
        totalAscentMeters: Int? = nil,
        watchBuildID: String? = nil,
        transportTimeoutCount: Int? = nil,
        transportErrorCount: Int? = nil,
        transportExceptionCount: Int? = nil,
        transportConsecutiveFailures: Int? = nil,
        transportLastOutcome: WatchTransportOutcome? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.sequence = sequence
        self.state = state
        self.activityStartEpochSeconds = activityStartEpochSeconds
        self.elapsedTimeMilliseconds = elapsedTimeMilliseconds
        self.distanceDecimeters = distanceDecimeters
        self.speedMillimetersPerSecond = speedMillimetersPerSecond
        self.heartRateBPM = heartRateBPM
        self.cadenceRPM = cadenceRPM
        self.latitudeMicrodegrees = latitudeMicrodegrees
        self.longitudeMicrodegrees = longitudeMicrodegrees
        self.gpsQuality = gpsQuality
        self.altitudeDecimeters = altitudeDecimeters
        self.totalAscentMeters = totalAscentMeters
        self.watchBuildID = watchBuildID
        self.transportTimeoutCount = transportTimeoutCount
        self.transportErrorCount = transportErrorCount
        self.transportExceptionCount = transportExceptionCount
        self.transportConsecutiveFailures = transportConsecutiveFailures
        self.transportLastOutcome = transportLastOutcome
    }
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
    var watchBuildID: String?
    var watchTransportTimeoutCount: Int?
    var watchTransportErrorCount: Int?
    var watchTransportExceptionCount: Int?
    var watchTransportConsecutiveFailures: Int?
    var watchTransportLastOutcome: WatchTransportOutcome?

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
        lastSafeErrorCategory: nil,
        watchBuildID: nil,
        watchTransportTimeoutCount: nil,
        watchTransportErrorCount: nil,
        watchTransportExceptionCount: nil,
        watchTransportConsecutiveFailures: nil,
        watchTransportLastOutcome: nil
    )
}

enum WatchReceiptFreshness: Equatable, Sendable {
    static let currentThreshold: TimeInterval = 10
    static let unavailableThreshold: TimeInterval = 30

    case captureDisabled
    case never
    case current(age: TimeInterval)
    case delayed(age: TimeInterval)
    case unavailable(age: TimeInterval)

    static func evaluate(
        captureEnabled: Bool,
        lastReceiptAt: Date?,
        now: Date
    ) -> WatchReceiptFreshness {
        guard captureEnabled else { return .captureDisabled }
        guard let lastReceiptAt else { return .never }
        let age = max(0, now.timeIntervalSince(lastReceiptAt))
        if age <= currentThreshold {
            return .current(age: age)
        }
        if age <= unavailableThreshold {
            return .delayed(age: age)
        }
        return .unavailable(age: age)
    }

    var title: String {
        switch self {
        case .captureDisabled: "Capture disabled"
        case .never: "Waiting for watch telemetry"
        case .current: "Watch telemetry current"
        case .delayed: "Watch telemetry delayed"
        case .unavailable: "Watch telemetry unavailable"
        }
    }

    var statusLabel: String {
        switch self {
        case .captureDisabled: "Capture disabled"
        case .never: "Never"
        case .current(let age): "Current, \(Self.seconds(age))s"
        case .delayed(let age): "Delayed, \(Self.seconds(age))s"
        case .unavailable(let age): "Unavailable, \(Self.seconds(age))s"
        }
    }

    var ageLabel: String {
        switch self {
        case .captureDisabled: "Capture is disabled"
        case .never: "No sample received yet"
        case .current(let age), .delayed(let age), .unavailable(let age):
            "Last sample \(Self.seconds(age))s ago"
        }
    }

    private static func seconds(_ interval: TimeInterval) -> Int {
        max(0, Int(interval.rounded(.down)))
    }
}
