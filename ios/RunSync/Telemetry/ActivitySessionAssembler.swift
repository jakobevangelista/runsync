import Foundation

enum ActivitySessionPhase: String, Codable, Equatable, Sendable {
    case opening
    case active
    case paused
    case stopped
}

enum ActivityBoundaryReason: String, Codable, Equatable, Sendable {
    case firstRunning = "first_running"
    case changedGarminStart = "changed_garmin_start"
    case elapsedReset = "elapsed_reset"
    case watchEnded = "watch_ended"
    case implicitTimerReset = "implicit_timer_reset"
    case incompatibleNonRunning = "incompatible_non_running"
    case captureDeviceChanged = "capture_device_changed"
    case explicitNewSession = "explicit_new_session"
    case recoverySuperseded = "recovery_superseded"
    case openingAbandoned = "opening_abandoned"
}

enum ActivityObservationReason: String, Equatable, Sendable {
    case captureDisabled
    case nonSelectedDevice
    case idleWaiting
    case idleNonRunning
    case anomalousWaiting
    case staleReceipt
    case staleTerminal
    case incompatibleNonRunning
}

struct PendingSessionClosure: Codable, Equatable, Sendable {
    let localRunID: UUID
    let closingReason: ActivityBoundaryReason
    let closedAt: Date
}

struct ActivitySessionState: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let localRunID: UUID
    let garminDeviceIdentifier: UUID
    var phase: ActivitySessionPhase
    var activityStartEpochSeconds: Int?
    var lastElapsedTimeMilliseconds: Int?
    var lastDistanceDecimeters: Int?
    var lastActivityState: ActivityState
    var lastWatchSequence: Int
    let openedAt: Date
    var lastPhoneReceivedAt: Date
    var lastBoundaryReason: ActivityBoundaryReason
    var openingSampleEnvelopeID: UUID?
    var pendingPriorClosure: PendingSessionClosure?
    var restoredAfterRelaunch: Bool

    init(
        localRunID: UUID,
        garminDeviceIdentifier: UUID,
        phase: ActivitySessionPhase,
        activityStartEpochSeconds: Int?,
        lastElapsedTimeMilliseconds: Int?,
        lastDistanceDecimeters: Int?,
        lastActivityState: ActivityState,
        lastWatchSequence: Int,
        openedAt: Date,
        lastPhoneReceivedAt: Date,
        lastBoundaryReason: ActivityBoundaryReason,
        openingSampleEnvelopeID: UUID? = nil,
        pendingPriorClosure: PendingSessionClosure? = nil,
        restoredAfterRelaunch: Bool = false
    ) {
        self.schemaVersion = Self.schemaVersion
        self.localRunID = localRunID
        self.garminDeviceIdentifier = garminDeviceIdentifier
        self.phase = phase
        self.activityStartEpochSeconds = activityStartEpochSeconds
        self.lastElapsedTimeMilliseconds = lastElapsedTimeMilliseconds
        self.lastDistanceDecimeters = lastDistanceDecimeters
        self.lastActivityState = lastActivityState
        self.lastWatchSequence = lastWatchSequence
        self.openedAt = openedAt
        self.lastPhoneReceivedAt = lastPhoneReceivedAt
        self.lastBoundaryReason = lastBoundaryReason
        self.openingSampleEnvelopeID = openingSampleEnvelopeID
        self.pendingPriorClosure = pendingPriorClosure
        self.restoredAfterRelaunch = restoredAfterRelaunch
    }
}

struct ActivityRunMetadata: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let localRunID: UUID
    let garminDeviceIdentifier: UUID
    let openedAt: Date
    var closedAt: Date?
    var activityStartEpochSeconds: Int?
    let openingReason: ActivityBoundaryReason
    var closingReason: ActivityBoundaryReason?
    var restoredAfterRelaunch: Bool
    var implicitEndUsed: Bool

    init(session: ActivitySessionState) {
        schemaVersion = Self.schemaVersion
        localRunID = session.localRunID
        garminDeviceIdentifier = session.garminDeviceIdentifier
        openedAt = session.openedAt
        closedAt = nil
        activityStartEpochSeconds = session.activityStartEpochSeconds
        openingReason = session.lastBoundaryReason
        closingReason = nil
        restoredAfterRelaunch = session.restoredAfterRelaunch
        implicitEndUsed = false
    }
}

struct ActivitySessionInput: Equatable, Sendable {
    let deviceID: UUID
    let selectedDeviceID: UUID?
    let phoneReceivedAt: Date
    let sample: TelemetrySample
}

enum ActivitySessionAction: Equatable, Sendable {
    case observe(ActivityObservationReason)
    case assignExisting
    case startNew
    case split(ActivityBoundaryReason)
    case assignAndClose(ActivityBoundaryReason)
    case closeWithoutAssignment(ActivityBoundaryReason)
}

struct ActivitySessionTransition: Equatable, Sendable {
    let action: ActivitySessionAction
    let assignedRunID: UUID?
    let proposedState: ActivitySessionState?
    let priorClosure: PendingSessionClosure?
}

struct ActivitySessionAssembler: Sendable {
    private let makeRunID: @Sendable () -> UUID

    init(makeRunID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.makeRunID = makeRunID
    }

