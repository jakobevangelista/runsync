import Foundation
import Network

protocol TelemetryConnectivityMonitoring: Sendable {
    func start(_ update: @escaping @Sendable (ConnectivityStatus) -> Void)
    func cancel()
}

final class TelemetryConnectivityMonitor: TelemetryConnectivityMonitoring, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue

    init(
        monitor: NWPathMonitor = NWPathMonitor(),
        queue: DispatchQueue = DispatchQueue(label: "com.jakobevangelista.runsync.telemetry-connectivity")
    ) {
        self.monitor = monitor
        self.queue = queue
    }

    func start(_ update: @escaping @Sendable (ConnectivityStatus) -> Void) {
        monitor.pathUpdateHandler = { path in
            let state: ConnectivityState
            switch path.status {
            case .satisfied: state = .satisfied
            case .unsatisfied: state = .unsatisfied
            case .requiresConnection: state = .requiresConnection
            @unknown default: state = .unknown
            }
            let interface: ConnectivityInterface
            if path.usesInterfaceType(.wifi) {
                interface = .wifi
            } else if path.usesInterfaceType(.cellular) {
                interface = .cellular
            } else if path.usesInterfaceType(.wiredEthernet) {
                interface = .wiredEthernet
            } else if state == .satisfied {
                interface = .other
            } else {
                interface = .unavailable
            }
            update(ConnectivityStatus(
                state: state,
                interface: interface,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            ))
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }
}

struct TelemetryIngestionFailure: Error, Sendable {
    let receiptPersisted: Bool
    let message: String
}

