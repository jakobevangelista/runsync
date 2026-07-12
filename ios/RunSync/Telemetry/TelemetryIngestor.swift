import Foundation

actor TelemetryIngestor {
    private struct OpenRun {
        let id: UUID
        let deviceID: UUID
        let activityStart: Int?
        var lastElapsedTime: Int?
    }

    private let archive: TelemetryArchive
    private let sink: MockTelemetrySink
    private let installationID: UUID
    private var openRun: OpenRun?
    private var pending: [TelemetryEnvelope] = []

    init(archive: TelemetryArchive, sink: MockTelemetrySink, installationID: UUID) {
        self.archive = archive
        self.sink = sink
        self.installationID = installationID
    }

    func ingest(_ sample: TelemetrySample, from deviceID: UUID) async throws -> IngestResult {
        let runID = selectRun(for: sample, deviceID: deviceID)
        let envelope = TelemetryEnvelope(
            id: UUID(),
            installationID: installationID,
            localRunID: runID,
            phoneReceivedAt: Date(),
            garminDeviceIdentifier: deviceID,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            sample: sample
        )

        try await archive.append(envelope)
        pending.append(envelope)
        let acknowledged = try await flushPending()

        if sample.state == .ended {
            openRun = nil
        }
        return IngestResult(envelope: envelope, acknowledgedIDs: acknowledged)
    }

    func setMockFailureInjection(_ enabled: Bool) async {
        await sink.setFailureInjection(enabled)
    }

    func recoverPending() async throws {
        pending = try await archive.pendingEnvelopes()
        _ = try await flushPending()
    }

    func deleteAllTelemetry() async throws {
        pending.removeAll()
        openRun = nil
        try await archive.deleteAll()
    }

    private func flushPending() async throws -> [UUID] {
        var allAcknowledged: [UUID] = []
        while !pending.isEmpty {
            let batch = Array(pending.prefix(3))
            let acknowledged = try await sink.submit(batch)
            let acknowledgedSet = Set(acknowledged)

            for runID in Set(batch.map(\.localRunID)) {
                let runAcknowledgements = batch
                    .filter { $0.localRunID == runID && acknowledgedSet.contains($0.id) }
                    .map(\.id)
                try await archive.appendAcknowledgements(runAcknowledgements, runID: runID)
            }

            pending.removeAll { acknowledgedSet.contains($0.id) }
            allAcknowledged.append(contentsOf: acknowledged)
            if acknowledged.isEmpty { break }
        }
        return allAcknowledged
    }

    private func selectRun(for sample: TelemetrySample, deviceID: UUID) -> UUID {
        let shouldStartNew: Bool
        if let openRun {
            let startChanged = sample.activityStartEpochSeconds != nil &&
                openRun.activityStart != nil &&
                sample.activityStartEpochSeconds != openRun.activityStart
            let elapsedRegressed = sample.elapsedTimeMilliseconds != nil &&
                openRun.lastElapsedTime != nil &&
                sample.elapsedTimeMilliseconds! < openRun.lastElapsedTime!
            shouldStartNew = openRun.deviceID != deviceID || startChanged || elapsedRegressed
        } else {
            shouldStartNew = true
        }

        if shouldStartNew {
            openRun = OpenRun(
                id: UUID(),
                deviceID: deviceID,
                activityStart: sample.activityStartEpochSeconds,
                lastElapsedTime: sample.elapsedTimeMilliseconds
            )
        } else {
            openRun?.lastElapsedTime = sample.elapsedTimeMilliseconds ?? openRun?.lastElapsedTime
        }

        return openRun!.id
    }
}
