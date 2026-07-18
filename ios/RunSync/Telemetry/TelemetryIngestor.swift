import Foundation

struct TelemetryIngestionFailure: Error, Sendable {
    let receiptPersisted: Bool
    let message: String
}

actor TelemetryIngestor {
    private struct SessionRecovery: Sendable {
        let session: ActivitySessionState?
        let pending: [TelemetryEnvelope]
    }

    private let archive: TelemetryArchive
    private let sink: any TelemetrySink
    private let installationID: UUID
    private let assembler: ActivitySessionAssembler
    private let makeEnvelopeID: @Sendable () -> UUID
    private let statusDidChange: (@Sendable (ServerUploadStatus) async -> Void)?
    private let now: @Sendable () -> Date
    private let jitter: @Sendable () -> Double
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var currentSession: ActivitySessionState?
    private var sessionRecovered = false
    private var needsReconciliation = false
    private var sessionRecoveryTask: Task<SessionRecovery, Error>?
    private var pending: [TelemetryEnvelope] = []
    private var isSubmitting = false
    private var automaticUploadsStopped = false
    private var uploadsPausedForCapture = true
    private var retryAttempt = 0
    private var retryAfter: Date?
    private var retryTask: Task<Void, Never>?
    private var configurationGeneration = 0
    private var status = ServerUploadStatus.notConfigured

    init(
        archive: TelemetryArchive,
        sink: any TelemetrySink,
        installationID: UUID,
        makeRunID: @escaping @Sendable () -> UUID = { UUID() },
        makeEnvelopeID: @escaping @Sendable () -> UUID = { UUID() },
        statusDidChange: (@Sendable (ServerUploadStatus) async -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.75...1.25) },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { delay in
            try? await Task.sleep(for: .seconds(delay))
        }
    ) {
        self.archive = archive
        self.sink = sink
        self.installationID = installationID
        self.assembler = ActivitySessionAssembler(makeRunID: makeRunID)
        self.makeEnvelopeID = makeEnvelopeID
        self.statusDidChange = statusDidChange
        self.now = now
        self.jitter = jitter
        self.sleep = sleep
    }

    func ingest(_ sample: TelemetrySample, from deviceID: UUID) async throws -> IngestResult {
        uploadsPausedForCapture = false
        return try await ingest(
            sample,
            from: deviceID,
            selectedDeviceID: deviceID,
            captureEnabled: true
        )
    }

    func ingest(
        _ sample: TelemetrySample,
        from deviceID: UUID,
        phoneReceivedAt: Date? = nil,
        selectedDeviceID: UUID?,
        captureEnabled: Bool = true
    ) async throws -> IngestResult {
        let receivedAt = phoneReceivedAt ?? now()
        guard captureEnabled else {
            return observedResult(
                sample: sample,
                receivedAt: receivedAt,
                reason: .captureDisabled
            )
        }
        try await ensureSessionRecovered()

        let input = ActivitySessionInput(
            deviceID: deviceID,
            selectedDeviceID: selectedDeviceID,
            phoneReceivedAt: receivedAt,
            sample: sample
        )
        var transition = assembler.propose(input: input, current: currentSession)
        var receiptPersisted = false

        do {
            if let opening = currentSession,
               opening.phase == .opening,
               input.deviceID == input.selectedDeviceID {
                let canReuseOpening: Bool
                if case .assignExisting = transition.action {
                    canReuseOpening = sample.state == .running
                } else {
                    canReuseOpening = false
                }
                if !canReuseOpening {
                    if let priorClosure = opening.pendingPriorClosure {
                        try await archive.closeRun(priorClosure)
                    }
                    try await archive.closeRun(PendingSessionClosure(
                        localRunID: opening.localRunID,
                        closingReason: .openingAbandoned,
                        closedAt: receivedAt
                    ))
                    try await archive.deleteCurrentSession()
                    currentSession = nil
                    transition = assembler.propose(input: input, current: nil)
                }
            }

            switch transition.action {
            case .observe(let reason):
                return observedResult(sample: sample, receivedAt: receivedAt, reason: reason)

            case .closeWithoutAssignment(let reason):
                if let closure = transition.priorClosure {
                    try await archive.closeRun(closure)
                }
                try await archive.deleteCurrentSession()
                currentSession = nil
                return IngestResult(
                    sample: sample,
                    phoneReceivedAt: receivedAt,
                    envelope: nil,
                    session: nil,
                    boundaryReason: transition.priorClosure?.closingReason ?? reason,
                    observationReason: nil,
                    acknowledgedIDs: [],
                    serverStatus: status
                )

            case .assignExisting:
                guard var proposed = transition.proposedState,
                      let runID = transition.assignedRunID else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let openingPriorClosure = currentSession?.phase == .opening
                    ? currentSession?.pendingPriorClosure
                    : nil
                let envelopeID = currentSession?.phase == .opening
                    ? currentSession?.openingSampleEnvelopeID ?? makeEnvelopeID()
                    : makeEnvelopeID()
                let envelope = makeEnvelope(
                    id: envelopeID,
                    runID: runID,
                    sample: sample,
                    deviceID: deviceID,
                    receivedAt: receivedAt
                )
                try await archive.append(envelope)
                receiptPersisted = true
                if let openingPriorClosure {
                    try await archive.closeRun(openingPriorClosure)
                }
                proposed.phase = phase(for: sample.state)
                proposed.openingSampleEnvelopeID = nil
                proposed.pendingPriorClosure = nil
                var metadata = try await archive.runMetadata(runID: runID) ?? ActivityRunMetadata(session: proposed)
                metadata.activityStartEpochSeconds = proposed.activityStartEpochSeconds
                metadata.restoredAfterRelaunch = proposed.restoredAfterRelaunch
                try await archive.writeRunMetadata(metadata)
                try await archive.writeCurrentSession(proposed)
                currentSession = proposed
                return assignedResult(envelope, session: proposed, reason: nil)

            case .startNew, .split:
                guard var proposed = transition.proposedState,
                      let runID = transition.assignedRunID else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let envelopeID = makeEnvelopeID()
                var opening = proposed
                opening.phase = .opening
                opening.openingSampleEnvelopeID = envelopeID
                opening.pendingPriorClosure = transition.priorClosure
                try await archive.writeCurrentSession(opening)
                try await archive.writeRunMetadata(ActivityRunMetadata(session: opening))

                let envelope = makeEnvelope(
                    id: envelopeID,
                    runID: runID,
                    sample: sample,
                    deviceID: deviceID,
                    receivedAt: receivedAt
                )
                try await archive.append(envelope)
                receiptPersisted = true
                if let closure = transition.priorClosure {
                    try await archive.closeRun(closure)
                }
                proposed.phase = .active
                proposed.openingSampleEnvelopeID = nil
                proposed.pendingPriorClosure = nil
                try await archive.writeRunMetadata(ActivityRunMetadata(session: proposed))
                try await archive.writeCurrentSession(proposed)
                currentSession = proposed
                let reason: ActivityBoundaryReason
                switch transition.action {
                case .split(let splitReason): reason = splitReason
                default: reason = .firstRunning
                }
                return assignedResult(envelope, session: proposed, reason: reason)

            case .assignAndClose(let reason):
                guard let runID = transition.assignedRunID,
                      let closure = transition.priorClosure else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let envelope = makeEnvelope(
                    id: makeEnvelopeID(),
                    runID: runID,
                    sample: sample,
                    deviceID: deviceID,
                    receivedAt: receivedAt
                )
                try await archive.append(envelope)
                receiptPersisted = true
                try await archive.closeRun(closure)
                try await archive.deleteCurrentSession()
                currentSession = nil
                return assignedResult(envelope, session: nil, reason: reason)
            }
        } catch {
            needsReconciliation = true
            sessionRecovered = false
            throw TelemetryIngestionFailure(
                receiptPersisted: receiptPersisted,
                message: String(describing: error)
            )
        }
    }

    @discardableResult
    func recoverPending() async throws -> ServerUploadStatus {
        try await ensureSessionRecovered()
        let recovered = try await archive.pendingEnvelopes()
        var envelopesByID = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, $0) })
        for envelope in recovered where envelopesByID[envelope.id] == nil {
            envelopesByID[envelope.id] = envelope
        }
        pending = envelopesByID.values.sorted { $0.phoneReceivedAt < $1.phoneReceivedAt }
        status.pendingCount = pending.count
        _ = await flushPending(force: false)
        return status
    }

    @discardableResult
    func retryPending(force: Bool = false) async -> ServerUploadStatus {
        if force {
            automaticUploadsStopped = false
            retryAfter = nil
            retryTask?.cancel()
            retryTask = nil
        }
        _ = await flushPending(force: force)
        return status
    }

    func currentStatus() -> ServerUploadStatus { status }

    func captureChanged(enabled: Bool) async -> ServerUploadStatus {
        uploadsPausedForCapture = !enabled
        if !enabled {
            configurationGeneration += 1
        } else {
            _ = await flushPending(force: false)
        }
        return status
    }

    func currentActivitySession() async throws -> ActivitySessionState? {
        try await ensureSessionRecovered()
        return currentSession
    }

    func reconcileSession() async throws {
        try await ensureSessionRecovered()
    }

    func canChangeCaptureDevice() async throws -> Bool {
        try await ensureSessionRecovered()
        return currentSession == nil
    }

    func configurationChanged(configured: Bool) async -> ServerUploadStatus {
        configurationGeneration += 1
        automaticUploadsStopped = false
        retryAttempt = 0
        retryAfter = nil
        retryTask?.cancel()
        retryTask = nil
        status.state = configured ? "Ready" : "Not configured"
        if configured { _ = await flushPending(force: true) }
        return status
    }

    func deleteAllTelemetry() async throws {
        try await archive.deleteAll()
        configurationGeneration += 1
        pending.removeAll()
        currentSession = nil
        sessionRecovered = true
        needsReconciliation = false
        retryTask?.cancel()
        retryTask = nil
        status = .notConfigured
    }

    private func flushPending(force: Bool) async -> [UUID] {
        guard !isSubmitting, !pending.isEmpty else { return [] }
        guard !uploadsPausedForCapture else { return [] }
        guard force || (!automaticUploadsStopped && retryAfter.map { now() >= $0 } != false) else { return [] }

        isSubmitting = true
        defer { isSubmitting = false }
        var allAcknowledged: [UUID] = []

        while !pending.isEmpty {
            if uploadsPausedForCapture { break }
            let batch = Array(pending.prefix(100))
            let submissionGeneration = configurationGeneration
            do {
                let acknowledged = try await sink.submit(batch)
                if submissionGeneration != configurationGeneration { continue }
                let requested = Set(batch.map(\.id))
                let acknowledgedSet = Set(acknowledged).intersection(requested)
                for runID in Set(batch.map(\.localRunID)) {
                    let runAcknowledgements = batch
                        .filter { $0.localRunID == runID && acknowledgedSet.contains($0.id) }
                        .map(\.id)
                    try await archive.appendAcknowledgements(runAcknowledgements, runID: runID)
                }
                pending.removeAll { acknowledgedSet.contains($0.id) }
                allAcknowledged.append(contentsOf: acknowledgedSet)
                status.pendingCount = pending.count
                status.lastUploadAt = now()
                if !acknowledgedSet.isEmpty { status.lastAcknowledgementAt = now() }
                status.state = acknowledgedSet.count == batch.count ? "Current" : "Partial acknowledgement"
                retryAttempt = 0
                retryAfter = nil
                retryTask?.cancel()
                retryTask = nil
                if acknowledgedSet.isEmpty || acknowledgedSet.count < batch.count {
                    scheduleRetry(after: nil)
                    break
                }
            } catch let error as TelemetrySinkError {
                if submissionGeneration != configurationGeneration { continue }
                handleSinkError(error)
                break
            } catch {
                if submissionGeneration != configurationGeneration { continue }
                scheduleRetry(after: nil)
                status.state = "Temporary upload failure"
                break
            }
        }
        if let statusDidChange {
            await statusDidChange(status)
        }
        return allAcknowledged
    }

    private func handleSinkError(_ error: TelemetrySinkError) {
        switch error {
        case .notConfigured:
            automaticUploadsStopped = true
            retryTask?.cancel()
            retryTask = nil
            status.state = "Not configured"
        case .permanent(let reason):
            automaticUploadsStopped = true
            retryTask?.cancel()
            retryTask = nil
            status.state = reason
        case .transient(let serverDelay):
            scheduleRetry(after: serverDelay)
            status.state = "Temporary upload failure"
        }
    }

    private func scheduleRetry(after serverDelay: TimeInterval?) {
        retryAttempt = min(retryAttempt + 1, 8)
        let exponential = min(300, pow(2, Double(retryAttempt - 1))) * jitter()
        retryAfter = now().addingTimeInterval(max(serverDelay ?? 0, exponential))
        armRetry()
    }

    private func armRetry() {
        guard let retryAfter else { return }
        let delay = max(0, retryAfter.timeIntervalSince(now()))
        retryTask?.cancel()
        retryTask = Task { [weak self, sleep] in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            await self?.retryDeadlineReached(retryAfter)
        }
    }

    private func retryDeadlineReached(_ expected: Date) async {
        guard retryAfter == expected, !automaticUploadsStopped else { return }
        retryTask = nil
        _ = await flushPending(force: false)
    }

    private func ensureSessionRecovered() async throws {
        guard !sessionRecovered || needsReconciliation else { return }
        let task: Task<SessionRecovery, Error>
        if let sessionRecoveryTask {
            task = sessionRecoveryTask
        } else {
            let archive = self.archive
            let created = Task { try await Self.recoverSession(from: archive) }
            sessionRecoveryTask = created
            task = created
        }

        let recovery: SessionRecovery
        do {
            recovery = try await task.value
        } catch {
            sessionRecoveryTask = nil
            throw error
        }
        guard !sessionRecovered || needsReconciliation else { return }
        currentSession = recovery.session
        var pendingByID = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, $0) })
        for envelope in recovery.pending where pendingByID[envelope.id] == nil {
            pendingByID[envelope.id] = envelope
        }
        pending = pendingByID.values.sorted {
            if $0.phoneReceivedAt != $1.phoneReceivedAt {
                return $0.phoneReceivedAt < $1.phoneReceivedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        status.pendingCount = pending.count
        needsReconciliation = false
        sessionRecovered = true
        sessionRecoveryTask = nil
        if !pending.isEmpty {
            Task { [weak self] in _ = await self?.flushPending(force: false) }
        }
    }

    private nonisolated static func recoverSession(
        from archive: TelemetryArchive
    ) async throws -> SessionRecovery {
        let restored = try await archive.currentSession()
        var recovered = restored

        if let session = restored {
            if let metadata = try await archive.runMetadata(runID: session.localRunID),
               metadata.closedAt != nil {
                try await archive.deleteCurrentSession()
                recovered = nil
            }
        }

        if var session = recovered {
            let latest = try await archive.latestEnvelope(runID: session.localRunID)
            if session.phase == .opening,
               let openingID = session.openingSampleEnvelopeID,
               try await archive.containsEnvelope(openingID, runID: session.localRunID),
               let latest {
                session = applying(latest, to: session)
                session.phase = phase(for: latest.sample.state)
                session.openingSampleEnvelopeID = nil
                if let closure = session.pendingPriorClosure {
                    try await archive.closeRun(closure)
                }
                session.pendingPriorClosure = nil
                try await archive.writeRunMetadata(ActivityRunMetadata(session: session))
                if latest.sample.state == .ended {
                    let closure = PendingSessionClosure(
                        localRunID: session.localRunID,
                        closingReason: .watchEnded,
                        closedAt: latest.phoneReceivedAt
                    )
                    try await archive.closeRun(closure)
                    try await archive.deleteCurrentSession()
                    recovered = nil
                } else {
                    try await archive.writeCurrentSession(session)
                    recovered = session
                }
            } else if let latest, latest.phoneReceivedAt > session.lastPhoneReceivedAt {
                if latest.sample.state == .ended {
                    let closure = PendingSessionClosure(
                        localRunID: session.localRunID,
                        closingReason: .watchEnded,
                        closedAt: latest.phoneReceivedAt
                    )
                    try await archive.closeRun(closure)
                    try await archive.deleteCurrentSession()
                    recovered = nil
                } else {
                    session = applying(latest, to: session)
                    try await archive.writeCurrentSession(session)
                    recovered = session
                }
            }
        }

        if var recovered {
            recovered.restoredAfterRelaunch = true
            try await archive.writeCurrentSession(recovered)
            if var metadata = try await archive.runMetadata(runID: recovered.localRunID) {
                metadata.restoredAfterRelaunch = true
                metadata.activityStartEpochSeconds = recovered.activityStartEpochSeconds
                try await archive.writeRunMetadata(metadata)
            }
            let pending = try await archive.pendingEnvelopes()
            return SessionRecovery(session: recovered, pending: pending)
        }
        let pending = try await archive.pendingEnvelopes()
        return SessionRecovery(session: nil, pending: pending)
    }

    private nonisolated static func applying(
        _ envelope: TelemetryEnvelope,
        to session: ActivitySessionState
    ) -> ActivitySessionState {
        var next = session
        next.phase = phase(for: envelope.sample.state)
        next.activityStartEpochSeconds = session.activityStartEpochSeconds ?? envelope.sample.activityStartEpochSeconds
        next.lastElapsedTimeMilliseconds = envelope.sample.elapsedTimeMilliseconds ?? session.lastElapsedTimeMilliseconds
        next.lastDistanceDecimeters = envelope.sample.distanceDecimeters ?? session.lastDistanceDecimeters
        next.lastActivityState = envelope.sample.state
        next.lastWatchSequence = envelope.sample.sequence
        next.lastPhoneReceivedAt = envelope.phoneReceivedAt
        return next
    }

    private nonisolated static func phase(for state: ActivityState) -> ActivitySessionPhase {
        switch state {
        case .paused: .paused
        case .stopped: .stopped
        default: .active
        }
    }

    private func phase(for state: ActivityState) -> ActivitySessionPhase {
        Self.phase(for: state)
    }

    private func makeEnvelope(
        id: UUID,
        runID: UUID,
        sample: TelemetrySample,
        deviceID: UUID,
        receivedAt: Date
    ) -> TelemetryEnvelope {
        TelemetryEnvelope(
            id: id,
            installationID: installationID,
            localRunID: runID,
            phoneReceivedAt: receivedAt,
            garminDeviceIdentifier: deviceID,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            sample: sample
        )
    }

    private func observedResult(
        sample: TelemetrySample,
        receivedAt: Date,
        reason: ActivityObservationReason
    ) -> IngestResult {
        IngestResult(
            sample: sample,
            phoneReceivedAt: receivedAt,
            envelope: nil,
            session: currentSession,
            boundaryReason: nil,
            observationReason: reason,
            acknowledgedIDs: [],
            serverStatus: status
        )
    }

    private func assignedResult(
        _ envelope: TelemetryEnvelope,
        session: ActivitySessionState?,
        reason: ActivityBoundaryReason?
    ) -> IngestResult {
        pending.append(envelope)
        status.pendingCount = pending.count
        Task { [weak self] in
            _ = await self?.flushPending(force: false)
        }
        return IngestResult(
            sample: envelope.sample,
            phoneReceivedAt: envelope.phoneReceivedAt,
            envelope: envelope,
            session: session,
            boundaryReason: reason,
            observationReason: nil,
            acknowledgedIDs: [],
            serverStatus: status
        )
    }
}
