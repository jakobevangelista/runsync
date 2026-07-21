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
            if await ingestor.currentStatus().uploadState == .waitingForConnectivity { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let envelopes = try await archive.envelopes(runID: envelope.localRunID)
        let acknowledgedIDs = try await archive.acknowledgedIDs(runID: envelope.localRunID)
        XCTAssertEqual(envelopes.map(\.id), [envelope.id])
        XCTAssertEqual(envelopes.map(\.sample), [envelope.sample])
        XCTAssertTrue(acknowledgedIDs.isEmpty)
        let status = await ingestor.currentStatus()
        XCTAssertEqual(status.pendingCount, 1)
        XCTAssertEqual(status.uploadState, .waitingForConnectivity)
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

    func testPausedCaptureDoesNotBlockArchivedUpload() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelope = TelemetryTestSupport.envelope()
        try await archive.append(envelope)
        let sink = RecordingTelemetrySink()
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: envelope.installationID
        )

        _ = await ingestor.captureChanged(enabled: false)
        _ = try await ingestor.recoverPending()

        let submitted = await sink.submittedIDs
        XCTAssertEqual(submitted, [envelope.id])
        let acknowledged = try await archive.acknowledgedIDs(runID: envelope.localRunID)
        XCTAssertEqual(acknowledged, [envelope.id])
    }

    func testOutboxUploadsWhenSessionReconciliationIsCorrupt() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelope = TelemetryTestSupport.envelope()
        try await archive.append(envelope)
        try Data("not-json".utf8).write(to: root.appendingPathComponent("session-state.json"))
        let sink = RecordingTelemetrySink()
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: envelope.installationID
        )

        _ = try await ingestor.recoverPending()

        let submitted = await sink.submittedIDs
        XCTAssertEqual(submitted, [envelope.id])
        do {
            _ = try await ingestor.currentActivitySession()
            XCTFail("Expected independent session recovery to fail")
        } catch {}
    }

    func testConnectivitySatisfiedTransitionBypassesBackoffOnce() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelope = TelemetryTestSupport.envelope()
        try await archive.append(envelope)
        let sink = MockTelemetrySink(latencyNanoseconds: 0)
        await sink.setFailureInjection(true)
        let monitor = TestConnectivityMonitor()
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: envelope.installationID,
            sleep: { _ in try? await Task.sleep(for: .seconds(60)) },
            connectivityMonitor: monitor
        )
        await ingestor.startConnectivityMonitoring()
        monitor.send(.init(
            state: .unsatisfied,
            interface: .unavailable,
            isExpensive: false,
            isConstrained: false
        ))
        _ = try await ingestor.recoverPending()
        await sink.setFailureInjection(false)

        monitor.send(.init(
            state: .satisfied,
            interface: .cellular,
            isExpensive: true,
            isConstrained: false
        ))
        for _ in 0..<50 {
            if await sink.hasAccepted(envelope.id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let accepted = await sink.hasAccepted(envelope.id)
        XCTAssertTrue(accepted)
        let status = await ingestor.currentStatus()
        XCTAssertEqual(status.connectivity.state, .satisfied)
        XCTAssertEqual(status.pendingCount, 0)
    }

    func testForegroundRescanBypassesTransientBackoff() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelope = TelemetryTestSupport.envelope()
        try await archive.append(envelope)
        let sink = MockTelemetrySink(latencyNanoseconds: 0)
        await sink.setFailureInjection(true)
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: envelope.installationID,
            sleep: { _ in try? await Task.sleep(for: .seconds(60)) }
        )
        _ = try await ingestor.recoverPending()
        await sink.setFailureInjection(false)

        _ = try await ingestor.applicationBecameActive()
        for _ in 0..<50 {
            if await sink.hasAccepted(envelope.id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let accepted = await sink.hasAccepted(envelope.id)
        XCTAssertTrue(accepted)
    }

    func testStatusSeparatesWatchArchiveAttemptAndAcknowledgementTimes() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let ingestor = TelemetryIngestor(
            archive: TelemetryArchive(rootURL: root),
            sink: RecordingTelemetrySink(),
            installationID: UUID(),
            now: { timestamp }
        )

        _ = try await ingestor.ingest(TelemetryTestSupport.sample(), from: UUID())
        for _ in 0..<50 {
            if await ingestor.currentStatus().lastAcknowledgementAt != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let status = await ingestor.currentStatus()
        XCTAssertEqual(status.lastWatchReceiptAt, timestamp)
        XCTAssertEqual(status.lastArchiveAt, timestamp)
        XCTAssertEqual(status.lastAttemptAt, timestamp)
        XCTAssertEqual(status.lastAcknowledgementAt, timestamp)
    }

    func testRetryPolicyUsesExpectedCappedSequenceAndJitter() {
        XCTAssertEqual(TelemetryIngestor.retryDelays, [1, 2, 4, 8, 16, 32, 60, 120, 300])
        XCTAssertEqual(TelemetryIngestor.retryDelay(attempt: 10, jitter: 1.25), 300)
    }

    func testConcurrentForegroundRecoverySubmitsEnvelopeOnce() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelope = TelemetryTestSupport.envelope()
        try await archive.append(envelope)
        let sink = SuspendedTelemetrySink()
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: envelope.installationID
        )

        let first = Task { try await ingestor.recoverPending() }
        await sink.waitUntilSubmitted()
        let second = Task { try await ingestor.recoverPending() }
        try await Task.sleep(for: .milliseconds(20))
        let countWhileSuspended = await sink.submissionCount
        XCTAssertEqual(countWhileSuspended, 1)
        await sink.resume()
        _ = try await first.value
        _ = try await second.value

        let finalSubmissionCount = await sink.submissionCount
        let acknowledgements = try await archive.acknowledgedIDs(runID: envelope.localRunID)
        XCTAssertEqual(finalSubmissionCount, 1)
        XCTAssertEqual(acknowledgements, [envelope.id])
    }

    func testBackgroundStagingExcludesForegroundEnvelopeLease() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("RunSync", isDirectory: true)
        let runs = storage.appendingPathComponent("Runs", isDirectory: true)
        let queueURL = storage.appendingPathComponent("UploadQueue", isDirectory: true)
        let gate = TelemetryUploadFenceGate()
        let control = TelemetryUploadControlStore(rootURL: storage, gate: gate)
        let archive = TelemetryArchive(
            rootURL: runs,
            storageRootURL: storage,
            uploadFenceGate: gate
        )
        let queue = BackgroundUploadQueue(rootURL: queueURL)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let configuration = ServerConfigurationStore(defaults: defaults, tokenStore: TestTokenStore())
        try await configuration.save(baseURL: "https://telemetry.example", token: "token")
        let currentConfiguration = try await configuration.current()
        let server = try XCTUnwrap(currentConfiguration)
        let envelope = TelemetryTestSupport.envelope()
        _ = try await control.bind(configuration: server, installationID: envelope.installationID)
        try await archive.append(envelope)
        let manager = BackgroundTelemetryUploadManager(
            archive: archive,
            configuration: configuration,
            installationID: envelope.installationID,
            control: control,
            queue: queue,
            activateSession: false,
            stagingEnabled: { true }
        )
        let sink = SuspendedTelemetrySink()
        let monitor = TestConnectivityMonitor()
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: envelope.installationID,
            connectivityMonitor: monitor,
            backgroundUploader: manager
        )
        await ingestor.startConnectivityMonitoring()

        let recovery = Task { try await ingestor.recoverPending() }
        await sink.waitUntilSubmitted()
        monitor.send(.init(
            state: .unsatisfied,
            interface: .unavailable,
            isExpensive: false,
            isConstrained: false
        ))
        try await Task.sleep(for: .milliseconds(20))
        let stagedWhileForegroundWasActive = try await queue.batches()
        XCTAssertTrue(stagedWhileForegroundWasActive.isEmpty)

        await sink.resume()
        _ = try await recovery.value
    }

    func testDeletionQuiescesSessionRecoveryAndCannotRewriteAfterDelete() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelope = TelemetryTestSupport.envelope()
        let session = ActivitySessionState(
            localRunID: envelope.localRunID,
            garminDeviceIdentifier: envelope.garminDeviceIdentifier,
            phase: .active,
            activityStartEpochSeconds: envelope.sample.activityStartEpochSeconds,
            lastElapsedTimeMilliseconds: envelope.sample.elapsedTimeMilliseconds,
            lastDistanceDecimeters: envelope.sample.distanceDecimeters,
            lastActivityState: envelope.sample.state,
            lastWatchSequence: envelope.sample.sequence,
            openedAt: envelope.phoneReceivedAt,
            lastPhoneReceivedAt: envelope.phoneReceivedAt,
            lastBoundaryReason: .firstRunning
        )
        try await archive.append(envelope)
        try await archive.writeRunMetadata(ActivityRunMetadata(session: session))
        try await archive.writeCurrentSession(session)
        let checkpoint = AsyncCheckpoint()
        let sink = RecordingTelemetrySink()
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: envelope.installationID,
            sessionRecoveryCheckpoint: { await checkpoint.suspend() }
        )

        let recovery = Task { try await ingestor.currentActivitySession() }
        await checkpoint.waitUntilSuspended()
        let deletion = Task { try await ingestor.deleteAllTelemetry() }
        while !(await ingestor.deletionIsInProgress()) { await Task.yield() }
        _ = await ingestor.retryPending(force: true)
        let submittedDuringDeletion = await sink.submittedIDs
        XCTAssertTrue(submittedDuringDeletion.isEmpty)
        await checkpoint.resume()
        _ = try? await recovery.value
        try await deletion.value

        let filesAfterDeletion = await archive.hasTelemetryFiles()
        let sessionAfterDeletion = try await archive.currentSession()
        XCTAssertFalse(filesAfterDeletion)
        XCTAssertNil(sessionAfterDeletion)
        try await Task.sleep(for: .milliseconds(20))
        let filesAfterRecoverySettled = await archive.hasTelemetryFiles()
        XCTAssertFalse(filesAfterRecoverySettled)
    }

    func testRetryableStructuredInvalidEnvelopeBacksOffWithoutQuarantine() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelope = matchingEnvelopes(count: 1)[0]
        try await archive.append(envelope)
        let sink = IsolationTelemetrySink(mode: .rejectAll(.init(
            statusCode: 422,
            code: .invalidEnvelope,
            envelopeID: envelope.id,
            retryable: true
        )))
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: envelope.installationID,
            sleep: { _ in try? await Task.sleep(for: .seconds(60)) },
            currentAppVersion: { "1.0" }
        )

        let status = try await ingestor.recoverPending()

        XCTAssertEqual(status.quarantineCount, 0)
        XCTAssertEqual(status.pendingCount, 1)
        XCTAssertEqual(status.lastSafeErrorCategory, "server_retryable")
        let submissionSizes = await sink.submissionSizes
        XCTAssertEqual(submissionSizes, [1])
    }

    func testBackgroundFailureOutcomesDoNotStageSuccessorsDuringBackoffOrBlock() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("RunSync", isDirectory: true)
        let gate = TelemetryUploadFenceGate()
        let control = TelemetryUploadControlStore(rootURL: storage, gate: gate)
        let archive = TelemetryArchive(
            rootURL: storage.appendingPathComponent("Runs", isDirectory: true),
            storageRootURL: storage,
            uploadFenceGate: gate
        )
        let queue = BackgroundUploadQueue(
            rootURL: storage.appendingPathComponent("UploadQueue", isDirectory: true)
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let configuration = ServerConfigurationStore(defaults: defaults, tokenStore: TestTokenStore())
        try await configuration.save(baseURL: "https://telemetry.example", token: "token")
        let envelope = TelemetryTestSupport.envelope()
        let bindingResult = try await control.bind(
            snapshot: try await configuration.snapshot(),
            installationID: envelope.installationID
        )
        let fence = try XCTUnwrap(bindingResult.binding?.fence)
        try await archive.append(envelope)
        let manager = BackgroundTelemetryUploadManager(
            archive: archive,
            configuration: configuration,
            installationID: envelope.installationID,
            control: control,
            queue: queue,
            activateSession: false,
            stagingEnabled: { true }
        )
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: RecordingTelemetrySink(),
            installationID: envelope.installationID,
            sleep: { _ in try? await Task.sleep(for: .seconds(60)) },
            backgroundUploader: manager
        )
        let metadata = backgroundMetadata(for: [envelope], fence: fence)

        await ingestor.backgroundUploadCompleted(
            metadata: metadata,
            outcome: .failed(.transient(retryAfter: 120))
        )
        let afterTransient = try await queue.batches()
        let transientStatus = await ingestor.currentStatus()
        XCTAssertTrue(afterTransient.isEmpty)
        XCTAssertEqual(transientStatus.uploadState, .waitingForConnectivity)

        await ingestor.backgroundUploadCompleted(
            metadata: metadata,
            outcome: .failed(.authentication)
        )
        let afterAuthentication = try await queue.batches()
        XCTAssertTrue(afterAuthentication.isEmpty)
        if case .blocked = await ingestor.currentStatus().uploadState {} else {
            XCTFail("Expected authentication to remain blocked")
        }
    }

    func testForegroundTransientStagesOnlyAfterSubmissionLeaseIsReleased() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("RunSync", isDirectory: true)
        let gate = TelemetryUploadFenceGate()
        let control = TelemetryUploadControlStore(rootURL: storage, gate: gate)
        let archive = TelemetryArchive(
            rootURL: storage.appendingPathComponent("Runs", isDirectory: true),
            storageRootURL: storage,
            uploadFenceGate: gate
        )
        let queue = BackgroundUploadQueue(
            rootURL: storage.appendingPathComponent("UploadQueue", isDirectory: true)
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let configuration = ServerConfigurationStore(defaults: defaults, tokenStore: TestTokenStore())
        try await configuration.save(baseURL: "https://telemetry.example", token: "token")
        let envelope = TelemetryTestSupport.envelope()
        _ = try await control.bind(
            snapshot: try await configuration.snapshot(),
            installationID: envelope.installationID
        )
        try await archive.append(envelope)
        let checkpoint = AsyncCheckpoint()
        let manager = BackgroundTelemetryUploadManager(
            archive: archive,
            configuration: configuration,
            installationID: envelope.installationID,
            control: control,
            queue: queue,
            activateSession: false,
            stagingEnabled: { true },
            stageCheckpoint: { await checkpoint.suspend() }
        )
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: TransientTelemetrySink(),
            installationID: envelope.installationID,
            sleep: { _ in try? await Task.sleep(for: .seconds(60)) },
            backgroundUploader: manager
        )

        let recovery = Task { try await ingestor.recoverPending() }
        await checkpoint.waitUntilSuspended()
        let statusWhileStaging = await ingestor.currentStatus()
        XCTAssertEqual(statusWhileStaging.uploadState, .waitingForConnectivity)
        await checkpoint.resume()
        _ = try await recovery.value
        try await manager.deleteAllTelemetry()
    }

    func testBackgroundRejectionConfirmationOwnsCoordinatorLease() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("RunSync", isDirectory: true)
        let gate = TelemetryUploadFenceGate()
        let control = TelemetryUploadControlStore(rootURL: storage, gate: gate)
        let archive = TelemetryArchive(
            rootURL: storage.appendingPathComponent("Runs", isDirectory: true),
            storageRootURL: storage,
            uploadFenceGate: gate
        )
        let queue = BackgroundUploadQueue(
            rootURL: storage.appendingPathComponent("UploadQueue", isDirectory: true)
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let configuration = ServerConfigurationStore(defaults: defaults, tokenStore: TestTokenStore())
        try await configuration.save(baseURL: "https://telemetry.example", token: "token")
        let envelopes = matchingEnvelopes(count: 2)
        let bindingResult = try await control.bind(
            snapshot: try await configuration.snapshot(),
            installationID: envelopes[0].installationID
        )
        let fence = try XCTUnwrap(bindingResult.binding?.fence)
        for envelope in envelopes { try await archive.append(envelope) }
        let stagingCheckpoint = AsyncCheckpoint()
        let manager = BackgroundTelemetryUploadManager(
            archive: archive,
            configuration: configuration,
            installationID: envelopes[0].installationID,
            control: control,
            queue: queue,
            activateSession: false,
            stagingEnabled: { true },
            stageCheckpoint: { await stagingCheckpoint.suspend() }
        )
        let rejection = TelemetryServerRejection(
            statusCode: 422,
            code: .invalidEnvelope,
            envelopeID: envelopes[0].id,
            retryable: false
        )
        let sink = SuspendedRejectionTelemetrySink(rejection: rejection)
        let monitor = TestConnectivityMonitor()
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: envelopes[0].installationID,
            connectivityMonitor: monitor,
            backgroundUploader: manager,
            currentAppVersion: { "1.0" }
        )
        await ingestor.startConnectivityMonitoring()
        let metadata = backgroundMetadata(for: [envelopes[0]], fence: fence)

        let completion = Task {
            await ingestor.backgroundUploadCompleted(
                metadata: metadata,
                outcome: .failed(.rejected(rejection))
            )
        }
        await sink.waitUntilSubmitted()
        let retry = Task { await ingestor.retryPending(force: true) }
        monitor.send(.init(
            state: .unsatisfied,
            interface: .unavailable,
            isExpensive: false,
            isConstrained: false
        ))
        try await Task.sleep(for: .milliseconds(20))

        let submissionCount = await sink.submissionCount
        let stagingStarted = await stagingCheckpoint.isSuspended
        let stagedBatches = try await queue.batches()
        XCTAssertEqual(submissionCount, 1)
        XCTAssertFalse(stagingStarted)
        XCTAssertTrue(stagedBatches.isEmpty)

        await sink.resume()
        await completion.value
        _ = await retry.value
        let status = await ingestor.currentStatus()
        XCTAssertEqual(status.quarantineCount, 1)
        XCTAssertEqual(status.pendingCount, 1)
    }

    func testDeleteInvalidatesQueuedBackgroundOutcomeFromPriorGeneration() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelope = TelemetryTestSupport.envelope()
        try await archive.append(envelope)
        let sink = SuspendedTelemetrySink()
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: envelope.installationID
        )
        let fence = TelemetryUploadFence(
            configurationGeneration: 1,
            destinationFingerprint: "test",
            deleteEpoch: 0
        )

        let foreground = Task { try await ingestor.recoverPending() }
        await sink.waitUntilSubmitted()
        let staleCompletion = Task {
            await ingestor.backgroundUploadCompleted(
                metadata: backgroundMetadata(for: [envelope], fence: fence),
                outcome: .failed(.authentication)
            )
        }
        while await ingestor.coordinatorWaiterCount() == 0 { await Task.yield() }

        try await ingestor.deleteAllTelemetry()
        await sink.resume()
        _ = try await foreground.value
        await staleCompletion.value

        let status = await ingestor.currentStatus()
        let archiveExists = await archive.hasTelemetryFiles()
        XCTAssertEqual(status.uploadState, .notConfigured)
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertFalse(archiveExists)
    }

    func testUnrelatedBackgroundSuccessDoesNotClearForegroundEnvelopeBackoff() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let first = matchingEnvelopes(count: 1)[0]
        try await archive.append(first)
        let sink = CountingTransientTelemetrySink()
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: first.installationID,
            sleep: { _ in try? await Task.sleep(for: .seconds(60)) }
        )
        _ = try await ingestor.recoverPending()
        let second = TelemetryEnvelope(
            id: UUID(),
            installationID: first.installationID,
            localRunID: first.localRunID,
            phoneReceivedAt: first.phoneReceivedAt.addingTimeInterval(1),
            garminDeviceIdentifier: first.garminDeviceIdentifier,
            appVersion: first.appVersion,
            sample: TelemetryTestSupport.sample(sequence: 2)
        )
        try await archive.append(second)
        try await archive.appendAcknowledgements([second.id], runID: second.localRunID)
        let fence = TelemetryUploadFence(
            configurationGeneration: 1,
            destinationFingerprint: "test",
            deleteEpoch: 0
        )

        await ingestor.backgroundUploadCompleted(
            metadata: backgroundMetadata(for: [second], fence: fence),
            outcome: .acknowledged([second.id])
        )
        _ = await ingestor.retryPending()

        let status = await ingestor.currentStatus()
        let submissionCount = await sink.submissionCount
        XCTAssertEqual(status.uploadState, .waitingForConnectivity)
        XCTAssertEqual(status.pendingCount, 1)
        XCTAssertEqual(submissionCount, 1)
    }

    func testRetryDeadlineOccupiedByCoordinatorReplaysAfterLeaseRelease() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelopes = matchingEnvelopes(count: 2)
        let failed = envelopes[0]
        let coordinatorOwned = envelopes[1]
        try await archive.append(failed)
        let sink = RetryCoordinatorTelemetrySink()
        let sleepGate = RetrySleepGate()
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: failed.installationID,
            jitter: { 0 },
            sleep: { _ in await sleepGate.sleep() }
        )
        _ = try await ingestor.recoverPending()
        await sleepGate.waitUntilSleeping()
        try await archive.append(coordinatorOwned)
        let fence = TelemetryUploadFence(
            configurationGeneration: 1,
            destinationFingerprint: "test",
            deleteEpoch: 0
        )
        let rejection = TelemetryServerRejection(
            statusCode: 409,
            code: .envelopeConflict,
            envelopeID: coordinatorOwned.id,
            retryable: false
        )
        let background = Task {
            await ingestor.backgroundUploadCompleted(
                metadata: backgroundMetadata(for: [coordinatorOwned], fence: fence),
                outcome: .failed(.rejected(rejection))
            )
        }
        await sink.waitForSubmissionCount(2)

        await sleepGate.fire()
        while !(await ingestor.retryTriggerIsPending()) { await Task.yield() }
        await sink.resumeSecondSubmission()
        await sink.waitForSubmissionCount(3)
        await background.value
        while (await ingestor.currentStatus()).pendingCount != 0 { await Task.yield() }

        let submittedIDs = await sink.submittedIDs
        let status = await ingestor.currentStatus()
        XCTAssertEqual(submittedIDs, [[failed.id], [coordinatorOwned.id], [failed.id]])
        XCTAssertEqual(status.pendingCount, 0)
    }

    func testRequestWideRejectionsBlockWithoutQuarantineOrReduction() async throws {
        for statusCode in [400, 404, 405, 415] {
            let root = try TelemetryTestSupport.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let archive = TelemetryArchive(rootURL: root)
            let envelopes = matchingEnvelopes(count: 2)
            for envelope in envelopes { try await archive.append(envelope) }
            let sink = IsolationTelemetrySink(mode: .rejectAll(.init(
                statusCode: statusCode, code: nil, envelopeID: nil, retryable: false
            )))
            let ingestor = TelemetryIngestor(
                archive: archive,
                sink: sink,
                installationID: envelopes[0].installationID,
                currentAppVersion: { "1.0" }
            )

            let status = try await ingestor.recoverPending()
            let submissionSizes = await sink.submissionSizes

            XCTAssertEqual(submissionSizes, [2])
            XCTAssertEqual(status.quarantineCount, 0)
            XCTAssertEqual(status.pendingCount, 2)
            if case .blocked = status.uploadState {} else { XCTFail("Expected request-wide block") }
        }
    }

    func testMultiEnvelope413ReducesBatchAndUploadsSingletons() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelopes = matchingEnvelopes(count: 3)
        for envelope in envelopes { try await archive.append(envelope) }
        let sink = IsolationTelemetrySink(mode: .rejectAboveSize(1))
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: envelopes[0].installationID,
            currentAppVersion: { "1.0" }
        )

        let status = try await ingestor.recoverPending()
        let submissionSizes = await sink.submissionSizes

        XCTAssertEqual(submissionSizes, [3, 1, 1, 1])
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertEqual(status.quarantineCount, 0)
    }

    func testSingleton413MustRepeatBeforeQuarantine() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelope = matchingEnvelopes(count: 1)[0]
        try await archive.append(envelope)
        let rejection = TelemetryServerRejection(
            statusCode: 413, code: nil, envelopeID: nil, retryable: false
        )
        let sink = IsolationTelemetrySink(mode: .rejectAll(rejection))
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: envelope.installationID,
            currentAppVersion: { "1.0" }
        )

        let status = try await ingestor.recoverPending()
        let submissionSizes = await sink.submissionSizes

        XCTAssertEqual(submissionSizes, [1, 1])
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertEqual(status.quarantineCount, 1)
        XCTAssertEqual(status.lastSafeErrorCategory, "oversized_envelope")
    }

    func testUnsupportedProtocolBlocksWithoutQuarantine() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelope = matchingEnvelopes(count: 1)[0]
        try await archive.append(envelope)
        let sink = IsolationTelemetrySink(mode: .rejectAll(.init(
            statusCode: 422, code: .unsupportedProtocol, envelopeID: nil, retryable: false
        )))
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: envelope.installationID,
            currentAppVersion: { "1.0" }
        )

        let status = try await ingestor.recoverPending()
        let submissionSizes = await sink.submissionSizes

        XCTAssertEqual(status.lastSafeErrorCategory, "unsupported_protocol")
        XCTAssertEqual(status.quarantineCount, 0)
        XCTAssertEqual(submissionSizes, [1])
    }

    func testAuthenticationBlocksAutomaticRetryAndManualForceAttemptsOnce() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelope = matchingEnvelopes(count: 1)[0]
        try await archive.append(envelope)
        let sink = IsolationTelemetrySink(mode: .authentication)
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: envelope.installationID,
            currentAppVersion: { "1.0" }
        )

        _ = try await ingestor.recoverPending()
        _ = await ingestor.retryPending()
        let automaticCount = await sink.submissionSizes.count
        let forcedStatus = await ingestor.retryPending(force: true)
        _ = await ingestor.retryPending()
        let finalCount = await sink.submissionSizes.count

        XCTAssertEqual(automaticCount, 1)
        XCTAssertEqual(finalCount, 2)
        XCTAssertEqual(forcedStatus.lastSafeErrorCategory, "authentication")
        XCTAssertEqual(forcedStatus.pendingCount, 1)
    }

    func testDeleteRestoresConfiguredAutomaticUploadsForNewTelemetry() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("RunSync", isDirectory: true)
        let gate = TelemetryUploadFenceGate()
        let control = TelemetryUploadControlStore(rootURL: storage, gate: gate)
        let archive = TelemetryArchive(
            rootURL: storage.appendingPathComponent("Runs", isDirectory: true),
            storageRootURL: storage,
            uploadFenceGate: gate
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let configuration = ServerConfigurationStore(defaults: defaults, tokenStore: TestTokenStore())
        try await configuration.save(baseURL: "https://telemetry.example", token: "token")
        let installationID = UUID()
        let manager = BackgroundTelemetryUploadManager(
            archive: archive,
            configuration: configuration,
            installationID: installationID,
            control: control,
            queue: BackgroundUploadQueue(
                rootURL: storage.appendingPathComponent("UploadQueue", isDirectory: true)
            ),
            activateSession: false
        )
        let sink = RecordingTelemetrySink()
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: installationID,
            backgroundUploader: manager
        )

        try await ingestor.deleteAllTelemetry()
        let result = try await ingestor.ingest(TelemetryTestSupport.sample(), from: UUID())
        let envelope = try XCTUnwrap(result.envelope)
        for _ in 0..<50 {
            if await sink.submittedIDs.contains(envelope.id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let submitted = await sink.submittedIDs
        let acknowledged = try await archive.acknowledgedIDs(runID: envelope.localRunID)
        XCTAssertEqual(submitted, [envelope.id])
        XCTAssertEqual(acknowledged, [envelope.id])
    }

    func testDeleteDoesNotClearExistingAuthenticationBlock() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let sink = IsolationTelemetrySink(mode: .authentication)
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: UUID()
        )
        _ = try await ingestor.ingest(TelemetryTestSupport.sample(), from: UUID())
        while await sink.submissionSizes.count < 1 { await Task.yield() }
        while true {
            if case .blocked = await ingestor.currentStatus().uploadState { break }
            await Task.yield()
        }

        try await ingestor.deleteAllTelemetry()
        _ = try await ingestor.ingest(
            TelemetryTestSupport.sample(sequence: 2, start: 456),
            from: UUID()
        )
        try await Task.sleep(for: .milliseconds(30))

        let submissionCount = await sink.submissionSizes.count
        XCTAssertEqual(submissionCount, 1)
        if case .blocked = await ingestor.currentStatus().uploadState {} else {
            XCTFail("Expected deletion to preserve the authentication block")
        }
    }

    func testConfigurationChangeDuringDeletionReplaysAndSupersedesOldAuthenticationBlock() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("RunSync", isDirectory: true)
        let gate = TelemetryUploadFenceGate()
        let control = TelemetryUploadControlStore(rootURL: storage, gate: gate)
        let archive = TelemetryArchive(
            rootURL: storage.appendingPathComponent("Runs", isDirectory: true),
            storageRootURL: storage,
            uploadFenceGate: gate
        )
        let queue = BackgroundUploadQueue(
            rootURL: storage.appendingPathComponent("UploadQueue", isDirectory: true)
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let configuration = ServerConfigurationStore(defaults: defaults, tokenStore: TestTokenStore())
        try await configuration.save(baseURL: "https://telemetry.example", token: "old-token")
        let envelope = TelemetryTestSupport.envelope()
        try await archive.append(envelope)
        let assignment = AsyncCheckpoint()
        let manager = BackgroundTelemetryUploadManager(
            archive: archive,
            configuration: configuration,
            installationID: envelope.installationID,
            control: control,
            queue: queue,
            activateSession: false,
            stagingEnabled: { true },
            assignmentCheckpoint: { await assignment.suspend() }
        )
        let sink = IsolationTelemetrySink(mode: .authentication)
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: envelope.installationID,
            backgroundUploader: manager
        )
        _ = try await ingestor.recoverPending()
        while true {
            if case .blocked = await ingestor.currentStatus().uploadState { break }
            await Task.yield()
        }

        let staging = Task { await manager.stageIfEnabled([envelope]) }
        await assignment.waitUntilSuspended()
        let deletion = Task { try await ingestor.deleteAllTelemetry() }
        while !(await ingestor.deletionIsInProgress()) { await Task.yield() }
        try await configuration.save(baseURL: "https://telemetry.example", token: "new-token")
        await sink.setMode(.acceptAll)
        _ = await ingestor.configurationChanged(configured: true)

        await assignment.resume()
        await staging.value
        try await deletion.value

        let result = try await ingestor.ingest(
            TelemetryTestSupport.sample(sequence: 2, start: 456),
            from: envelope.garminDeviceIdentifier
        )
        let newEnvelope = try XCTUnwrap(result.envelope)
        for _ in 0..<50 {
            if try await archive.acknowledgedIDs(runID: newEnvelope.localRunID).contains(newEnvelope.id) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let binding = try await manager.requestBinding()
        let acknowledgements = try await archive.acknowledgedIDs(runID: newEnvelope.localRunID)
        XCTAssertEqual(binding?.server.token, "new-token")
        XCTAssertEqual(acknowledgements, [newEnvelope.id])
        if case .blocked = await ingestor.currentStatus().uploadState {
            XCTFail("Expected changed credentials to supersede the old authentication block")
        }
    }

    func testBlockedManualTransientResultAutomaticallyRetries() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelope = TelemetryTestSupport.envelope()
        try await archive.append(envelope)
        let sink = BlockedTransientThenSuccessSink()
        let sleepGate = RetrySleepGate()
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: envelope.installationID,
            jitter: { 0 },
            sleep: { _ in await sleepGate.sleep() }
        )
        _ = try await ingestor.recoverPending()
        await sink.waitForSubmissionCount(1)

        _ = await ingestor.retryPending(force: true)
        await sink.waitForSubmissionCount(2)
        await sleepGate.waitUntilSleeping()
        await sleepGate.fire()
        await sink.waitForSubmissionCount(3)
        while (await ingestor.currentStatus()).pendingCount != 0 { await Task.yield() }

        let acknowledged = try await archive.acknowledgedIDs(runID: envelope.localRunID)
        let submissionCount = await sink.submissionCount
        XCTAssertEqual(submissionCount, 3)
        XCTAssertEqual(acknowledged, [envelope.id])
    }

    func testInstallationOwnershipConflictBlocksWithoutQuarantine() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelopes = matchingEnvelopes(count: 2)
        for envelope in envelopes { try await archive.append(envelope) }
        let sink = IsolationTelemetrySink(mode: .rejectAll(.init(
            statusCode: 403,
            code: .installationOwnershipConflict,
            envelopeID: nil,
            retryable: false
        )))
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: envelopes[0].installationID,
            currentAppVersion: { "1.0" }
        )

        let status = try await ingestor.recoverPending()
        let submissionSizes = await sink.submissionSizes

        XCTAssertEqual(submissionSizes, [2])
        XCTAssertEqual(status.pendingCount, 2)
        XCTAssertEqual(status.quarantineCount, 0)
        XCTAssertEqual(status.lastSafeErrorCategory, "installation_ownership_conflict")
    }

    func testIdentifiedInvalidEnvelopeIsConfirmedQuarantinedAndLaterEnvelopeUploads() async throws {
        try await assertIdentifiedEnvelopeIsolation(statusCode: 422, code: .invalidEnvelope)
    }

    func testIdentifiedOwnershipConflictIsConfirmedAndIsolatesOnlyThatEnvelope() async throws {
        try await assertIdentifiedEnvelopeIsolation(statusCode: 403, code: .envelopeOwnershipConflict)
    }

    func testIdentified409IsConfirmedBeforeQuarantine() async throws {
        try await assertIdentifiedEnvelopeIsolation(statusCode: 409, code: .envelopeConflict)
    }

    func testSystemicInvalidEnvelopeOnBothHalvesStopsWithoutQuarantine() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelopes = matchingEnvelopes(count: 4)
        for envelope in envelopes { try await archive.append(envelope) }
        let sink = IsolationTelemetrySink(mode: .rejectAll(.init(
            statusCode: 422, code: .invalidEnvelope, envelopeID: nil, retryable: false
        )))
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: envelopes[0].installationID,
            currentAppVersion: { "1.0" }
        )

        let status = try await ingestor.recoverPending()
        let submissionSizes = await sink.submissionSizes

        XCTAssertEqual(submissionSizes, [4, 2, 2])
        XCTAssertEqual(status.pendingCount, 4)
        XCTAssertEqual(status.quarantineCount, 0)
        XCTAssertEqual(status.lastSafeErrorCategory, "invalid_envelope_systemic")
    }

    func testUnattributedInvalidEnvelopeUsesDeterministicBisection() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelopes = matchingEnvelopes(count: 4)
        for envelope in envelopes { try await archive.append(envelope) }
        let rejected = envelopes[0]
        let sink = IsolationTelemetrySink(mode: .rejectEnvelope(
            rejected.id,
            .init(statusCode: 422, code: .invalidEnvelope, envelopeID: nil, retryable: false)
        ))
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: rejected.installationID,
            currentAppVersion: { "1.0" }
        )

        let status = try await ingestor.recoverPending()
        let submissionSizes = await sink.submissionSizes

        XCTAssertEqual(submissionSizes, [4, 2, 2, 1, 1, 1])
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertEqual(status.quarantineCount, 1)
        XCTAssertEqual(status.lastQuarantinedEnvelopeID, rejected.id)
    }

    func testExplicitQuarantineRetryAttemptsOnceAndCanRecover() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelope = matchingEnvelopes(count: 1)[0]
        try await archive.append(envelope)
        let sink = IsolationTelemetrySink(mode: .rejectEnvelope(
            envelope.id,
            .init(statusCode: 422, code: .invalidEnvelope, envelopeID: envelope.id, retryable: false)
        ))
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: envelope.installationID,
            currentAppVersion: { "1.0" }
        )
        _ = try await ingestor.recoverPending()
        await sink.setMode(.acceptAll)

        let status = await ingestor.retryQuarantined()
        let acknowledgements = try await archive.acknowledgedIDs(runID: envelope.localRunID)
        let sourceIDs = try await archive.envelopes(runID: envelope.localRunID).map(\.id)

        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertEqual(status.quarantineCount, 0)
        XCTAssertEqual(acknowledgements, [envelope.id])
        XCTAssertEqual(sourceIDs, [envelope.id])
    }

    func testAppVersionChangeReleasesQuarantineForOneRetry() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelope = matchingEnvelopes(count: 1)[0]
        try await archive.append(envelope)
        let sink = IsolationTelemetrySink(mode: .rejectEnvelope(
            envelope.id,
            .init(statusCode: 422, code: .invalidEnvelope, envelopeID: envelope.id, retryable: false)
        ))
        let oldIngestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: envelope.installationID,
            currentAppVersion: { "1.0" }
        )
        _ = try await oldIngestor.recoverPending()
        await sink.setMode(.acceptAll)
        let updatedIngestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: envelope.installationID,
            currentAppVersion: { "2.0" }
        )

        let status = try await updatedIngestor.recoverPending()
        let acknowledgements = try await archive.acknowledgedIDs(runID: envelope.localRunID)

        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertEqual(status.quarantineCount, 0)
        XCTAssertEqual(acknowledgements, [envelope.id])
    }

    private func assertIdentifiedEnvelopeIsolation(
        statusCode: Int,
        code: TelemetryServerErrorCode
    ) async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelopes = matchingEnvelopes(count: 2)
        let rejected = envelopes[0]
        let valid = envelopes[1]
        for envelope in envelopes { try await archive.append(envelope) }
        let sink = IsolationTelemetrySink(mode: .rejectEnvelope(
            rejected.id,
            .init(statusCode: statusCode, code: code, envelopeID: rejected.id, retryable: false)
        ))
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: rejected.installationID,
            currentAppVersion: { "1.0" }
        )

        let status = try await ingestor.recoverPending()
        let sourceIDs = try await archive.envelopes(runID: rejected.localRunID).map(\.id)
        let acknowledgements = try await archive.acknowledgedIDs(runID: rejected.localRunID)
        let submittedIDs = await sink.submittedIDs

        XCTAssertEqual(submittedIDs, [[rejected.id, valid.id], [rejected.id], [valid.id]])
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertEqual(status.quarantineCount, 1)
        XCTAssertEqual(status.lastQuarantinedEnvelopeID, rejected.id)
        XCTAssertEqual(sourceIDs, envelopes.map(\.id))
        XCTAssertEqual(acknowledgements, [valid.id])
    }

    private func matchingEnvelopes(count: Int) -> [TelemetryEnvelope] {
        let first = TelemetryTestSupport.envelope()
        return (0..<count).map { offset in
            TelemetryEnvelope(
                id: offset == 0 ? first.id : UUID(),
                installationID: first.installationID,
                localRunID: first.localRunID,
                phoneReceivedAt: first.phoneReceivedAt.addingTimeInterval(TimeInterval(offset)),
                garminDeviceIdentifier: first.garminDeviceIdentifier,
                appVersion: first.appVersion,
                sample: TelemetryTestSupport.sample(sequence: offset + 1)
            )
        }
    }

    private func backgroundMetadata(
        for envelopes: [TelemetryEnvelope],
        fence: TelemetryUploadFence
    ) -> BackgroundUploadMetadata {
        BackgroundUploadMetadata(
            batchID: UUID(),
            envelopeIDs: envelopes.map(\.id),
            activityIDs: envelopes.map(\.localRunID),
            configurationGeneration: fence.configurationGeneration,
            destinationFingerprint: fence.destinationFingerprint,
            deleteEpoch: fence.deleteEpoch,
            taskIdentifier: 1,
            createdAt: Date()
        )
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

private actor TransientTelemetrySink: TelemetrySink {
    func submit(_ envelopes: [TelemetryEnvelope]) throws -> [UUID] {
        throw TelemetrySinkError.transient(retryAfter: nil)
    }
}

private actor CountingTransientTelemetrySink: TelemetrySink {
    private(set) var submissionCount = 0

    func submit(_ envelopes: [TelemetryEnvelope]) throws -> [UUID] {
        submissionCount += 1
        throw TelemetrySinkError.transient(retryAfter: nil)
    }
}

private actor RetrySleepGate {
    private var sleeping = false
    private var sleepWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func sleep() async {
        sleeping = true
        let waiters = sleepWaiters
        sleepWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilSleeping() async {
        guard !sleeping else { return }
        await withCheckedContinuation { sleepWaiters.append($0) }
    }

    func fire() {
        continuation?.resume()
        continuation = nil
    }
}

private actor RetryCoordinatorTelemetrySink: TelemetrySink {
    private(set) var submittedIDs: [[UUID]] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var secondSubmissionContinuation: CheckedContinuation<Void, Never>?

    func submit(_ envelopes: [TelemetryEnvelope]) async throws -> [UUID] {
        let ids = envelopes.map(\.id)
        submittedIDs.append(ids)
        let count = submittedIDs.count
        let ready = countWaiters.filter { $0.0 <= count }
        countWaiters.removeAll { $0.0 <= count }
        ready.forEach { $0.1.resume() }
        if count == 1 { throw TelemetrySinkError.transient(retryAfter: nil) }
        if count == 2 {
            await withCheckedContinuation { secondSubmissionContinuation = $0 }
        }
        return ids
    }

    func waitForSubmissionCount(_ count: Int) async {
        guard submittedIDs.count < count else { return }
        await withCheckedContinuation { countWaiters.append((count, $0)) }
    }

    func resumeSecondSubmission() {
        secondSubmissionContinuation?.resume()
        secondSubmissionContinuation = nil
    }
}

private actor BlockedTransientThenSuccessSink: TelemetrySink {
    private(set) var submissionCount = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func submit(_ envelopes: [TelemetryEnvelope]) throws -> [UUID] {
        submissionCount += 1
        let ready = waiters.filter { $0.0 <= submissionCount }
        waiters.removeAll { $0.0 <= submissionCount }
        ready.forEach { $0.1.resume() }
        switch submissionCount {
        case 1:
            throw TelemetrySinkError.authentication
        case 2:
            throw TelemetrySinkError.transient(retryAfter: nil)
        default:
            return envelopes.map(\.id)
        }
    }

    func waitForSubmissionCount(_ count: Int) async {
        guard submissionCount < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

private actor SuspendedRejectionTelemetrySink: TelemetrySink {
    private let rejection: TelemetryServerRejection
    private(set) var submissionCount = 0
    private var submitted = false
    private var submissionWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    init(rejection: TelemetryServerRejection) { self.rejection = rejection }

    func submit(_ envelopes: [TelemetryEnvelope]) async throws -> [UUID] {
        submissionCount += 1
        submitted = true
        let waiters = submissionWaiters
        submissionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { resumeContinuation = $0 }
        throw TelemetrySinkError.rejected(rejection)
    }

    func waitUntilSubmitted() async {
        guard !submitted else { return }
        await withCheckedContinuation { submissionWaiters.append($0) }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private actor SuspendedTelemetrySink: TelemetrySink {
    private(set) var submissionCount = 0
    private var submitted = false
    private var submissionWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func submit(_ envelopes: [TelemetryEnvelope]) async -> [UUID] {
        submissionCount += 1
        submitted = true
        let waiters = submissionWaiters
        submissionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { resumeContinuation = $0 }
        return envelopes.map(\.id)
    }

    func waitUntilSubmitted() async {
        guard !submitted else { return }
        await withCheckedContinuation { submissionWaiters.append($0) }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private actor AsyncCheckpoint {
    private var suspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    var isSuspended: Bool { suspended }

    func suspend() async {
        suspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { resumeContinuation = $0 }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private actor UploadStatusRecorder {
    private(set) var statuses: [ServerUploadStatus] = []
    func append(_ status: ServerUploadStatus) { statuses.append(status) }
}

private actor IsolationTelemetrySink: TelemetrySink {
    enum Mode: Sendable {
        case acceptAll
        case rejectAboveSize(Int)
        case authentication
        case rejectAll(TelemetryServerRejection)
        case rejectEnvelope(UUID, TelemetryServerRejection)
    }

    private var mode: Mode
    private(set) var submittedIDs: [[UUID]] = []
    var submissionSizes: [Int] { submittedIDs.map(\.count) }

    init(mode: Mode) { self.mode = mode }

    func setMode(_ mode: Mode) { self.mode = mode }

    func submit(_ envelopes: [TelemetryEnvelope]) throws -> [UUID] {
        submittedIDs.append(envelopes.map(\.id))
        switch mode {
        case .acceptAll:
            return envelopes.map(\.id)
        case .rejectAboveSize(let maximum) where envelopes.count > maximum:
            throw TelemetrySinkError.rejected(.init(
                statusCode: 413, code: nil, envelopeID: nil, retryable: false
            ))
        case .rejectAboveSize:
            return envelopes.map(\.id)
        case .authentication:
            throw TelemetrySinkError.authentication
        case .rejectAll(let rejection):
            throw TelemetrySinkError.rejected(rejection)
        case .rejectEnvelope(let envelopeID, let rejection):
            if envelopes.contains(where: { $0.id == envelopeID }) {
                throw TelemetrySinkError.rejected(rejection)
            }
            return envelopes.map(\.id)
        }
    }
}

private final class TestConnectivityMonitor: TelemetryConnectivityMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var update: (@Sendable (ConnectivityStatus) -> Void)?

    func start(_ update: @escaping @Sendable (ConnectivityStatus) -> Void) {
        lock.withLock { self.update = update }
    }

    func cancel() {
        lock.withLock { update = nil }
    }

    func send(_ status: ConnectivityStatus) {
        let handler: (@Sendable (ConnectivityStatus) -> Void)? = lock.withLock { self.update }
        handler?(status)
    }
}
