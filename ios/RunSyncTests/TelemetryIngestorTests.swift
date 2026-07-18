import XCTest
@testable import RunSync

final class TelemetryIngestorTests: XCTestCase {
    func testArchivesBeforeMockFailure() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let sink = MockTelemetrySink(latencyNanoseconds: 0)
        await sink.setFailureInjection(true)
        let ingestor = TelemetryIngestor(archive: archive, sink: sink, installationID: UUID())

        let result = try await ingestor.ingest(TelemetryTestSupport.sample(), from: UUID())
        let envelope = try XCTUnwrap(result.envelope)
        for _ in 0..<50 {
            if await ingestor.currentStatus().state == "Temporary upload failure" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let envelopes = try await archive.envelopes(runID: envelope.localRunID)
        let acknowledgedIDs = try await archive.acknowledgedIDs(runID: envelope.localRunID)
        XCTAssertEqual(envelopes.map(\.id), [envelope.id])
        XCTAssertEqual(envelopes.map(\.sample), [envelope.sample])
        XCTAssertTrue(acknowledgedIDs.isEmpty)
        let status = await ingestor.currentStatus()
        XCTAssertEqual(status.pendingCount, 1)
        XCTAssertEqual(status.state, "Temporary upload failure")
    }

    func testRecoversArchivedPendingEnvelope() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let sink = MockTelemetrySink(latencyNanoseconds: 0)
        await sink.setFailureInjection(true)
        let firstIngestor = TelemetryIngestor(archive: archive, sink: sink, installationID: UUID())

        let firstResult = try await firstIngestor.ingest(TelemetryTestSupport.sample(), from: UUID())
        let runID = try XCTUnwrap(firstResult.envelope?.localRunID)

        await sink.setFailureInjection(false)
        let recoveredIngestor = TelemetryIngestor(archive: archive, sink: sink, installationID: UUID())
        _ = await recoveredIngestor.captureChanged(enabled: true)
        try await recoveredIngestor.recoverPending()