    func propose(input: ActivitySessionInput, current: ActivitySessionState?) -> ActivitySessionTransition {
        guard input.selectedDeviceID == input.deviceID else {
            return observe(.nonSelectedDevice, current: current)
        }
        guard let current else {
            return proposeWithoutSession(input)
        }
        guard current.garminDeviceIdentifier == input.deviceID else {
            return observe(.nonSelectedDevice, current: current)
        }

        if input.phoneReceivedAt < current.openedAt {
            return observe(.staleReceipt, current: current)
        }

        let sample = input.sample
        switch sample.state {
        case .waiting:
            let reset = (sample.elapsedTimeMilliseconds == nil || sample.elapsedTimeMilliseconds == 0) &&
                sample.activityStartEpochSeconds == nil
            if reset {
                return ActivitySessionTransition(
                    action: .closeWithoutAssignment(.implicitTimerReset),
                    assignedRunID: nil,
                    proposedState: nil,
                    priorClosure: closure(for: current, reason: .implicitTimerReset, at: input.phoneReceivedAt)
                )
            }
            return observe(.anomalousWaiting, current: current)

        case .ended:
            if knownStartChanged(current: current, sample: sample) {
                return observe(.staleTerminal, current: current)
            }
            return ActivitySessionTransition(
                action: .assignAndClose(.watchEnded),
                assignedRunID: current.localRunID,
                proposedState: nil,
                priorClosure: closure(for: current, reason: .watchEnded, at: input.phoneReceivedAt)
            )

        case .paused, .stopped:
            if let reason = discontinuity(current: current, sample: sample) {
                return ActivitySessionTransition(
                    action: .closeWithoutAssignment(.incompatibleNonRunning),
                    assignedRunID: nil,
                    proposedState: nil,
                    priorClosure: closure(for: current, reason: reason, at: input.phoneReceivedAt)
                )
            }
            return assign(input, current: current)

        case .running:
            if let reason = discontinuity(current: current, sample: sample) {
                let runID = makeRunID()
                let next = newState(runID: runID, input: input, reason: reason)
                return ActivitySessionTransition(
                    action: .split(reason),
                    assignedRunID: runID,
                    proposedState: next,
                    priorClosure: closure(for: current, reason: reason, at: input.phoneReceivedAt)
                )
            }
            return assign(input, current: current)
        }
    }

    private func proposeWithoutSession(_ input: ActivitySessionInput) -> ActivitySessionTransition {
        guard input.sample.state == .running else {
            return observe(input.sample.state == .waiting ? .idleWaiting : .idleNonRunning, current: nil)
        }
        let runID = makeRunID()
        return ActivitySessionTransition(
            action: .startNew,
            assignedRunID: runID,
            proposedState: newState(runID: runID, input: input, reason: .firstRunning),
            priorClosure: nil
        )
    }

    private func assign(_ input: ActivitySessionInput, current: ActivitySessionState) -> ActivitySessionTransition {
        var next = current
        next.phase = phase(for: input.sample.state)
        next.activityStartEpochSeconds = current.activityStartEpochSeconds ?? input.sample.activityStartEpochSeconds
        next.lastElapsedTimeMilliseconds = input.sample.elapsedTimeMilliseconds ?? current.lastElapsedTimeMilliseconds
        next.lastDistanceDecimeters = input.sample.distanceDecimeters ?? current.lastDistanceDecimeters
        next.lastActivityState = input.sample.state
        next.lastWatchSequence = input.sample.sequence
        next.lastPhoneReceivedAt = input.phoneReceivedAt
        next.openingSampleEnvelopeID = nil
        next.pendingPriorClosure = nil
        return ActivitySessionTransition(
            action: .assignExisting,
            assignedRunID: current.localRunID,
            proposedState: next,
            priorClosure: nil
        )
    }

    private func newState(
        runID: UUID,
        input: ActivitySessionInput,
        reason: ActivityBoundaryReason
    ) -> ActivitySessionState {
        ActivitySessionState(
            localRunID: runID,
            garminDeviceIdentifier: input.deviceID,
            phase: .active,
            activityStartEpochSeconds: input.sample.activityStartEpochSeconds,
            lastElapsedTimeMilliseconds: input.sample.elapsedTimeMilliseconds,
            lastDistanceDecimeters: input.sample.distanceDecimeters,
            lastActivityState: input.sample.state,
            lastWatchSequence: input.sample.sequence,
            openedAt: input.phoneReceivedAt,
            lastPhoneReceivedAt: input.phoneReceivedAt,
            lastBoundaryReason: reason
        )
    }

    private func discontinuity(
        current: ActivitySessionState,
        sample: TelemetrySample
    ) -> ActivityBoundaryReason? {
        if knownStartChanged(current: current, sample: sample) {
            return .changedGarminStart
        }
        let stableKnownStart = current.activityStartEpochSeconds != nil &&
            current.activityStartEpochSeconds == sample.activityStartEpochSeconds
        if !stableKnownStart,
           let previous = current.lastElapsedTimeMilliseconds,
           let incoming = sample.elapsedTimeMilliseconds,
           (incoming <= 5_000 && previous >= 30_000 || previous - incoming >= 10_000) {
            return .elapsedReset
        }
        return nil
    }

    private func knownStartChanged(
        current: ActivitySessionState,
        sample: TelemetrySample
    ) -> Bool {
        guard let previous = current.activityStartEpochSeconds,
              let incoming = sample.activityStartEpochSeconds else { return false }
        return previous != incoming
    }

    private func phase(for state: ActivityState) -> ActivitySessionPhase {
        switch state {
        case .paused: .paused
        case .stopped: .stopped
        default: .active
        }
    }

    private func closure(
        for current: ActivitySessionState,
        reason: ActivityBoundaryReason,
        at date: Date
    ) -> PendingSessionClosure {
        PendingSessionClosure(localRunID: current.localRunID, closingReason: reason, closedAt: date)
    }

    private func observe(
        _ reason: ActivityObservationReason,
        current: ActivitySessionState?
    ) -> ActivitySessionTransition {
        ActivitySessionTransition(
            action: .observe(reason),
            assignedRunID: nil,
            proposedState: current,
            priorClosure: nil
        )
    }
}
