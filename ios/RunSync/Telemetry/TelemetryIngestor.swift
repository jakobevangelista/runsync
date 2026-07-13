import Foundation

actor TelemetryIngestor {
    private struct OpenRun {
        let id: UUID
        let deviceID: UUID
        let activityStart: Int?
        var lastElapsedTime: Int?
    }

    private let archive: TelemetryArchive
    private let sink: any TelemetrySink
    private let installationID: UUID
    private let now: @Sendable () -> Date
    private let jitter: @Sendable () -> Double
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var openRun: OpenRun?
    private var pending: [TelemetryEnvelope] = []
    private var isSubmitting = false
    private var automaticUploadsStopped = false
    private var retryAttempt = 0
    private var retryAfter: Date?
    private var retryTask: Task<Void, Never>?
    private var configurationGeneration = 0
    private var status = ServerUploadStatus.notConfigured

    init(
        archive: TelemetryArchive,
        sink: any TelemetrySink,
        installationID: UUID,
        now: @escaping @Sendable () -> Date = { Date() },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.75...1.25) },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { delay in
            try? await Task.sleep(for: .seconds(delay))
        }
    ) {
        self.archive = archive
        self.sink = sink
        self.installationID = installationID
        self.now = now
        self.jitter = jitter
        self.sleep = sleep
    }

    func ingest(_ sample: TelemetrySample, from deviceID: UUID) async throws -> IngestResult {
        let runID = selectRun(for: sample, deviceID: deviceID)
        let envelope = TelemetryEnvelope(
            id: UUID(),
            installationID: installationID,
            localRunID: runID,
            phoneReceivedAt: now(),
            garminDeviceIdentifier: deviceID,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            sample: sample
        )

        try await archive.append(envelope)
        pending.append(envelope)
        status.pendingCount = pending.count
        let acknowledged = await flushPending(force: false)

        if sample.state == .ended { openRun = nil }
        return IngestResult(envelope: envelope, acknowledgedIDs: acknowledged, serverStatus: status)
    }

    @discardableResult
    func recoverPending() async throws -> ServerUploadStatus {
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
        configurationGeneration += 1
        pending.removeAll()
        openRun = nil
        retryTask?.cancel()
        retryTask = nil
        status = .notConfigured
        try await archive.deleteAll()
    }

    private func flushPending(force: Bool) async -> [UUID] {
        guard !isSubmitting, !pending.isEmpty else { return [] }
        guard force || (!automaticUploadsStopped && retryAfter.map { now() >= $0 } != false) else { return [] }

        isSubmitting = true
        defer { isSubmitting = false }
        var allAcknowledged: [UUID] = []

        while !pending.isEmpty {
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

    private func selectRun(for sample: TelemetrySample, deviceID: UUID) -> UUID {
        let shouldStartNew: Bool
        if let openRun {
            let startChanged = sample.activityStartEpochSeconds != nil &&
                openRun.activityStart != nil && sample.activityStartEpochSeconds != openRun.activityStart
            let elapsedRegressed = sample.elapsedTimeMilliseconds != nil &&
                openRun.lastElapsedTime != nil && sample.elapsedTimeMilliseconds! < openRun.lastElapsedTime!
            shouldStartNew = openRun.deviceID != deviceID || startChanged || elapsedRegressed
        } else {
            shouldStartNew = true
        }

        if shouldStartNew {
            openRun = OpenRun(
                id: UUID(), deviceID: deviceID,
                activityStart: sample.activityStartEpochSeconds,
                lastElapsedTime: sample.elapsedTimeMilliseconds
            )
        } else {
            openRun?.lastElapsedTime = sample.elapsedTimeMilliseconds ?? openRun?.lastElapsedTime
        }
        return openRun!.id
    }
}