        let envelopes = try await archive.envelopes(runID: runID)
        let acknowledgements = try await archive.acknowledgedIDs(runID: runID)
        XCTAssertEqual(acknowledgements, Set(envelopes.map(\.id)))
    }

    func testPartialAcknowledgementIsNotResentAfterRelaunch() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let first = TelemetryTestSupport.envelope()
        let second = TelemetryEnvelope(
            id: UUID(), installationID: first.installationID, localRunID: first.localRunID,
            phoneReceivedAt: first.phoneReceivedAt.addingTimeInterval(1),
            garminDeviceIdentifier: first.garminDeviceIdentifier, appVersion: first.appVersion,
            sample: first.sample
        )
        try await archive.append(first)
        try await archive.append(second)

        let partialSink = PartialTelemetrySink(acknowledgedID: first.id)
        let firstIngestor = TelemetryIngestor(
            archive: archive, sink: partialSink, installationID: first.installationID
        )
        _ = await firstIngestor.captureChanged(enabled: true)
        _ = try await firstIngestor.recoverPending()

        let recoverySink = RecordingTelemetrySink()
        let recoveredIngestor = TelemetryIngestor(
            archive: archive, sink: recoverySink, installationID: first.installationID
        )
        _ = await recoveredIngestor.captureChanged(enabled: true)
        _ = try await recoveredIngestor.recoverPending()
        let submitted = await recoverySink.submittedIDs
        XCTAssertEqual(submitted, [second.id])
    }

    func testTransientFailureRetriesWithoutAnotherTrigger() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let sink = FailOnceTelemetrySink()
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: UUID(),
            jitter: { 0 }
        )

        let result = try await ingestor.ingest(TelemetryTestSupport.sample(), from: UUID())
        let envelope = try XCTUnwrap(result.envelope)
        for _ in 0..<50 {
            if await sink.submissionCount >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let submissionCount = await sink.submissionCount
        XCTAssertEqual(submissionCount, 2)
        let acknowledged = try await archive.acknowledgedIDs(runID: envelope.localRunID)
        XCTAssertEqual(acknowledged, [envelope.id])
    }

    func testPublishesStatusAfterBackgroundUploadCompletes() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = UploadStatusRecorder()
        let ingestor = TelemetryIngestor(
            archive: TelemetryArchive(rootURL: root),
            sink: RecordingTelemetrySink(),
            installationID: UUID(),
            statusDidChange: { status in await recorder.append(status) }
        )

        _ = try await ingestor.ingest(TelemetryTestSupport.sample(), from: UUID())
        for _ in 0..<50 {
            if await recorder.statuses.contains(where: { $0.pendingCount == 0 && $0.state == "Current" }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let statuses = await recorder.statuses
        XCTAssertTrue(statuses.contains { $0.pendingCount == 0 && $0.state == "Current" })
    }

    func testWaitingIsObservedWithoutArchivingOrUploading() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let sink = RecordingTelemetrySink()
        let ingestor = TelemetryIngestor(archive: archive, sink: sink, installationID: UUID())

        let result = try await ingestor.ingest(
            TelemetryTestSupport.sample(state: .waiting, start: nil, elapsed: 0),
            from: UUID()
        )

        XCTAssertNil(result.envelope)
        XCTAssertEqual(result.observationReason, .idleWaiting)
        let pending = try await archive.pendingEnvelopes()
        let submitted = await sink.submittedIDs
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(submitted.isEmpty)
    }

    func testMissingSelectedDeviceCannotCreateActivity() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: RecordingTelemetrySink(),
            installationID: UUID()
        )

        let result = try await ingestor.ingest(
            TelemetryTestSupport.sample(state: .running),
            from: UUID(),
            selectedDeviceID: nil
        )

        let pending = try await archive.pendingEnvelopes()
        XCTAssertNil(result.envelope)
        XCTAssertEqual(result.observationReason, .nonSelectedDevice)
        XCTAssertTrue(pending.isEmpty)
    }

    func testRelaunchRestoresActivityAfterEveryEnvelopeIsAcknowledged() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let sink = RecordingTelemetrySink()
        let installationID = UUID()
        let deviceID = UUID()
        let first = TelemetryIngestor(archive: archive, sink: sink, installationID: installationID)
        let firstResult = try await first.ingest(TelemetryTestSupport.sample(), from: deviceID)
        let firstEnvelope = try XCTUnwrap(firstResult.envelope)
        for _ in 0..<50 {
            if try await archive.acknowledgedIDs(runID: firstEnvelope.localRunID).contains(firstEnvelope.id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let restored = TelemetryIngestor(archive: archive, sink: sink, installationID: installationID)
        let secondResult = try await restored.ingest(
            TelemetryTestSupport.sample(sequence: 2, elapsed: 2_000),
            from: deviceID
        )

        XCTAssertEqual(secondResult.envelope?.localRunID, firstEnvelope.localRunID)
        XCTAssertTrue(secondResult.session?.restoredAfterRelaunch == true)
    }

    func testImplicitWaitingResetClosesAndNextRunningUsesNewActivity() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: RecordingTelemetrySink(),
            installationID: UUID()
        )
        let deviceID = UUID()
        let first = try await ingestor.ingest(TelemetryTestSupport.sample(), from: deviceID)
        let reset = try await ingestor.ingest(
            TelemetryTestSupport.sample(sequence: 2, state: .waiting, start: nil, elapsed: 0),
            from: deviceID
        )
        let second = try await ingestor.ingest(
            TelemetryTestSupport.sample(sequence: 3, state: .running, start: 456, elapsed: 1_000),
            from: deviceID
        )

        XCTAssertNil(reset.envelope)
        XCTAssertEqual(reset.boundaryReason, .implicitTimerReset)
        XCTAssertNotEqual(first.envelope?.localRunID, second.envelope?.localRunID)
    }

    func testOpeningIntentWithoutEnvelopeReusesIDForCompatibleRunningSample() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let runID = UUID()
        let envelopeID = UUID()
        let deviceID = UUID()
        let openedAt = Date(timeIntervalSince1970: 100)
        let opening = ActivitySessionState(
            localRunID: runID,
            garminDeviceIdentifier: deviceID,
            phase: .opening,
            activityStartEpochSeconds: 123,
            lastElapsedTimeMilliseconds: 1_000,
            lastDistanceDecimeters: 100,
            lastActivityState: .running,
            lastWatchSequence: 1,
            openedAt: openedAt,
            lastPhoneReceivedAt: openedAt,
            lastBoundaryReason: .firstRunning,
            openingSampleEnvelopeID: envelopeID
        )
        try await archive.writeCurrentSession(opening)
        try await archive.writeRunMetadata(ActivityRunMetadata(session: opening))
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: RecordingTelemetrySink(),
            installationID: UUID()
        )

        let result = try await ingestor.ingest(
            TelemetryTestSupport.sample(sequence: 2, state: .running, start: 123, elapsed: 2_000),
            from: deviceID,
            phoneReceivedAt: openedAt.addingTimeInterval(1),
            selectedDeviceID: deviceID
        )

        XCTAssertEqual(result.envelope?.localRunID, runID)
        XCTAssertEqual(result.envelope?.id, envelopeID)
        XCTAssertEqual(result.session?.phase, .active)
    }

    func testOpeningIntentWithoutEnvelopeIsAbandonedForWaiting() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let runID = UUID()
        let deviceID = UUID()
        let openedAt = Date(timeIntervalSince1970: 100)
        let opening = ActivitySessionState(
            localRunID: runID,
            garminDeviceIdentifier: deviceID,
            phase: .opening,
            activityStartEpochSeconds: 123,
            lastElapsedTimeMilliseconds: 1_000,
            lastDistanceDecimeters: 100,
            lastActivityState: .running,
            lastWatchSequence: 1,
            openedAt: openedAt,
            lastPhoneReceivedAt: openedAt,
            lastBoundaryReason: .firstRunning,
            openingSampleEnvelopeID: UUID()
        )
        try await archive.writeCurrentSession(opening)
        try await archive.writeRunMetadata(ActivityRunMetadata(session: opening))
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: RecordingTelemetrySink(),
            installationID: UUID()
        )

        let result = try await ingestor.ingest(
            TelemetryTestSupport.sample(sequence: 2, state: .waiting, start: nil, elapsed: 0),
            from: deviceID,
            phoneReceivedAt: openedAt.addingTimeInterval(1),
            selectedDeviceID: deviceID
        )

        let metadata = try await archive.runMetadata(runID: runID)
        let currentSession = try await ingestor.currentActivitySession()
        XCTAssertNil(result.envelope)
        XCTAssertEqual(result.observationReason, .idleWaiting)
        XCTAssertEqual(metadata?.closingReason, .openingAbandoned)
        XCTAssertNil(currentSession)
    }

    func testRecoveryDoesNotReopenSessionWhoseRunMetadataIsClosed() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let runID = UUID()
        let deviceID = UUID()
        let openedAt = Date(timeIntervalSince1970: 100)
        let session = ActivitySessionState(
            localRunID: runID,
            garminDeviceIdentifier: deviceID,
            phase: .stopped,
            activityStartEpochSeconds: 123,
            lastElapsedTimeMilliseconds: 30_000,
            lastDistanceDecimeters: 100,
            lastActivityState: .stopped,
            lastWatchSequence: 30,
            openedAt: openedAt,
            lastPhoneReceivedAt: openedAt.addingTimeInterval(30),
            lastBoundaryReason: .firstRunning
        )
        var metadata = ActivityRunMetadata(session: session)
        metadata.closedAt = openedAt.addingTimeInterval(31)
        metadata.closingReason = .implicitTimerReset
        metadata.implicitEndUsed = true
        try await archive.writeCurrentSession(session)
        try await archive.writeRunMetadata(metadata)
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: RecordingTelemetrySink(),
            installationID: UUID()
        )

        let recovered = try await ingestor.currentActivitySession()
        let pointer = try await archive.currentSession()

        XCTAssertNil(recovered)
        XCTAssertNil(pointer)
    }
}

private actor PartialTelemetrySink: TelemetrySink {
    let acknowledgedID: UUID
    init(acknowledgedID: UUID) { self.acknowledgedID = acknowledgedID }
    func submit(_ envelopes: [TelemetryEnvelope]) -> [UUID] { [acknowledgedID] }
}

private actor RecordingTelemetrySink: TelemetrySink {
    private(set) var submittedIDs: [UUID] = []
    func submit(_ envelopes: [TelemetryEnvelope]) -> [UUID] {
        submittedIDs.append(contentsOf: envelopes.map(\.id))
        return envelopes.map(\.id)
    }
}

private actor FailOnceTelemetrySink: TelemetrySink {
    private(set) var submissionCount = 0

    func submit(_ envelopes: [TelemetryEnvelope]) throws -> [UUID] {
        submissionCount += 1
        if submissionCount == 1 {
            throw TelemetrySinkError.transient(retryAfter: nil)
        }
        return envelopes.map(\.id)
    }
}

private actor UploadStatusRecorder {
    private(set) var statuses: [ServerUploadStatus] = []
    func append(_ status: ServerUploadStatus) { statuses.append(status) }
}