actor TelemetryIngestor {
    private struct SessionRecovery: Sendable {
        let session: ActivitySessionState?
        let latestEnvelope: TelemetryEnvelope?
    }

    private enum RejectionResolution {
        case continueUploading(batchLimit: Int?)
        case stop
    }

    private enum ProbeResult {
        case acknowledged
        case rejected(TelemetryServerRejection)
        case stopped
    }

    private struct SubmissionWaiter {
        let envelopeIDs: Set<UUID>
        let generation: Int
        let continuation: CheckedContinuation<Bool, Never>
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
    private let connectivityMonitor: (any TelemetryConnectivityMonitoring)?
    private let currentAppVersion: @Sendable () -> String
    private let backgroundUploader: BackgroundTelemetryUploadManager?
    private let sessionRecoveryCheckpoint: @Sendable () async -> Void
    private var currentSession: ActivitySessionState?
    private var sessionRecovered = false
    private var needsReconciliation = false
    private var sessionRecoveryTask: Task<SessionRecovery, Error>?
    private var pending: [TelemetryEnvelope] = []
    private var quarantinedIDs: Set<UUID> = []
    private var isSubmitting = false
    private var foregroundLeasedIDs: Set<UUID> = []
    private var submissionOwnerGeneration: Int?
    private var submissionWaiters: [SubmissionWaiter] = []
    private var automaticUploadsStopped = false
    private var retryAttempt = 0
    private var retryAfter: Date?
    private var retryEnvelopeIDs: Set<UUID> = []
    private var retryTask: Task<Void, Never>?
    private var retryTriggerPending = false
    private var configurationGeneration = 0
    private var deletionInProgress = false
    private var uploadStopBeforeDeletion: (
        automatic: Bool,
        uploadState: TelemetryUploadState,
        errorCategory: String?
    )?
    private var configurationChangeDuringDeletion: Bool?
    private var activeIngestionCount = 0
    private var ingestionWaiters: [CheckedContinuation<Void, Never>] = []
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
        },
        connectivityMonitor: (any TelemetryConnectivityMonitoring)? = nil,
        backgroundUploader: BackgroundTelemetryUploadManager? = nil,
        sessionRecoveryCheckpoint: @escaping @Sendable () async -> Void = {},
        currentAppVersion: @escaping @Sendable () -> String = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
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
        self.connectivityMonitor = connectivityMonitor
        self.backgroundUploader = backgroundUploader
        self.sessionRecoveryCheckpoint = sessionRecoveryCheckpoint
        self.currentAppVersion = currentAppVersion
    }

    func ingest(_ sample: TelemetrySample, from deviceID: UUID) async throws -> IngestResult {
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
        guard !deletionInProgress else { throw CancellationError() }
        activeIngestionCount += 1
        defer { ingestionDidFinish() }
        let receivedAt = phoneReceivedAt ?? now()
        status.lastWatchReceiptAt = receivedAt
        applyWatchDiagnostics(from: sample)
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
                status.lastArchiveAt = envelope.phoneReceivedAt
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
                status.lastArchiveAt = envelope.phoneReceivedAt
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
                status.lastArchiveAt = envelope.phoneReceivedAt
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
        guard !deletionInProgress else { return statusSnapshot() }
        try await scanOutbox()
        _ = await flushPending(bypassBackoff: false, allowBlockedRetry: false)
        return statusSnapshot()
    }

    @discardableResult
    func applicationBecameActive() async throws -> ServerUploadStatus {
        guard !deletionInProgress else { return statusSnapshot() }
        try await scanOutbox()
        bypassTransientBackoff()
        Task { [weak self] in
            _ = await self?.flushPending(bypassBackoff: true, allowBlockedRetry: false)
        }
        return statusSnapshot()
    }

    @discardableResult
    func prepareManualRecovery() async throws -> ServerUploadStatus {
        guard !deletionInProgress else { return statusSnapshot() }
        try await archive.releaseAllQuarantine()
        quarantinedIDs.removeAll()
        status.quarantineCount = 0
        status.lastQuarantinedEnvelopeID = nil
        status.lastSafeErrorCategory = nil
        try await scanOutbox()
        bypassTransientBackoff()
        Task { [weak self] in
            _ = await self?.flushPending(bypassBackoff: true, allowBlockedRetry: true)
        }
        return statusSnapshot()
    }

    func startConnectivityMonitoring() {
        connectivityMonitor?.start { [weak self] connectivity in
            Task { await self?.connectivityChanged(connectivity) }
        }
    }

    private func scanOutbox() async throws {
        guard !deletionInProgress else { return }
        let generation = configurationGeneration
        try await archive.releaseQuarantineFromOlderAppVersions(currentAppVersion: currentAppVersion())
        let scan = try await archive.scanPendingEnvelopes()
        guard !deletionInProgress, generation == configurationGeneration else { return }
        pending = scan.pendingEnvelopes.sorted(by: Self.isOrderedBefore)
        quarantinedIDs = Set(scan.quarantined.map(\.envelopeID))
        status.localArchiveIssueCount = scan.issues.count
        status.quarantineCount = scan.quarantined.count
        let previousQuarantineID = status.lastQuarantinedEnvelopeID
        if let latest = scan.quarantined.max(by: { $0.quarantinedAt < $1.quarantinedAt }) {
            status.lastQuarantinedEnvelopeID = latest.envelopeID
            status.lastSafeErrorCategory = latest.category
        } else {
            status.lastQuarantinedEnvelopeID = nil
            if previousQuarantineID != nil { status.lastSafeErrorCategory = nil }
        }
        updatePendingStatus()
        await publishStatus()
    }

    @discardableResult
    func retryPending(force: Bool = false) async -> ServerUploadStatus {
        guard !deletionInProgress else { return statusSnapshot() }
        if force {
            bypassTransientBackoff()
        }
        _ = await flushPending(bypassBackoff: force, allowBlockedRetry: force)
        return statusSnapshot()
    }

    func retryQuarantined() async -> ServerUploadStatus {
        guard !deletionInProgress else { return statusSnapshot() }
        do {
            try await archive.releaseAllQuarantine()
            quarantinedIDs.removeAll()
            status.quarantineCount = 0
            status.lastQuarantinedEnvelopeID = nil
            status.lastSafeErrorCategory = nil
            try await scanOutbox()
            bypassTransientBackoff()
            _ = await flushPending(bypassBackoff: true, allowBlockedRetry: true)
        } catch {
            blockUploads(reason: "Quarantine recovery unavailable", category: "quarantine_storage")
            await publishStatus()
        }
        return statusSnapshot()
    }

    func currentStatus() -> ServerUploadStatus { statusSnapshot() }

    func deletionIsInProgress() -> Bool { deletionInProgress }

    func coordinatorWaiterCount() -> Int { submissionWaiters.count }

    func retryTriggerIsPending() -> Bool { retryTriggerPending }

    func captureChanged(enabled: Bool) async -> ServerUploadStatus {
        if enabled, !deletionInProgress {
            Task { [weak self] in
                _ = await self?.flushPending(bypassBackoff: false, allowBlockedRetry: false)
            }
        }
        return statusSnapshot()
    }

    func currentActivitySession() async throws -> ActivitySessionState? {
        guard !deletionInProgress else { return nil }
        try await ensureSessionRecovered()
        return currentSession
    }

    func reconcileSession() async throws {
        guard !deletionInProgress else { throw CancellationError() }
        try await ensureSessionRecovered()
    }

    func canChangeCaptureDevice() async throws -> Bool {
        guard !deletionInProgress else { return false }
        try await ensureSessionRecovered()
        return currentSession == nil
    }

    func configurationChanged(configured: Bool) async -> ServerUploadStatus {
        guard !deletionInProgress else {
            configurationChangeDuringDeletion = configured
            return statusSnapshot()
        }
        return await applyConfigurationChange(configured: configured)
    }

    private func applyConfigurationChange(configured: Bool) async -> ServerUploadStatus {
        configurationGeneration += 1
        (sink as? any CancellableTelemetrySink)?.cancelAll()
        do {
            try await backgroundUploader?.configurationDidChange()
        } catch {
            blockUploads(reason: "Upload configuration unavailable", category: "configuration_storage")
            await publishStatus()
            return statusSnapshot()
        }
        automaticUploadsStopped = false
        retryAttempt = 0
        retryAfter = nil
        retryEnvelopeIDs.removeAll()
        retryTriggerPending = false
        retryTask?.cancel()
        retryTask = nil
        status.uploadState = configured ? .idle : .notConfigured
        if configured {
            do {
                try await archive.releaseAllQuarantine()
                quarantinedIDs.removeAll()
                status.quarantineCount = 0
                status.lastQuarantinedEnvelopeID = nil
                status.lastSafeErrorCategory = nil
                try await scanOutbox()
            } catch {
                blockUploads(reason: "Quarantine recovery unavailable", category: "quarantine_storage")
                await publishStatus()
                return statusSnapshot()
            }
            _ = await flushPending(bypassBackoff: true, allowBlockedRetry: true)
        }
        return statusSnapshot()
    }

    func deleteAllTelemetry() async throws {
        if !deletionInProgress {
            deletionInProgress = true
            uploadStopBeforeDeletion = (
                automaticUploadsStopped,
                status.uploadState,
                status.lastSafeErrorCategory
            )
            configurationGeneration += 1
            automaticUploadsStopped = true
            retryAttempt = 0
            retryAfter = nil
            retryEnvelopeIDs.removeAll()
            retryTriggerPending = false
            retryTask?.cancel()
            retryTask = nil
            (sink as? any CancellableTelemetrySink)?.cancelAll()
            foregroundLeasedIDs.removeAll()
            invalidateSubmissionWaiters()
            pending.removeAll()
            updatePendingStatus()
            let recoveryTask = sessionRecoveryTask
            recoveryTask?.cancel()
            sessionRecoveryTask = nil

            await waitForIngestionQuiescence()
            if let recoveryTask { _ = await recoveryTask.result }
        }
        if let backgroundUploader {
            try await backgroundUploader.deleteAllTelemetry()
        } else {
            try await archive.deleteAll()
        }
        currentSession = nil
        sessionRecovered = true
        needsReconciliation = false
        status = .notConfigured
        if let prior = uploadStopBeforeDeletion, prior.automatic {
            automaticUploadsStopped = true
            status.uploadState = prior.uploadState
            status.lastSafeErrorCategory = prior.errorCategory
        } else if let backgroundUploader {
            do {
                let configured = try await backgroundUploader.requestBinding() != nil
                automaticUploadsStopped = !configured
                status.uploadState = configured ? .idle : .notConfigured
                status.lastSafeErrorCategory = configured ? nil : "configuration"
            } catch {
                blockUploads(reason: "Upload configuration unavailable", category: "configuration_storage")
            }
        } else {
            automaticUploadsStopped = false
            status.uploadState = .notConfigured
        }
        uploadStopBeforeDeletion = nil
        deletionInProgress = false
        if let configured = configurationChangeDuringDeletion {
            configurationChangeDuringDeletion = nil
            _ = await applyConfigurationChange(configured: configured)
        }
        await publishStatus()
    }

    func backgroundUploadCompleted(
        metadata: BackgroundUploadMetadata,
        outcome: BackgroundUploadOutcome
    ) async {
        guard !deletionInProgress else { return }
        let completionGeneration = configurationGeneration
        guard await acquireSubmissionLease(
            envelopeIDs: Set(metadata.envelopeIDs),
            generation: completionGeneration
        ) else { return }
        var leaseHeld = true
        defer {
            if leaseHeld { releaseSubmissionLease() }
        }
        guard !deletionInProgress, completionGeneration == configurationGeneration else { return }
        do {
            try await scanOutbox()
        } catch {
            guard !deletionInProgress, completionGeneration == configurationGeneration else { return }
            blockUploads(reason: "Upload archive unavailable", category: "archive_storage")
            await publishStatus()
            return
        }
        guard !deletionInProgress, completionGeneration == configurationGeneration else { return }

        switch outcome {
        case .stale:
            break
        case .acknowledged(let acknowledged):
            clearRetry(for: Set(acknowledged))
            if !automaticUploadsStopped {
                if activeRetryEnvelopeIDs().isEmpty {
                    status.uploadState = pending.isEmpty ? .current : .idle
                } else {
                    status.uploadState = status.connectivity.state == .satisfied
                        ? .backingOff
                        : .waitingForConnectivity
                }
            }
            status.lastAcknowledgementAt = now()
        case .partial(let acknowledged):
            if !acknowledged.isEmpty { status.lastAcknowledgementAt = now() }
            clearRetry(for: Set(acknowledged))
            let failedIDs = Set(metadata.envelopeIDs).subtracting(acknowledged)
            scheduleRetry(after: nil, envelopeIDs: failedIDs)
            status.uploadState = .backingOff
            status.lastSafeErrorCategory = "partial_acknowledgement"
        case .failed(.rejected(let rejection)):
            let envelopeIDs = Set(metadata.envelopeIDs)
            let batch = pending.filter { envelopeIDs.contains($0.id) }
            if batch.isEmpty {
                scheduleRetry(after: nil, envelopeIDs: envelopeIDs)
                status.uploadState = .backingOff
            } else {
                _ = await handleRejection(
                    rejection,
                    batch: batch,
                    generation: configurationGeneration,
                    batchLimit: min(100, batch.count)
                )
            }
        case .failed(let error):
            handleSinkError(error, envelopeIDs: Set(metadata.envelopeIDs))
        }

        updatePendingStatus()
        await publishStatus()
        let shouldStartSuccessor: Bool
        if case .acknowledged = outcome,
           !pending.isEmpty, !automaticUploadsStopped {
            let blockedIDs = activeRetryEnvelopeIDs()
            shouldStartSuccessor = pending.contains { !blockedIDs.contains($0.id) }
        } else {
            shouldStartSuccessor = false
        }
        releaseSubmissionLease()
        leaseHeld = false

        if shouldStartSuccessor {
            if retryEnvelopeIDs.isEmpty { await stageBackgroundIfNeeded() }
            Task { [weak self] in
                _ = await self?.flushPending(bypassBackoff: false, allowBlockedRetry: false)
            }
        }
    }

    private func flushPending(bypassBackoff: Bool, allowBlockedRetry: Bool) async -> [UUID] {
        guard !deletionInProgress, !isSubmitting, !pending.isEmpty else { return [] }
        guard !automaticUploadsStopped || allowBlockedRetry else { return [] }

        guard beginSubmissionLease(
            envelopeIDs: Set(pending.map(\.id)),
            generation: configurationGeneration
        ) else { return [] }
        if allowBlockedRetry { automaticUploadsStopped = false }
        await backgroundUploader?.resumePreparedIfEnabled()
        guard !deletionInProgress else {
            releaseSubmissionLease()
            return []
        }
        var allAcknowledged: [UUID] = []
        var batchLimit = 100
        var backgroundHandoffIDs: Set<UUID> = []

        while !pending.isEmpty {
            let leased = backgroundUploader?.leasedEnvelopeIDs() ?? []
            let blockedByBackoff = bypassBackoff ? Set<UUID>() : activeRetryEnvelopeIDs()
            let available = pending.filter {
                !leased.contains($0.id) && !blockedByBackoff.contains($0.id)
            }
            guard !available.isEmpty else { break }
            let batch = Array(available.prefix(batchLimit))
            let submissionGeneration = configurationGeneration
            let binding: TelemetryUploadBinding?
            do {
                binding = try await backgroundUploader?.requestBinding()
            } catch {
                guard !deletionInProgress, submissionGeneration == configurationGeneration else { break }
                handleSinkError(.notConfigured)
                break
            }
            let submissionFence = binding?.fence
            guard !deletionInProgress,
                  submissionGeneration == configurationGeneration,
                  backgroundUploader == nil || binding != nil else { break }
            status.uploadState = .submitting
            status.lastAttemptAt = now()
            await publishStatus()
            do {
                let acknowledged = try await submit(batch, binding: binding)
                guard await submissionIsCurrent(generation: submissionGeneration, fence: submissionFence) else {
                    continue
                }
                let acknowledgedSet = try await applyAcknowledgements(
                    acknowledged,
                    for: batch,
                    fence: submissionFence
                )
                allAcknowledged.append(contentsOf: acknowledgedSet)
                status.uploadState = acknowledgedSet.count == batch.count ? .current : .backingOff
                clearRetry(for: acknowledgedSet)
                if acknowledgedSet.isEmpty || acknowledgedSet.count < batch.count {
                    let failedIDs = Set(batch.map(\.id)).subtracting(acknowledgedSet)
                    scheduleRetry(
                        after: nil,
                        envelopeIDs: failedIDs
                    )
                    backgroundHandoffIDs.formUnion(failedIDs)
                    break
                } else if !activeRetryEnvelopeIDs().isEmpty {
                    status.uploadState = status.connectivity.state == .satisfied
                        ? .backingOff
                        : .waitingForConnectivity
                }
            } catch let error as TelemetrySinkError {
                guard await submissionIsCurrent(generation: submissionGeneration, fence: submissionFence) else {
                    continue
                }
                if case .rejected(let rejection) = error {
                    let resolution = await handleRejection(
                        rejection,
                        batch: batch,
                        generation: submissionGeneration,
                        batchLimit: batchLimit
                    )
                    switch resolution {
                    case .continueUploading(let reducedLimit):
                        if let reducedLimit { batchLimit = reducedLimit }
                        continue
                    case .stop:
                        if status.uploadState == .backingOff
                            || status.uploadState == .waitingForConnectivity {
                            backgroundHandoffIDs.formUnion(batch.map(\.id))
                        }
                        break
                    }
                } else {
                    handleSinkError(error, envelopeIDs: Set(batch.map(\.id)))
                    if case .transient = error {
                        backgroundHandoffIDs.formUnion(batch.map(\.id))
                    }
                }
                break
            } catch {
                guard await submissionIsCurrent(generation: submissionGeneration, fence: submissionFence) else {
                    continue
                }
                scheduleRetry(after: nil, envelopeIDs: Set(batch.map(\.id)))
                backgroundHandoffIDs.formUnion(batch.map(\.id))
                status.uploadState = status.connectivity.state == .satisfied ? .backingOff : .waitingForConnectivity
                break
            }
        }
        let shouldStageAfterSubmission = status.uploadState == .backingOff
            || status.uploadState == .waitingForConnectivity
        releaseSubmissionLease()
        if shouldStageAfterSubmission {
            await stageBackgroundIfNeeded(includingBackoffEnvelopeIDs: backgroundHandoffIDs)
        }
        await publishStatus()
        return allAcknowledged
    }

    private func handleSinkError(
        _ error: TelemetrySinkError,
        envelopeIDs: Set<UUID> = []
    ) {
        switch error {
        case .notConfigured:
            automaticUploadsStopped = true
            retryTask?.cancel()
            retryTask = nil
            status.uploadState = .notConfigured
            status.lastSafeErrorCategory = "configuration"
        case .authentication:
            blockUploads(reason: "Authentication rejected", category: "authentication")
        case .rejected(let rejection):
            blockUploads(
                reason: "Upload rejected",
                category: rejection.code?.rawValue ?? "unknown_rejection"
            )
        case .permanent(let reason):
            blockUploads(reason: reason, category: "configuration")
        case .transient(let serverDelay):
            scheduleRetry(after: serverDelay, envelopeIDs: envelopeIDs)
            status.uploadState = status.connectivity.state == .satisfied ? .backingOff : .waitingForConnectivity
        }
    }

    private func handleRejection(
        _ rejection: TelemetryServerRejection,
        batch: [TelemetryEnvelope],
        generation: Int,
        batchLimit: Int
    ) async -> RejectionResolution {
        if rejection.retryable == true {
            scheduleRetry(after: nil, envelopeIDs: Set(batch.map(\.id)))
            status.uploadState = .backingOff
            status.lastSafeErrorCategory = "server_retryable"
            return .stop
        }
        switch rejection.statusCode {
        case 400:
            return blockRejection(reason: "Client request incompatible", category: "request_malformed")
        case 404, 405:
            return blockRejection(reason: "Telemetry endpoint unavailable", category: "endpoint_configuration")
        case 415:
            return blockRejection(reason: "Client content type rejected", category: "content_type")
        case 413:
            if batch.count > 1 {
                return .continueUploading(batchLimit: max(1, min(batchLimit, batch.count / 2)))
            }
            return await confirmAndQuarantine(
                batch[0],
                expected: rejection,
                category: "oversized_envelope",
                generation: generation
            )
        case 403:
            if rejection.code == .installationOwnershipConflict {
                return blockRejection(
                    reason: "Installation ownership conflict",
                    category: "installation_ownership_conflict"
                )
            }
            if rejection.code == .envelopeOwnershipConflict,
               let envelope = attributedEnvelope(for: rejection, in: batch) {
                return await confirmAndQuarantine(
                    envelope,
                    expected: rejection,
                    category: "envelope_ownership_conflict",
                    generation: generation
                )
            }
            return blockRejection(reason: "Ownership conflict", category: "ownership_conflict")
        case 409:
            guard let envelope = attributedEnvelope(for: rejection, in: batch) else {
                return blockRejection(reason: "Unattributed envelope conflict", category: "envelope_conflict")
            }
            guard rejection.code == .envelopeConflict else {
                return blockRejection(reason: "Unknown envelope conflict", category: "envelope_conflict")
            }
            return await confirmAndQuarantine(
                envelope,
                expected: rejection,
                category: rejection.code?.rawValue ?? "envelope_conflict",
                generation: generation
            )
        case 422:
            if rejection.code == .unsupportedProtocol {
                return blockRejection(reason: "App update required", category: "unsupported_protocol")
            }
            if rejection.code == .invalidEnvelope {
                if let envelope = attributedEnvelope(for: rejection, in: batch) {
                    return await confirmAndQuarantine(
                        envelope,
                        expected: rejection,
                        category: "invalid_envelope",
                        generation: generation
                    )
                }
                return await isolateUnattributedInvalidEnvelope(
                    batch,
                    rejection: rejection,
                    generation: generation,
                    depth: 0
                )
            }
            return blockRejection(reason: "Client protocol incompatible", category: "client_compatibility")
        default:
            return blockRejection(reason: "Server rejected upload", category: "unknown_rejection")
        }
    }

    private func isolateUnattributedInvalidEnvelope(
        _ batch: [TelemetryEnvelope],
        rejection: TelemetryServerRejection,
        generation: Int,
        depth: Int
    ) async -> RejectionResolution {
        guard !batch.isEmpty, depth < 8 else {
            return blockRejection(reason: "Envelope isolation limit reached", category: "invalid_envelope")
        }
        if batch.count == 1 {
            return await confirmAndQuarantine(
                batch[0],
                expected: rejection,
                category: "invalid_envelope",
                generation: generation
            )
        }

        let midpoint = batch.count / 2
        let left = Array(batch[..<midpoint])
        let right = Array(batch[midpoint...])
        let leftResult = await submitProbe(left, generation: generation)
        guard case .stopped = leftResult else {
            let rightResult = await submitProbe(right, generation: generation)
            switch (leftResult, rightResult) {
            case (.acknowledged, .acknowledged):
                return .continueUploading(batchLimit: nil)
            case (.rejected(let leftError), .rejected(let rightError)):
                if sameRejection(leftError, rightError) {
                    return blockRejection(
                        reason: "Systemic envelope rejection",
                        category: "invalid_envelope_systemic"
                    )
                }
                return blockRejection(reason: "Ambiguous envelope rejection", category: "unknown_rejection")
            case (.rejected(let childError), .acknowledged):
                return await isolateRejectedChild(
                    left,
                    rejection: childError,
                    generation: generation,
                    depth: depth + 1
                )
            case (.acknowledged, .rejected(let childError)):
                return await isolateRejectedChild(
                    right,
                    rejection: childError,
                    generation: generation,
                    depth: depth + 1
                )
            default:
                return .stop
            }
        }
        return .stop
    }

    private func isolateRejectedChild(
        _ batch: [TelemetryEnvelope],
        rejection: TelemetryServerRejection,
        generation: Int,
        depth: Int
    ) async -> RejectionResolution {
        guard rejection.statusCode == 422, rejection.code == .invalidEnvelope else {
            return blockRejection(reason: "Isolation changed rejection", category: "unknown_rejection")
        }
        if let envelope = attributedEnvelope(for: rejection, in: batch) {
            return await confirmAndQuarantine(
                envelope,
                expected: rejection,
                category: "invalid_envelope",
                generation: generation
            )
        }
        return await isolateUnattributedInvalidEnvelope(
            batch,
            rejection: rejection,
            generation: generation,
            depth: depth
        )
    }

    private func submitProbe(_ batch: [TelemetryEnvelope], generation: Int) async -> ProbeResult {
        guard !deletionInProgress, generation == configurationGeneration else { return .stopped }
        let binding: TelemetryUploadBinding?
        if let backgroundUploader {
            do {
                binding = try await backgroundUploader.requestBinding()
            } catch {
                handleSinkError(.notConfigured)
                return .stopped
            }
        } else {
            binding = nil
        }
        let submissionFence = binding?.fence
        guard !deletionInProgress, generation == configurationGeneration,
              backgroundUploader == nil || submissionFence != nil else { return .stopped }
        status.uploadState = .submitting
        status.lastAttemptAt = now()
        await publishStatus()
        do {
            let acknowledged = try await submit(batch, binding: binding)
            guard await submissionIsCurrent(generation: generation, fence: submissionFence) else { return .stopped }
            let acknowledgedSet = try await applyAcknowledgements(
                acknowledged,
                for: batch,
                fence: submissionFence
            )
            guard acknowledgedSet.count == batch.count else {
                scheduleRetry(
                    after: nil,
                    envelopeIDs: Set(batch.map(\.id)).subtracting(acknowledgedSet)
                )
                status.uploadState = .backingOff
                return .stopped
            }
            return .acknowledged
        } catch let error as TelemetrySinkError {
            guard generation == configurationGeneration else { return .stopped }
            if case .rejected(let rejection) = error { return .rejected(rejection) }
            handleSinkError(error, envelopeIDs: Set(batch.map(\.id)))
            return .stopped
        } catch {
            scheduleRetry(after: nil, envelopeIDs: Set(batch.map(\.id)))
            status.uploadState = .backingOff
            return .stopped
        }
    }

    private func confirmAndQuarantine(
        _ envelope: TelemetryEnvelope,
        expected: TelemetryServerRejection,
        category: String,
        generation: Int
    ) async -> RejectionResolution {
        let confirmation = await submitProbe([envelope], generation: generation)
        switch confirmation {
        case .acknowledged:
            return .continueUploading(batchLimit: nil)
        case .stopped:
            return .stop
        case .rejected(let repeated):
            guard sameRejection(expected, repeated),
                  repeated.envelopeID == nil || repeated.envelopeID == envelope.id else {
                return blockRejection(reason: "Envelope rejection changed", category: "unknown_rejection")
            }
            do {
                try await archive.quarantine(TelemetryQuarantineRecord(
                    envelopeID: envelope.id,
                    runID: envelope.localRunID,
                    category: category,
                    serverCode: repeated.code,
                    statusCode: repeated.statusCode,
                    quarantinedAt: now(),
                    appVersion: currentAppVersion()
                ))
                quarantinedIDs.insert(envelope.id)
                pending.removeAll { $0.id == envelope.id }
                clearRetry(for: [envelope.id])
                automaticUploadsStopped = false
                status.quarantineCount = quarantinedIDs.count
                status.lastQuarantinedEnvelopeID = envelope.id
                status.lastSafeErrorCategory = category
                status.uploadState = .idle
                updatePendingStatus()
                return .continueUploading(batchLimit: nil)
            } catch {
                return blockRejection(reason: "Could not protect quarantine metadata", category: "quarantine_storage")
            }
        }
    }

    private func applyAcknowledgements(
        _ acknowledged: [UUID],
        for batch: [TelemetryEnvelope],
        fence: TelemetryUploadFence? = nil
    ) async throws -> Set<UUID> {
        let requested = Set(batch.map(\.id))
        let acknowledgedSet = Set(acknowledged).intersection(requested)
        for runID in Set(batch.map(\.localRunID)) {
            let runAcknowledgements = batch
                .filter { $0.localRunID == runID && acknowledgedSet.contains($0.id) }
                .map(\.id)
            if let fence {
                guard try await archive.appendAcknowledgements(
                    runAcknowledgements,
                    runID: runID,
                    fence: fence
                ) else { return [] }
            } else {
                try await archive.appendAcknowledgements(runAcknowledgements, runID: runID)
            }
        }
        pending.removeAll { acknowledgedSet.contains($0.id) }
        updatePendingStatus()
        if !acknowledgedSet.isEmpty { status.lastAcknowledgementAt = now() }
        return acknowledgedSet
    }

    private func attributedEnvelope(
        for rejection: TelemetryServerRejection,
        in batch: [TelemetryEnvelope]
    ) -> TelemetryEnvelope? {
        guard let envelopeID = rejection.envelopeID else { return nil }
        return batch.first { $0.id == envelopeID }
    }

    private func sameRejection(
        _ lhs: TelemetryServerRejection,
        _ rhs: TelemetryServerRejection
    ) -> Bool {
        lhs.statusCode == rhs.statusCode && lhs.code == rhs.code && lhs.retryable == rhs.retryable
    }

    private func blockRejection(reason: String, category: String) -> RejectionResolution {
        blockUploads(reason: reason, category: category)
        return .stop
    }

    private func blockUploads(reason: String, category: String) {
        automaticUploadsStopped = true
        retryTriggerPending = false
        retryTask?.cancel()
        retryTask = nil
        status.uploadState = .blocked(reason)
        status.lastSafeErrorCategory = category
    }

    private func scheduleRetry(
        after serverDelay: TimeInterval?,
        envelopeIDs: Set<UUID>
    ) {
        guard !envelopeIDs.isEmpty else { return }
        retryTriggerPending = false
        retryEnvelopeIDs.formUnion(envelopeIDs)
        retryAttempt = min(retryAttempt + 1, Self.retryDelays.count)
        let exponential = Self.retryDelay(attempt: retryAttempt, jitter: jitter())
        let proposed = now().addingTimeInterval(max(serverDelay ?? 0, exponential))
        retryAfter = max(retryAfter ?? proposed, proposed)
        armRetry()
    }

    private func clearRetry(for envelopeIDs: Set<UUID>) {
        retryEnvelopeIDs.subtract(envelopeIDs)
        guard retryEnvelopeIDs.isEmpty else { return }
        retryAttempt = 0
        retryAfter = nil
        retryTriggerPending = false
        retryTask?.cancel()
        retryTask = nil
    }

    private func activeRetryEnvelopeIDs() -> Set<UUID> {
        guard let retryAfter, now() < retryAfter else { return [] }
        return retryEnvelopeIDs
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
        guard !isSubmitting else {
            retryTriggerPending = true
            return
        }
        _ = await flushPending(bypassBackoff: false, allowBlockedRetry: false)
    }

    private func ensureSessionRecovered() async throws {
        guard !deletionInProgress else { throw CancellationError() }
        guard !sessionRecovered || needsReconciliation else { return }
        let generation = configurationGeneration
        let task: Task<SessionRecovery, Error>
        if let sessionRecoveryTask {
            task = sessionRecoveryTask
        } else {
            let archive = self.archive
            let checkpoint = sessionRecoveryCheckpoint
            let created = Task { try await Self.recoverSession(from: archive, checkpoint: checkpoint) }
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
        guard !deletionInProgress, generation == configurationGeneration else { throw CancellationError() }
        guard !sessionRecovered || needsReconciliation else { return }
        currentSession = recovery.session
        if let latestEnvelope = recovery.latestEnvelope {
            status.lastWatchReceiptAt = latestEnvelope.phoneReceivedAt
            applyWatchDiagnostics(from: latestEnvelope.sample)
        }
        needsReconciliation = false
        sessionRecovered = true
        sessionRecoveryTask = nil
    }

    private nonisolated static func recoverSession(
        from archive: TelemetryArchive,
        checkpoint: @Sendable () async -> Void
    ) async throws -> SessionRecovery {
        let restored = try await archive.currentSession()
        await checkpoint()
        try Task.checkCancellation()
        var recovered = restored
        var latestRecoveredEnvelope: TelemetryEnvelope?

        if let session = restored {
            if let metadata = try await archive.runMetadata(runID: session.localRunID),
               metadata.closedAt != nil {
                try Task.checkCancellation()
                try await archive.deleteCurrentSession()
                recovered = nil
            }
        }

        if var session = recovered {
            let latest = try await archive.latestEnvelope(runID: session.localRunID)
            latestRecoveredEnvelope = latest
            if session.phase == .opening,
               let openingID = session.openingSampleEnvelopeID,
               try await archive.containsEnvelope(openingID, runID: session.localRunID),
               let latest {
                session = applying(latest, to: session)
                session.phase = phase(for: latest.sample.state)
                session.openingSampleEnvelopeID = nil
                if let closure = session.pendingPriorClosure {
                    try Task.checkCancellation()
                    try await archive.closeRun(closure)
                }
                session.pendingPriorClosure = nil
                try Task.checkCancellation()
                try await archive.writeRunMetadata(ActivityRunMetadata(session: session))
                if latest.sample.state == .ended {
                    let closure = PendingSessionClosure(
                        localRunID: session.localRunID,
                        closingReason: .watchEnded,
                        closedAt: latest.phoneReceivedAt
                    )
                    try Task.checkCancellation()
                    try await archive.closeRun(closure)
                    try await archive.deleteCurrentSession()
                    recovered = nil
                } else {
                    try Task.checkCancellation()
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
                    try Task.checkCancellation()
                    try await archive.closeRun(closure)
                    try await archive.deleteCurrentSession()
                    recovered = nil
                } else {
                    session = applying(latest, to: session)
                    try Task.checkCancellation()
                    try await archive.writeCurrentSession(session)
                    recovered = session
                }
            }
        }

        if var recovered {
            recovered.restoredAfterRelaunch = true
            try Task.checkCancellation()
            try await archive.writeCurrentSession(recovered)
            if var metadata = try await archive.runMetadata(runID: recovered.localRunID) {
                metadata.restoredAfterRelaunch = true
                metadata.activityStartEpochSeconds = recovered.activityStartEpochSeconds
                try Task.checkCancellation()
                try await archive.writeRunMetadata(metadata)
            }
            return SessionRecovery(session: recovered, latestEnvelope: latestRecoveredEnvelope)
        }
        return SessionRecovery(session: nil, latestEnvelope: latestRecoveredEnvelope)
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
            serverStatus: statusSnapshot()
        )
    }

    private func assignedResult(
        _ envelope: TelemetryEnvelope,
        session: ActivitySessionState?,
        reason: ActivityBoundaryReason?
    ) -> IngestResult {
        pending.append(envelope)
        pending.sort(by: Self.isOrderedBefore)
        status.lastArchiveAt = envelope.phoneReceivedAt
        updatePendingStatus()
        if !deletionInProgress {
            Task { [weak self] in await self?.uploadAfterArchiving() }
        }
        return IngestResult(
            sample: envelope.sample,
            phoneReceivedAt: envelope.phoneReceivedAt,
            envelope: envelope,
            session: session,
            boundaryReason: reason,
            observationReason: nil,
            acknowledgedIDs: [],
            serverStatus: statusSnapshot()
        )
    }

    private func connectivityChanged(_ connectivity: ConnectivityStatus) async {
        let becameSatisfied = status.connectivity.state != .satisfied && connectivity.state == .satisfied
        status.connectivity = connectivity
        if becameSatisfied {
            bypassTransientBackoff()
            Task { [weak self] in
                _ = await self?.flushPending(bypassBackoff: true, allowBlockedRetry: false)
            }
        } else if connectivity.state != .satisfied {
            await stageBackgroundIfNeeded()
        }
        await publishStatus()
    }

    private func uploadAfterArchiving() async {
        guard !deletionInProgress else { return }
        _ = await flushPending(bypassBackoff: false, allowBlockedRetry: false)
    }

    private func bypassTransientBackoff() {
        retryAfter = nil
        retryEnvelopeIDs.removeAll()
        retryAttempt = 0
        retryTriggerPending = false
        retryTask?.cancel()
        retryTask = nil
    }

    private func updatePendingStatus() {
        status.pendingCount = pending.count
        status.oldestPendingAge = pending.first.map { max(0, now().timeIntervalSince($0.phoneReceivedAt)) }
    }

    private func applyWatchDiagnostics(from sample: TelemetrySample) {
        status.watchBuildID = sample.watchBuildID ?? status.watchBuildID
        status.watchTransportTimeoutCount = sample.transportTimeoutCount ?? status.watchTransportTimeoutCount
        status.watchTransportErrorCount = sample.transportErrorCount ?? status.watchTransportErrorCount
        status.watchTransportExceptionCount = sample.transportExceptionCount ?? status.watchTransportExceptionCount
        status.watchTransportConsecutiveFailures = sample.transportConsecutiveFailures ?? status.watchTransportConsecutiveFailures
        status.watchTransportLastOutcome = sample.transportLastOutcome ?? status.watchTransportLastOutcome
    }

    private func submissionIsCurrent(
        generation: Int,
        fence: TelemetryUploadFence?
    ) async -> Bool {
        guard generation == configurationGeneration else { return false }
        guard let backgroundUploader else { return true }
        guard let fence else { return false }
        return await backgroundUploader.isCurrent(fence)
    }

    private func stageBackgroundIfNeeded(
        includingBackoffEnvelopeIDs: Set<UUID> = []
    ) async {
        guard !deletionInProgress, !isSubmitting, let backgroundUploader else { return }
        guard !automaticUploadsStopped else { return }
        switch status.uploadState {
        case .blocked, .notConfigured: return
        default: break
        }
        let leased = backgroundUploader.leasedEnvelopeIDs()
        let blockedByBackoff = activeRetryEnvelopeIDs().subtracting(includingBackoffEnvelopeIDs)
        await backgroundUploader.stageIfEnabled(pending.filter {
            !leased.contains($0.id)
                && !foregroundLeasedIDs.contains($0.id)
                && !blockedByBackoff.contains($0.id)
        })
    }

    private func statusSnapshot() -> ServerUploadStatus {
        var snapshot = status
        snapshot.pendingCount = pending.count
        snapshot.oldestPendingAge = pending.first.map { max(0, now().timeIntervalSince($0.phoneReceivedAt)) }
        return snapshot
    }

    private func publishStatus() async {
        if let statusDidChange {
            await statusDidChange(statusSnapshot())
        }
    }

    nonisolated static let retryDelays: [TimeInterval] = [1, 2, 4, 8, 16, 32, 60, 120, 300]

    nonisolated static func retryDelay(attempt: Int, jitter: Double) -> TimeInterval {
        min(300, retryDelays[min(max(attempt, 1), retryDelays.count) - 1] * jitter)
    }

    private func submit(
        _ batch: [TelemetryEnvelope],
        binding: TelemetryUploadBinding?
    ) async throws -> [UUID] {
        if let binding, let boundSink = sink as? any BoundTelemetrySink {
            return try await boundSink.submit(batch, server: binding.server)
        }
        return try await sink.submit(batch)
    }

    private func ingestionDidFinish() {
        activeIngestionCount = max(0, activeIngestionCount - 1)
        guard activeIngestionCount == 0 else { return }
        let waiters = ingestionWaiters
        ingestionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForIngestionQuiescence() async {
        guard activeIngestionCount > 0 else { return }
        await withCheckedContinuation { ingestionWaiters.append($0) }
    }

    private func beginSubmissionLease(envelopeIDs: Set<UUID>, generation: Int) -> Bool {
        guard !deletionInProgress, generation == configurationGeneration, !isSubmitting else { return false }
        isSubmitting = true
        foregroundLeasedIDs = envelopeIDs
        submissionOwnerGeneration = generation
        return true
    }

    private func acquireSubmissionLease(envelopeIDs: Set<UUID>, generation: Int) async -> Bool {
        guard !deletionInProgress, generation == configurationGeneration else { return false }
        if beginSubmissionLease(envelopeIDs: envelopeIDs, generation: generation) { return true }
        return await withCheckedContinuation { continuation in
            submissionWaiters.append(SubmissionWaiter(
                envelopeIDs: envelopeIDs,
                generation: generation,
                continuation: continuation
            ))
        }
    }

    private func releaseSubmissionLease() {
        foregroundLeasedIDs.removeAll()
        submissionOwnerGeneration = nil
        while !submissionWaiters.isEmpty {
            let waiter = submissionWaiters.removeFirst()
            guard !deletionInProgress, waiter.generation == configurationGeneration else {
                waiter.continuation.resume(returning: false)
                continue
            }
            foregroundLeasedIDs = waiter.envelopeIDs
            submissionOwnerGeneration = waiter.generation
            waiter.continuation.resume(returning: true)
            return
        }
        isSubmitting = false
        replayPendingRetryTrigger()
    }

    private func replayPendingRetryTrigger() {
        guard retryTriggerPending, !deletionInProgress, !automaticUploadsStopped else { return }
        Task { [weak self] in await self?.consumePendingRetryTrigger() }
    }

    private func consumePendingRetryTrigger() async {
        guard retryTriggerPending, !isSubmitting, !deletionInProgress, !automaticUploadsStopped else { return }
        retryTriggerPending = false
        _ = await flushPending(bypassBackoff: false, allowBlockedRetry: false)
    }

    private func invalidateSubmissionWaiters() {
        let waiters = submissionWaiters
        submissionWaiters.removeAll()
        waiters.forEach { $0.continuation.resume(returning: false) }
    }

    private nonisolated static func isOrderedBefore(_ lhs: TelemetryEnvelope, _ rhs: TelemetryEnvelope) -> Bool {
        if lhs.phoneReceivedAt != rhs.phoneReceivedAt {
            return lhs.phoneReceivedAt < rhs.phoneReceivedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
