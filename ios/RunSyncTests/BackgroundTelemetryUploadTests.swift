import XCTest
@testable import RunSync

final class BackgroundTelemetryUploadTests: XCTestCase {
    func testProtectedStagingPersistsWithoutSecretsInMetadata() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let envelope = TelemetryTestSupport.envelope()
        let fence = try await environment.synchronize(installationID: envelope.installationID)

        var prepared = try await environment.queue.prepare([envelope], fence: fence)
        var metadata = prepared.metadata
        metadata.taskIdentifier = 42
        try await environment.queue.commit(metadata)
        let restoredBatches = try await BackgroundUploadQueue(rootURL: environment.queueURL).batches()
        prepared = try XCTUnwrap(restoredBatches.first)

        XCTAssertEqual(prepared.metadata.envelopeIDs, [envelope.id])
        XCTAssertEqual(prepared.metadata.activityIDs, [envelope.localRunID])
        XCTAssertEqual(prepared.metadata.taskIdentifier, 42)
        XCTAssertEqual(prepared.metadata.fence, fence)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.bodyURL.path))

        let metadataURL = environment.queueURL
            .appendingPathComponent("\(metadata.batchID.uuidString).metadata.json")
        let metadataText = try String(contentsOf: metadataURL, encoding: .utf8)
        XCTAssertFalse(metadataText.contains(environment.server.token))
        XCTAssertFalse(metadataText.contains("latitude"))
        XCTAssertFalse(metadataText.contains("longitude"))
        XCTAssertFalse(metadataText.contains("sample"))
        XCTAssertFalse(metadataText.contains("Authorization"))

        let request = BackgroundTelemetryUploadManager.makeRequest(server: environment.server)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(environment.server.token)")
        XCTAssertNil(request.httpBody)
    }

    func testResponseIsAccumulatedAndAcknowledgedOnlyAfterCompletionThenStagingIsRemoved() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let envelope = TelemetryTestSupport.envelope()
        try await environment.archive.append(envelope)
        let fence = try await environment.synchronize(installationID: envelope.installationID)
        var prepared = try await environment.queue.prepare([envelope], fence: fence)
        var metadata = prepared.metadata
        metadata.taskIdentifier = 7
        try await environment.queue.commit(metadata)
        let stagedBatches = try await environment.queue.batches()
        prepared = try XCTUnwrap(stagedBatches.first)

        let responseBody = Data("""
            {"acknowledgedEnvelopeIds":["\(envelope.id.uuidString)"],"serverTime":"2026-07-19T12:00:00Z"}
            """.utf8)
        let response = HTTPURLResponse(
            url: environment.server.baseURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let accumulator = BackgroundTransferResponses()
        accumulator.received(response: response, taskID: 7)
        accumulator.received(data: responseBody.prefix(responseBody.count / 2), taskID: 7)
        let acknowledgementsBeforeCompletion = try await environment.archive.acknowledgedIDs(
            runID: envelope.localRunID
        )
        XCTAssertTrue(acknowledgementsBeforeCompletion.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.bodyURL.path))

        accumulator.received(data: responseBody.suffix(from: responseBody.count / 2), taskID: 7)
        let completed = accumulator.complete(taskID: 7)
        let finalizer = BackgroundUploadFinalizer(
            archive: environment.archive,
            control: environment.control,
            queue: environment.queue
        )
        let outcome = await finalizer.finalize(metadata: metadata, completed: completed, error: nil)

        let acknowledgements = try await environment.archive.acknowledgedIDs(runID: envelope.localRunID)
        XCTAssertEqual(acknowledgements, [envelope.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.bodyURL.path))
        let remainingBatches = try await environment.queue.batches()
        XCTAssertTrue(remainingBatches.isEmpty)
        XCTAssertEqual(outcome, .acknowledged([envelope.id]))
    }

    func testGenerationAndDestinationFencePersistAndChangeOnlyWithBinding() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let installationID = UUID()
        let first = try await environment.control.synchronize(
            configuration: environment.server,
            installationID: installationID
        )
        let sameDestination = ServerConfiguration(
            baseURL: URL(string: "https://TELEMETRY.example/api/")!,
            token: environment.server.token
        )
        let unchanged = try await environment.control.synchronize(
            configuration: sameDestination,
            installationID: installationID
        )
        XCTAssertFalse(unchanged.changed)
        XCTAssertEqual(unchanged.fence, first.fence)

        let tokenChanged = try await environment.control.synchronize(
            configuration: ServerConfiguration(baseURL: environment.server.baseURL, token: "replacement"),
            installationID: installationID
        )
        XCTAssertTrue(tokenChanged.changed)
        XCTAssertEqual(
            tokenChanged.fence?.configurationGeneration,
            (first.fence?.configurationGeneration ?? 0) + 1
        )
        XCTAssertEqual(tokenChanged.fence?.destinationFingerprint, first.fence?.destinationFingerprint)

        let installationChanged = try await environment.control.synchronize(
            configuration: ServerConfiguration(baseURL: environment.server.baseURL, token: "replacement"),
            installationID: UUID()
        )
        XCTAssertEqual(
            installationChanged.fence?.configurationGeneration,
            (tokenChanged.fence?.configurationGeneration ?? 0) + 1
        )

        let restoredGate = TelemetryUploadFenceGate()
        let restored = TelemetryUploadControlStore(rootURL: environment.storageURL, gate: restoredGate)
        let restoredSnapshot = await restored.snapshot()
        let currentSnapshot = await environment.control.snapshot()
        XCTAssertEqual(restoredSnapshot, currentSnapshot)
    }

    func testStaleGenerationAndOldDeleteEpochCannotAcknowledgeOrRecreateArchives() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let envelope = TelemetryTestSupport.envelope()
        try await environment.archive.append(envelope)
        let oldFence = try await environment.synchronize(installationID: envelope.installationID)
        var prepared = try await environment.queue.prepare([envelope], fence: oldFence)
        var metadata = prepared.metadata
        metadata.taskIdentifier = 9
        try await environment.queue.commit(metadata)
        let stagedBatches = try await environment.queue.batches()
        prepared = try XCTUnwrap(stagedBatches.first)

        _ = try await environment.control.beginDeletion()
        try await environment.archive.deleteAll()
        let finalizer = BackgroundUploadFinalizer(
            archive: environment.archive,
            control: environment.control,
            queue: environment.queue
        )
        _ = await finalizer.finalize(
            metadata: metadata,
            completed: successfulCompletion(envelopeID: envelope.id, url: environment.server.baseURL),
            error: nil
        )

        let archiveExists = await environment.archive.hasTelemetryFiles()
        XCTAssertFalse(archiveExists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.bodyURL.path))
    }

    func testDeletionInProgressPublishesNoFence() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let fence = try await environment.synchronize(installationID: UUID())
        let initialSnapshot = await environment.control.snapshot()
        XCTAssertEqual(initialSnapshot.fence, fence)

        _ = try await environment.control.beginDeletion()

        let snapshot = await environment.control.snapshot()
        XCTAssertTrue(snapshot.deletionInProgress)
        XCTAssertNil(snapshot.fence)
        let oldFenceIsCurrent = await environment.control.isCurrent(fence)
        XCTAssertFalse(oldFenceIsCurrent)
    }

    func testImmutableConfigurationBindingChangesGenerationWithToken() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let installationID = UUID()
        let first = try await environment.control.bind(
            configuration: environment.server,
            installationID: installationID
        ).binding
        let replacement = ServerConfiguration(
            baseURL: URL(string: "https://replacement.example/root")!,
            token: "replacement-token"
        )

        let second = try await environment.control.bind(
            configuration: replacement,
            installationID: installationID
        ).binding

        XCTAssertEqual(first?.server, environment.server)
        XCTAssertEqual(second?.server, replacement)
        XCTAssertNotEqual(first?.fence, second?.fence)
        if let oldFence = first?.fence {
            let oldFenceIsCurrent = await environment.control.isCurrent(oldFence)
            XCTAssertFalse(oldFenceIsCurrent)
        }
    }

    func testPartialCompletionAcknowledgesDurablyAndResetsStagingForRetry() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let firstEnvelope = TelemetryTestSupport.envelope()
        let secondEnvelope = TelemetryEnvelope(
            id: UUID(),
            installationID: firstEnvelope.installationID,
            localRunID: firstEnvelope.localRunID,
            phoneReceivedAt: firstEnvelope.phoneReceivedAt.addingTimeInterval(1),
            garminDeviceIdentifier: firstEnvelope.garminDeviceIdentifier,
            appVersion: firstEnvelope.appVersion,
            sample: firstEnvelope.sample
        )
        let envelopes = [firstEnvelope, secondEnvelope]
        let fence = try await environment.synchronize(installationID: envelopes[0].installationID)
        let finalizer = BackgroundUploadFinalizer(
            archive: environment.archive,
            control: environment.control,
            queue: environment.queue,
            now: { Date(timeIntervalSince1970: 100) }
        )
        let partial = try await environment.queue.prepare(envelopes, fence: fence)
        var assignedPartial = partial.metadata
        assignedPartial.taskIdentifier = 23
        try await environment.queue.commit(assignedPartial)
        let partialResponse = HTTPURLResponse(
            url: environment.server.baseURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let partialOutcome = await finalizer.finalize(
            metadata: assignedPartial,
            completed: .init(
                response: partialResponse,
                data: Data("{\"acknowledgedEnvelopeIds\":[\"\(envelopes[0].id.uuidString)\"],\"serverTime\":\"2026-07-19T12:00:00Z\"}".utf8),
                redirected: false
            ),
            error: nil
        )
        XCTAssertEqual(partialOutcome, .partial([envelopes[0].id]))
        let partialAcknowledgements = try await environment.archive.acknowledgedIDs(
            runID: envelopes[0].localRunID
        )
        let partialBatches = try await environment.queue.batches()
        let retainedPartial = try XCTUnwrap(partialBatches.first(where: {
            $0.metadata.batchID == partial.metadata.batchID
        }))
        XCTAssertEqual(partialAcknowledgements, [envelopes[0].id])
        XCTAssertEqual(retainedPartial.metadata.taskIdentifier, -1)
        XCTAssertEqual(retainedPartial.metadata.retryAttempt, 1)
        XCTAssertEqual(retainedPartial.metadata.retryNotBefore, Date(timeIntervalSince1970: 101))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedPartial.bodyURL.path))
    }

    func testTransientCompletionRetainsBodyAndResetsStagingForRetry() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let envelope = TelemetryTestSupport.envelope()
        let fence = try await environment.synchronize(installationID: envelope.installationID)
        let prepared = try await environment.queue.prepare([envelope], fence: fence)
        var assigned = prepared.metadata
        assigned.taskIdentifier = 24
        try await environment.queue.commit(assigned)
        let finalizer = BackgroundUploadFinalizer(
            archive: environment.archive,
            control: environment.control,
            queue: environment.queue,
            now: { Date(timeIntervalSince1970: 200) }
        )

        let outcome = await finalizer.finalize(
            metadata: assigned,
            completed: .init(response: nil, data: Data(), redirected: false),
            error: URLError(.timedOut)
        )

        let retainedBatches = try await environment.queue.batches()
        let retained = try XCTUnwrap(retainedBatches.first)
        XCTAssertEqual(outcome, .failed(.transient(retryAfter: nil)))
        XCTAssertEqual(retained.metadata.taskIdentifier, -1)
        XCTAssertEqual(retained.metadata.retryAttempt, 1)
        XCTAssertEqual(retained.metadata.retryNotBefore, Date(timeIntervalSince1970: 201))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.bodyURL.path))
    }

    func testMalformedSuccessAndArchiveAcknowledgementUncertaintyRetainStaging() async throws {
        let malformedEnvironment = try TestEnvironment()
        defer { malformedEnvironment.remove() }
        let malformedEnvelope = TelemetryTestSupport.envelope()
        let malformedFence = try await malformedEnvironment.synchronize(
            installationID: malformedEnvelope.installationID
        )
        let malformed = try await malformedEnvironment.queue.prepare(
            [malformedEnvelope],
            fence: malformedFence
        )
        let malformedFinalizer = BackgroundUploadFinalizer(
            archive: malformedEnvironment.archive,
            control: malformedEnvironment.control,
            queue: malformedEnvironment.queue
        )
        let response = HTTPURLResponse(
            url: malformedEnvironment.server.baseURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!

        let malformedOutcome = await malformedFinalizer.finalize(
            metadata: malformed.metadata,
            completed: .init(
                response: response,
                data: Data("{\"acknowledgedEnvelopeIds\":[]}".utf8),
                redirected: false
            ),
            error: nil
        )
        XCTAssertEqual(malformedOutcome, .failed(.transient(retryAfter: nil)))
        let malformedBatches = try await malformedEnvironment.queue.batches()
        XCTAssertEqual(malformedBatches.count, 1)

        let archiveEnvironment = try TestEnvironment()
        defer { archiveEnvironment.remove() }
        let archiveEnvelope = TelemetryTestSupport.envelope()
        let archiveFence = try await archiveEnvironment.synchronize(
            installationID: archiveEnvelope.installationID
        )
        let uncertain = try await archiveEnvironment.queue.prepare(
            [archiveEnvelope],
            fence: archiveFence
        )
        try Data("not-a-directory".utf8).write(to: archiveEnvironment.runsURL)
        let archiveFinalizer = BackgroundUploadFinalizer(
            archive: archiveEnvironment.archive,
            control: archiveEnvironment.control,
            queue: archiveEnvironment.queue
        )

        let uncertainOutcome = await archiveFinalizer.finalize(
            metadata: uncertain.metadata,
            completed: successfulCompletion(
                envelopeID: archiveEnvelope.id,
                url: archiveEnvironment.server.baseURL
            ),
            error: nil
        )
        let retainedBatches = try await archiveEnvironment.queue.batches()
        let retained = try XCTUnwrap(retainedBatches.first)
        XCTAssertEqual(uncertainOutcome, .failed(.transient(retryAfter: nil)))
        XCTAssertEqual(retained.metadata.taskIdentifier, -1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.bodyURL.path))
    }

    func testAuthenticationAndPermanentCompletionsUnstageBlockedBatches() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let envelope = TelemetryTestSupport.envelope()
        let fence = try await environment.synchronize(installationID: envelope.installationID)
        let finalizer = BackgroundUploadFinalizer(
            archive: environment.archive,
            control: environment.control,
            queue: environment.queue
        )

        let authentication = try await environment.queue.prepare([envelope], fence: fence)
        let authenticationOutcome = await finalizer.finalize(
            metadata: authentication.metadata,
            completed: .init(
                response: HTTPURLResponse(
                    url: environment.server.baseURL,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                ),
                data: Data(),
                redirected: false
            ),
            error: nil
        )
        XCTAssertEqual(authenticationOutcome, .failed(.authentication))

        let permanent = try await environment.queue.prepare([envelope], fence: fence)
        let permanentOutcome = await finalizer.finalize(
            metadata: permanent.metadata,
            completed: .init(
                response: nil,
                data: Data(),
                redirected: true
            ),
            error: nil
        )
        XCTAssertEqual(
            permanentOutcome,
            .failed(.permanent(reason: "Unexpected server redirect"))
        )
        let remainingBatches = try await environment.queue.batches()
        XCTAssertTrue(remainingBatches.isEmpty)
    }

    func testBackgroundRetryPolicyPersistsAttemptsAcrossRelaunchAndHonorsLongRetryAfter() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let envelope = TelemetryTestSupport.envelope()
        let fence = try await environment.synchronize(installationID: envelope.installationID)
        let prepared = try await environment.queue.prepare([envelope], fence: fence)
        var firstAssignment = prepared.metadata
        firstAssignment.taskIdentifier = 40
        try await environment.queue.commit(firstAssignment)

        let firstRetryResult = try await environment.queue.prepareRetry(
            batchID: prepared.metadata.batchID,
            expectedTaskIdentifier: 40,
            retryAfter: nil,
            now: Date(timeIntervalSince1970: 1_000)
        )
        let firstRetry = try XCTUnwrap(firstRetryResult)
        XCTAssertEqual(firstRetry.metadata.retryAttempt, 1)
        XCTAssertEqual(firstRetry.metadata.retryNotBefore, Date(timeIntervalSince1970: 1_001))

        var secondAssignment = firstRetry.metadata
        secondAssignment.taskIdentifier = 41
        try await environment.queue.commit(secondAssignment)
        let relaunchedQueue = BackgroundUploadQueue(rootURL: environment.queueURL)
        let secondRetryResult = try await relaunchedQueue.prepareRetry(
            batchID: prepared.metadata.batchID,
            expectedTaskIdentifier: 41,
            retryAfter: nil,
            now: Date(timeIntervalSince1970: 2_000)
        )
        let secondRetry = try XCTUnwrap(secondRetryResult)
        XCTAssertEqual(secondRetry.metadata.retryAttempt, 2)
        XCTAssertEqual(secondRetry.metadata.retryNotBefore, Date(timeIntervalSince1970: 2_002))

        var thirdAssignment = secondRetry.metadata
        thirdAssignment.taskIdentifier = 42
        try await relaunchedQueue.commit(thirdAssignment)
        let thirdRetryResult = try await relaunchedQueue.prepareRetry(
            batchID: prepared.metadata.batchID,
            expectedTaskIdentifier: 42,
            retryAfter: 3_600,
            now: Date(timeIntervalSince1970: 3_000)
        )
        let thirdRetry = try XCTUnwrap(thirdRetryResult)
        XCTAssertEqual(thirdRetry.metadata.retryAttempt, 3)
        XCTAssertEqual(thirdRetry.metadata.retryNotBefore, Date(timeIntervalSince1970: 6_600))
        XCTAssertEqual(BackgroundTelemetryUploadManager.backgroundRetryDelays, [1, 2, 4, 8, 16, 32, 60, 120, 300])
        XCTAssertEqual(
            BackgroundTelemetryUploadManager.backgroundRetryDelay(attempt: 20, retryAfter: nil),
            300
        )
        XCTAssertEqual(
            BackgroundTelemetryUploadManager.backgroundRetryDelay(attempt: 3, retryAfter: 2),
            4
        )
    }

    func testStaleFinalizerCannotResetNewerTaskAssignment() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let envelope = TelemetryTestSupport.envelope()
        let fence = try await environment.synchronize(installationID: envelope.installationID)
        let prepared = try await environment.queue.prepare([envelope], fence: fence)
        var completed = prepared.metadata
        completed.taskIdentifier = 50
        try await environment.queue.commit(completed)
        var newer = completed
        newer.taskIdentifier = 51
        try await environment.queue.commit(newer)
        let finalizer = BackgroundUploadFinalizer(
            archive: environment.archive,
            control: environment.control,
            queue: environment.queue
        )

        let outcome = await finalizer.finalize(
            metadata: completed,
            completed: .init(response: nil, data: Data(), redirected: false),
            error: URLError(.timedOut)
        )

        let batches = try await environment.queue.batches()
        let retained = try XCTUnwrap(batches.first)
        XCTAssertEqual(outcome, .stale)
        XCTAssertEqual(retained.metadata.taskIdentifier, 51)
        XCTAssertEqual(retained.metadata.retryAttempt, 0)
        XCTAssertNil(retained.metadata.retryNotBefore)
    }

    func testLegacyMetadataWithoutRetryFieldsDecodesWithDefaults() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        try FileManager.default.createDirectory(
            at: environment.queueURL,
            withIntermediateDirectories: true
        )
        let metadata = LegacyBackgroundUploadMetadata(
            batchID: UUID(),
            envelopeIDs: [UUID()],
            activityIDs: [UUID()],
            configurationGeneration: 2,
            destinationFingerprint: "legacy",
            deleteEpoch: 1,
            taskIdentifier: 12,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        try JSONEncoder().encode(metadata).write(
            to: environment.queueURL.appendingPathComponent("\(metadata.batchID.uuidString).metadata.json")
        )
        try Data("{}".utf8).write(
            to: environment.queueURL.appendingPathComponent("\(metadata.batchID.uuidString).json")
        )

        let batches = try await environment.queue.batches()
        let restored = try XCTUnwrap(batches.first)
        XCTAssertEqual(restored.metadata.retryAttempt, 0)
        XCTAssertNil(restored.metadata.retryNotBefore)
    }

    func testInterruptedDeleteResumesOnColdLaunchBeforeFilesCanBeScanned() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let envelope = TelemetryTestSupport.envelope()
        try await environment.archive.append(envelope)
        let fence = try await environment.synchronize(installationID: envelope.installationID)
        let prepared = try await environment.queue.prepare([envelope], fence: fence)
        var metadata = prepared.metadata
        metadata.taskIdentifier = 11
        try await environment.queue.commit(metadata)
        _ = try await environment.control.beginDeletion()

        let relaunchedGate = TelemetryUploadFenceGate()
        let relaunchedControl = TelemetryUploadControlStore(
            rootURL: environment.storageURL,
            gate: relaunchedGate
        )
        let relaunchedArchive = TelemetryArchive(
            rootURL: environment.runsURL,
            storageRootURL: environment.storageURL,
            uploadFenceGate: relaunchedGate
        )
        let relaunchedQueue = BackgroundUploadQueue(rootURL: environment.queueURL)
        try await TelemetryDeletionTransaction.resumeIfNeeded(
            control: relaunchedControl,
            queue: relaunchedQueue,
            archive: relaunchedArchive
        )

        let snapshot = await relaunchedControl.snapshot()
        XCTAssertFalse(snapshot.deletionInProgress)
        let archiveExists = await relaunchedArchive.hasTelemetryFiles()
        let queueExists = await relaunchedQueue.exists()
        XCTAssertFalse(archiveExists)
        XCTAssertFalse(queueExists)
    }

    func testRelaunchPlanKeepsOneHealthyTaskAndOnePreparedSuccessor() {
        let fence = TelemetryUploadFence(
            configurationGeneration: 3,
            destinationFingerprint: "destination",
            deleteEpoch: 2
        )
        let first = preparedBatch(taskID: 10, fence: fence, offset: 0)
        let second = preparedBatch(taskID: -1, fence: fence, offset: 1)
        let third = preparedBatch(taskID: 30, fence: fence, offset: 2)

        let plan = BackgroundLeasePlan.make(
            taskIDs: [20, 10],
            batches: [first, second, third],
            fence: fence
        )

        XCTAssertEqual(plan.active?.taskIdentifier, 10)
        XCTAssertEqual(plan.prepared?.metadata.taskIdentifier, -1)
        XCTAssertFalse(plan.taskIDsToCancel.contains(10))
        XCTAssertTrue(plan.taskIDsToCancel.contains(20))
        XCTAssertEqual(plan.batchIDsToRemove, [third.metadata.batchID])
    }

    func testCallbackOwnedCompletedBatchIsReservedFromReconstruction() {
        let fence = TelemetryUploadFence(
            configurationGeneration: 3,
            destinationFingerprint: "destination",
            deleteEpoch: 2
        )
        let completed = preparedBatch(taskID: 42, fence: fence, offset: 0)

        let plan = BackgroundLeasePlan.make(
            taskIDs: [],
            batches: [completed],
            fence: fence,
            callbackOwnedTaskIDs: [42]
        )

        XCTAssertNil(plan.active)
        XCTAssertNil(plan.prepared)
        XCTAssertFalse(plan.batchIDsToRemove.contains(completed.metadata.batchID))
    }

    func testStageCapturedBeforeDeleteCannotCrossEpochOrRecreateTelemetry() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let configuration = ServerConfigurationStore(defaults: defaults, tokenStore: TestTokenStore())
        try await configuration.save(
            baseURL: environment.server.baseURL.absoluteString,
            token: environment.server.token
        )
        let configurationSnapshot = try await configuration.snapshot()
        let envelope = TelemetryTestSupport.envelope()
        _ = try await environment.control.bind(
            snapshot: configurationSnapshot,
            installationID: envelope.installationID
        )
        try await environment.archive.append(envelope)
        let checkpoint = BackgroundCheckpoint()
        let manager = BackgroundTelemetryUploadManager(
            archive: environment.archive,
            configuration: configuration,
            installationID: envelope.installationID,
            control: environment.control,
            queue: environment.queue,
            activateSession: false,
            stagingEnabled: { true },
            stageCheckpoint: { await checkpoint.suspend() }
        )

        let staging = Task { await manager.stageIfEnabled([envelope]) }
        await checkpoint.waitUntilSuspended()
        let deletionFinished = CompletionCounter()
        let deletion = Task {
            try await manager.deleteAllTelemetry()
            deletionFinished.increment()
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(deletionFinished.value, 0)

        await checkpoint.resume()
        await staging.value
        try await deletion.value

        XCTAssertEqual(deletionFinished.value, 1)
        let archiveExists = await environment.archive.hasTelemetryFiles()
        let queueExists = await environment.queue.exists()
        XCTAssertFalse(archiveExists)
        XCTAssertFalse(queueExists)
    }

    func testStaleConfigurationReadCannotRegressNewerPersistedBinding() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let tokenStore = TestTokenStore()
        let configuration = ServerConfigurationStore(defaults: defaults, tokenStore: tokenStore)
        try await configuration.save(baseURL: "https://old.example", token: "old-token")
        let checkpoint = FirstBindingCheckpoint()
        let installationID = UUID()
        let manager = BackgroundTelemetryUploadManager(
            archive: environment.archive,
            configuration: configuration,
            installationID: installationID,
            control: environment.control,
            queue: environment.queue,
            activateSession: false,
            bindingCheckpoint: { revision in await checkpoint.pauseFirst(revision: revision) }
        )

        let staleRequest = Task { try await manager.requestBinding() }
        await checkpoint.waitUntilSuspended()
        try await configuration.save(baseURL: "https://new.example", token: "new-token")
        let newestBinding = try await manager.requestBinding()
        await checkpoint.resume()
        let retriedBinding = try await staleRequest.value

        XCTAssertEqual(newestBinding?.server.baseURL.host, "new.example")
        XCTAssertEqual(retriedBinding?.server, newestBinding?.server)
        XCTAssertEqual(retriedBinding?.fence, newestBinding?.fence)
        let currentFence = await environment.control.snapshot().fence
        XCTAssertEqual(currentFence, newestBinding?.fence)
    }

    func testSameRevisionBindingMismatchIsRecoveredWithoutSpinning() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let tokenStore = TestTokenStore()
        let configuration = ServerConfigurationStore(defaults: defaults, tokenStore: tokenStore)
        try await configuration.save(baseURL: "https://old.example", token: "old-token")
        let installationID = UUID()
        _ = try await environment.control.bind(
            snapshot: try await configuration.snapshot(),
            installationID: installationID
        )
        defaults.set("https://recovered.example", forKey: "RunSyncServerBaseURL")
        try tokenStore.save("recovered-token")
        let manager = BackgroundTelemetryUploadManager(
            archive: environment.archive,
            configuration: configuration,
            installationID: installationID,
            control: environment.control,
            queue: environment.queue,
            activateSession: false
        )

        let binding = try await manager.requestBinding()

        let recoveredSnapshot = try await configuration.snapshot()
        let controlSnapshot = await environment.control.snapshot()
        XCTAssertEqual(binding?.server.baseURL.host, "recovered.example")
        XCTAssertEqual(recoveredSnapshot.revision, 2)
        XCTAssertEqual(controlSnapshot.fence, binding?.fence)
    }

    func testBindingInvalidationDoesNotReleaseActiveStagingMutex() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let configuration = ServerConfigurationStore(defaults: defaults, tokenStore: TestTokenStore())
        try await configuration.save(
            baseURL: environment.server.baseURL.absoluteString,
            token: environment.server.token
        )
        let envelope = TelemetryTestSupport.envelope()
        try await environment.archive.append(envelope)
        let bindingChanged = BackgroundCheckpoint()
        let stageEntries = AsyncCounter()
        let manager = BackgroundTelemetryUploadManager(
            archive: environment.archive,
            configuration: configuration,
            installationID: envelope.installationID,
            control: environment.control,
            queue: environment.queue,
            activateSession: false,
            stagingEnabled: { true },
            stageCheckpoint: { await stageEntries.increment() },
            bindingDidChangeCheckpoint: { await bindingChanged.suspend() }
        )

        let first = Task { await manager.stageIfEnabled([envelope]) }
        await bindingChanged.waitUntilSuspended()
        let duplicate = Task { await manager.stageIfEnabled([envelope]) }
        try await Task.sleep(for: .milliseconds(20))
        let stageEntryCount = await stageEntries.value
        XCTAssertEqual(stageEntryCount, 1)

        let deletion = Task { try await manager.deleteAllTelemetry() }
        await bindingChanged.resume()
        await first.value
        await duplicate.value
        try await deletion.value
    }

    func testUnownedCleanupCannotDeleteBetweenAssignedCommitAndLeasePublication() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let configuration = ServerConfigurationStore(defaults: defaults, tokenStore: TestTokenStore())
        try await configuration.save(
            baseURL: environment.server.baseURL.absoluteString,
            token: environment.server.token
        )
        let envelope = TelemetryTestSupport.envelope()
        try await environment.archive.append(envelope)
        let assignment = BackgroundCheckpoint()
        let manager = BackgroundTelemetryUploadManager(
            archive: environment.archive,
            configuration: configuration,
            installationID: envelope.installationID,
            control: environment.control,
            queue: environment.queue,
            activateSession: false,
            stagingEnabled: { true },
            assignmentCheckpoint: { await assignment.suspend() }
        )

        let staging = Task { await manager.stageIfEnabled([envelope]) }
        await assignment.waitUntilSuspended()
        let cleanup = Task { await manager.removeUnownedSubmittedBatches() }
        try await Task.sleep(for: .milliseconds(20))
        let committed = try await environment.queue.batches()
        XCTAssertEqual(committed.count, 1)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(committed.first).metadata.taskIdentifier, 0)

        await assignment.resume()
        await staging.value
        await cleanup.value

        let retained = try await environment.queue.batches()
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(manager.leasedEnvelopeIDs(), [envelope.id])
        try await manager.deleteAllTelemetry()
    }

    func testFinalizingOwnershipPreventsForegroundSubmissionUntilReplacementLeaseIsPublished() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let configuration = ServerConfigurationStore(defaults: defaults, tokenStore: TestTokenStore())
        try await configuration.save(
            baseURL: environment.server.baseURL.absoluteString,
            token: environment.server.token
        )
        let envelope = TelemetryTestSupport.envelope()
        try await environment.archive.append(envelope)
        let binding = try await environment.control.bind(
            snapshot: try await configuration.snapshot(),
            installationID: envelope.installationID
        )
        let fence = try XCTUnwrap(binding.binding?.fence)
        let prepared = try await environment.queue.prepare([envelope], fence: fence)
        var completedMetadata = prepared.metadata
        completedMetadata.taskIdentifier = 77
        try await environment.queue.commit(completedMetadata)
        let finalization = BackgroundCheckpoint()
        let replacementAssignment = BackgroundCheckpoint()
        let manager = BackgroundTelemetryUploadManager(
            archive: environment.archive,
            configuration: configuration,
            installationID: envelope.installationID,
            control: environment.control,
            queue: environment.queue,
            activateSession: false,
            stagingEnabled: { true },
            assignmentCheckpoint: { await replacementAssignment.suspend() },
            finalizationCheckpoint: { await finalization.suspend() }
        )
        let sink = BackgroundRecordingTelemetrySink()
        let ingestor = TelemetryIngestor(
            archive: environment.archive,
            sink: sink,
            installationID: envelope.installationID,
            backgroundUploader: manager
        )

        let completion = Task {
            await manager.finalize(
                taskID: completedMetadata.taskIdentifier,
                completed: .init(response: nil, data: Data(), redirected: false),
                error: URLError(.timedOut)
            )
        }
        await finalization.waitUntilSuspended()
        XCTAssertEqual(manager.leasedEnvelopeIDs(), [envelope.id])

        _ = try await ingestor.recoverPending()
        let submissionsDuringFinalization = await sink.submissionCount
        XCTAssertEqual(submissionsDuringFinalization, 0)

        await finalization.resume()
        await replacementAssignment.waitUntilSuspended()
        XCTAssertEqual(manager.leasedEnvelopeIDs(), [envelope.id])
        _ = await ingestor.retryPending(force: true)
        let submissionsDuringReplacement = await sink.submissionCount
        XCTAssertEqual(submissionsDuringReplacement, 0)

        await replacementAssignment.resume()
        await completion.value

        let replacementBatches = try await environment.queue.batches()
        let replacement = try XCTUnwrap(replacementBatches.first)
        XCTAssertEqual(manager.leasedEnvelopeIDs(), [envelope.id])
        XCTAssertNotEqual(replacement.metadata.taskIdentifier, completedMetadata.taskIdentifier)
        XCTAssertGreaterThanOrEqual(replacement.metadata.taskIdentifier, 0)
        XCTAssertEqual(replacement.metadata.retryAttempt, 1)
        try await manager.deleteAllTelemetry()
    }

    func testReplacementAssignmentCommitFailureReleasesOwnershipForForegroundFallback() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let configuration = ServerConfigurationStore(defaults: defaults, tokenStore: TestTokenStore())
        try await configuration.save(
            baseURL: environment.server.baseURL.absoluteString,
            token: environment.server.token
        )
        let envelope = TelemetryTestSupport.envelope()
        try await environment.archive.append(envelope)
        let binding = try await environment.control.bind(
            snapshot: try await configuration.snapshot(),
            installationID: envelope.installationID
        )
        let fence = try XCTUnwrap(binding.binding?.fence)
        let commitFailure = AssignmentCommitFailure()
        let queue = BackgroundUploadQueue(
            rootURL: environment.queueURL,
            commitCheckpoint: { try commitFailure.check($0) }
        )
        let prepared = try await queue.prepare([envelope], fence: fence)
        var completedMetadata = prepared.metadata
        completedMetadata.taskIdentifier = 78
        try await queue.commit(completedMetadata)
        commitFailure.failNextReplacementAssignment()
        let manager = BackgroundTelemetryUploadManager(
            archive: environment.archive,
            configuration: configuration,
            installationID: envelope.installationID,
            control: environment.control,
            queue: queue,
            activateSession: false,
            stagingEnabled: { true }
        )
        let sink = BackgroundRecordingTelemetrySink()
        let ingestor = TelemetryIngestor(
            archive: environment.archive,
            sink: sink,
            installationID: envelope.installationID,
            backgroundUploader: manager
        )

        await manager.finalize(
            taskID: completedMetadata.taskIdentifier,
            completed: .init(response: nil, data: Data(), redirected: false),
            error: URLError(.timedOut)
        )

        XCTAssertTrue(manager.leasedEnvelopeIDs().isEmpty)
        let remainingBatches = try await queue.batches()
        XCTAssertTrue(remainingBatches.isEmpty)
        _ = try await ingestor.recoverPending()
        let submissionCount = await sink.submissionCount
        XCTAssertEqual(submissionCount, 1)
        let acknowledgements = try await environment.archive.acknowledgedIDs(
            runID: envelope.localRunID
        )
        XCTAssertEqual(acknowledgements, [envelope.id])
        try await manager.deleteAllTelemetry()
    }

    func testMissingReplacementBodyReleasesOwnershipForForegroundFallback() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let configuration = ServerConfigurationStore(defaults: defaults, tokenStore: TestTokenStore())
        try await configuration.save(
            baseURL: environment.server.baseURL.absoluteString,
            token: environment.server.token
        )
        let envelope = TelemetryTestSupport.envelope()
        try await environment.archive.append(envelope)
        let binding = try await environment.control.bind(
            snapshot: try await configuration.snapshot(),
            installationID: envelope.installationID
        )
        let fence = try XCTUnwrap(binding.binding?.fence)
        let prepared = try await environment.queue.prepare([envelope], fence: fence)
        var completedMetadata = prepared.metadata
        completedMetadata.taskIdentifier = 79
        try await environment.queue.commit(completedMetadata)
        let replacement = BackgroundCheckpoint()
        let manager = BackgroundTelemetryUploadManager(
            archive: environment.archive,
            configuration: configuration,
            installationID: envelope.installationID,
            control: environment.control,
            queue: environment.queue,
            activateSession: false,
            stagingEnabled: { true },
            replacementCheckpoint: { await replacement.suspend() }
        )
        let sink = BackgroundRecordingTelemetrySink()
        let ingestor = TelemetryIngestor(
            archive: environment.archive,
            sink: sink,
            installationID: envelope.installationID,
            backgroundUploader: manager
        )

        let completion = Task {
            await manager.finalize(
                taskID: completedMetadata.taskIdentifier,
                completed: .init(response: nil, data: Data(), redirected: false),
                error: URLError(.timedOut)
            )
        }
        await replacement.waitUntilSuspended()
        try FileManager.default.removeItem(at: prepared.bodyURL)
        await replacement.resume()
        await completion.value

        XCTAssertTrue(manager.leasedEnvelopeIDs().isEmpty)
        _ = try await ingestor.recoverPending()
        let submissionCount = await sink.submissionCount
        XCTAssertEqual(submissionCount, 1)
        let acknowledgements = try await environment.archive.acknowledgedIDs(
            runID: envelope.localRunID
        )
        XCTAssertEqual(acknowledgements, [envelope.id])
        try await manager.deleteAllTelemetry()
    }

    func testActiveRetryRetiresPreparedSuccessorBeforePublishingSolePreparedOwner() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let configuration = ServerConfigurationStore(defaults: defaults, tokenStore: TestTokenStore())
        try await configuration.save(
            baseURL: environment.server.baseURL.absoluteString,
            token: environment.server.token
        )
        let active = TelemetryTestSupport.envelope()
        let successor = TelemetryEnvelope(
            id: UUID(),
            installationID: active.installationID,
            localRunID: active.localRunID,
            phoneReceivedAt: active.phoneReceivedAt.addingTimeInterval(1),
            garminDeviceIdentifier: active.garminDeviceIdentifier,
            appVersion: active.appVersion,
            sample: TelemetryTestSupport.sample(sequence: 2)
        )
        try await environment.archive.append(active)
        try await environment.archive.append(successor)
        let binding = try await environment.control.bind(
            snapshot: try await configuration.snapshot(),
            installationID: active.installationID
        )
        let fence = try XCTUnwrap(binding.binding?.fence)
        let activeBatch = try await environment.queue.prepare([active], fence: fence)
        var completedMetadata = activeBatch.metadata
        completedMetadata.taskIdentifier = 80
        try await environment.queue.commit(completedMetadata)
        let successorBatch = try await environment.queue.prepare([successor], fence: fence)
        let assignment = BackgroundCheckpoint()
        let manager = BackgroundTelemetryUploadManager(
            archive: environment.archive,
            configuration: configuration,
            installationID: active.installationID,
            control: environment.control,
            queue: environment.queue,
            activateSession: false,
            stagingEnabled: { true },
            assignmentCheckpoint: { await assignment.suspend() }
        )
        manager.setPreparedLease(successorBatch.metadata)
        let sink = BackgroundRecordingTelemetrySink()
        let ingestor = TelemetryIngestor(
            archive: environment.archive,
            sink: sink,
            installationID: active.installationID,
            backgroundUploader: manager
        )

        let completion = Task {
            await manager.finalize(
                taskID: completedMetadata.taskIdentifier,
                completed: .init(response: nil, data: Data(), redirected: false),
                error: URLError(.timedOut)
            )
        }
        await assignment.waitUntilSuspended()

        let duringHandoff = try await environment.queue.batches()
        XCTAssertEqual(duringHandoff.map(\.metadata.batchID), [activeBatch.metadata.batchID])
        XCTAssertEqual(manager.leasedEnvelopeIDs(), [active.id])
        _ = try await ingestor.recoverPending()
        let foregroundIDs = await sink.submittedIDs
        XCTAssertEqual(foregroundIDs, [successor.id])
        let successorAcknowledgements = try await environment.archive.acknowledgedIDs(
            runID: successor.localRunID
        )
        XCTAssertTrue(successorAcknowledgements.contains(successor.id))

        await assignment.resume()
        await completion.value

        let finalBatches = try await environment.queue.batches()
        XCTAssertEqual(finalBatches.map(\.metadata.batchID), [activeBatch.metadata.batchID])
        XCTAssertEqual(manager.leasedEnvelopeIDs(), [active.id])
        try await manager.deleteAllTelemetry()
    }

    func testContendedActiveRetryIsDiscardedWhilePreparedSuccessorRemainsSoleOwner() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let configuration = ServerConfigurationStore(defaults: defaults, tokenStore: TestTokenStore())
        try await configuration.save(
            baseURL: environment.server.baseURL.absoluteString,
            token: environment.server.token
        )
        let active = TelemetryTestSupport.envelope()
        let successor = TelemetryEnvelope(
            id: UUID(),
            installationID: active.installationID,
            localRunID: active.localRunID,
            phoneReceivedAt: active.phoneReceivedAt.addingTimeInterval(1),
            garminDeviceIdentifier: active.garminDeviceIdentifier,
            appVersion: active.appVersion,
            sample: TelemetryTestSupport.sample(sequence: 2)
        )
        try await environment.archive.append(active)
        try await environment.archive.append(successor)
        let binding = try await environment.control.bind(
            snapshot: try await configuration.snapshot(),
            installationID: active.installationID
        )
        let fence = try XCTUnwrap(binding.binding?.fence)
        let successorBatch = try await environment.queue.prepare([successor], fence: fence)
        let activeBatch = try await environment.queue.prepare([active], fence: fence)
        var completedMetadata = activeBatch.metadata
        completedMetadata.taskIdentifier = 81
        try await environment.queue.commit(completedMetadata)
        let successorAssignment = BackgroundCheckpoint()
        let manager = BackgroundTelemetryUploadManager(
            archive: environment.archive,
            configuration: configuration,
            installationID: active.installationID,
            control: environment.control,
            queue: environment.queue,
            activateSession: false,
            stagingEnabled: { true },
            assignmentCheckpoint: { await successorAssignment.suspend() }
        )
        manager.setPreparedLease(successorBatch.metadata)
        let sink = BackgroundRecordingTelemetrySink()
        let ingestor = TelemetryIngestor(
            archive: environment.archive,
            sink: sink,
            installationID: active.installationID,
            backgroundUploader: manager
        )

        let assigningSuccessor = Task { await manager.resumePreparedIfEnabled() }
        await successorAssignment.waitUntilSuspended()
        await manager.finalize(
            taskID: completedMetadata.taskIdentifier,
            completed: .init(response: nil, data: Data(), redirected: false),
            error: URLError(.timedOut)
        )

        let duringContention = try await environment.queue.batches()
        XCTAssertEqual(duringContention.map(\.metadata.batchID), [successorBatch.metadata.batchID])
        XCTAssertEqual(manager.leasedEnvelopeIDs(), [successor.id])
        _ = try await ingestor.recoverPending()
        let foregroundIDs = await sink.submittedIDs
        XCTAssertEqual(foregroundIDs, [active.id])

        await successorAssignment.resume()
        await assigningSuccessor.value

        let finalBatches = try await environment.queue.batches()
        XCTAssertEqual(finalBatches.map(\.metadata.batchID), [successorBatch.metadata.batchID])
        XCTAssertEqual(manager.leasedEnvelopeIDs(), [successor.id])
        try await manager.deleteAllTelemetry()
    }

    func testOrphanAssignedBatchIsReclaimedAsPreparedWork() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let envelope = TelemetryTestSupport.envelope()
        let fence = try await environment.synchronize(installationID: envelope.installationID)
        let original = try await environment.queue.prepare([envelope], fence: fence)
        var assigned = original.metadata
        assigned.taskIdentifier = 91
        try await environment.queue.commit(assigned)
        let restoredBatches = try await environment.queue.batches()
        let restored = try XCTUnwrap(restoredBatches.first)

        let plan = BackgroundLeasePlan.make(
            taskIDs: [],
            batches: [restored],
            fence: fence,
            callbackOwnedTaskIDs: []
        )
        let reclaimed = try await environment.queue.resetForRetry(try XCTUnwrap(plan.prepared))

        XCTAssertEqual(plan.orphanAssigned.map(\.metadata.batchID), [assigned.batchID])
        XCTAssertEqual(reclaimed.metadata.taskIdentifier, -1)
        XCTAssertFalse(plan.batchIDsToRemove.contains(assigned.batchID))
    }

    func testOlderStartupFailureCannotClearNewerAttemptIdentity() {
        XCTAssertFalse(BackgroundTelemetryUploadManager.startupAttemptCanClear(
            currentGeneration: 8,
            completedGeneration: 7
        ))
        XCTAssertTrue(BackgroundTelemetryUploadManager.startupAttemptCanClear(
            currentGeneration: 8,
            completedGeneration: 8
        ))
    }

    func testProtectedControlLoadRetriesAndBackgroundEventsEventuallyComplete() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let configuration = ServerConfigurationStore(defaults: defaults, tokenStore: TestTokenStore())
        try await configuration.save(
            baseURL: environment.server.baseURL.absoluteString,
            token: environment.server.token
        )
        let configurationSnapshot = try await configuration.snapshot()
        let installationID = UUID()
        let persisted = try await environment.control.bind(
            snapshot: configurationSnapshot,
            installationID: installationID
        )
        let loader = FlakyStateLoader()
        let restoredGate = TelemetryUploadFenceGate()
        let restoredControl = TelemetryUploadControlStore(
            rootURL: environment.storageURL,
            gate: restoredGate,
            stateLoader: { try loader.load($0) }
        )
        let initiallyRestored = await restoredControl.snapshot()
        XCTAssertNil(initiallyRestored.fence)
        let restoredArchive = TelemetryArchive(
            rootURL: environment.runsURL,
            storageRootURL: environment.storageURL,
            uploadFenceGate: restoredGate
        )
        let manager = BackgroundTelemetryUploadManager(
            archive: restoredArchive,
            configuration: configuration,
            installationID: installationID,
            control: restoredControl,
            queue: environment.queue,
            activateSession: false,
            startupRetrySleep: { await Task.yield() }
        )
        let completed = expectation(description: "background events released after protected data retry")

        manager.handleEvents { completed.fulfill() }
        manager.urlSessionDidFinishEvents(forBackgroundURLSession: .shared)
        await fulfillment(of: [completed], timeout: 2)

        XCTAssertGreaterThanOrEqual(loader.loadCount, 2)
        let finalSnapshot = await restoredControl.snapshot()
        XCTAssertEqual(finalSnapshot.fence, persisted.binding?.fence)
    }

    func testDeleteReloadsControlBeforeAdvancingEpochAfterInitialLoadFailure() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let envelope = TelemetryTestSupport.envelope()
        try await environment.archive.append(envelope)
        _ = try await environment.control.synchronize(
            configuration: environment.server,
            installationID: envelope.installationID
        )
        let priorEpoch = try await environment.control.beginDeletion()
        try await environment.control.completeDeletion(epoch: priorEpoch)
        let priorFence = (await environment.control.snapshot()).fence
        let loader = FlakyStateLoader()
        let restoredGate = TelemetryUploadFenceGate()
        let restoredControl = TelemetryUploadControlStore(
            rootURL: environment.storageURL,
            gate: restoredGate,
            stateLoader: { try loader.load($0) }
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let manager = BackgroundTelemetryUploadManager(
            archive: environment.archive,
            configuration: ServerConfigurationStore(defaults: defaults, tokenStore: TestTokenStore()),
            installationID: envelope.installationID,
            control: restoredControl,
            queue: environment.queue,
            activateSession: false
        )
        let fallback = await restoredControl.snapshot()
        XCTAssertTrue(fallback.deletionInProgress)

        try await manager.deleteAllTelemetry()

        let final = try await restoredControl.persistedSnapshot()
        XCTAssertEqual(final.deleteEpoch, priorEpoch + 1)
        XCTAssertFalse(final.deletionInProgress)
        XCTAssertNotEqual(final.fence, priorFence)
        XCTAssertEqual(final.fence?.deleteEpoch, priorEpoch + 1)
        XCTAssertGreaterThanOrEqual(loader.loadCount, 2)
    }

    func testBackgroundRedirectIsRejected() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let configuration = ServerConfigurationStore(defaults: defaults, tokenStore: TestTokenStore())
        let manager = BackgroundTelemetryUploadManager(
            archive: environment.archive,
            configuration: configuration,
            installationID: UUID(),
            control: environment.control,
            queue: environment.queue,
            activateSession: false
        )
        let original = URLRequest(url: URL(string: "https://telemetry.example/v1/telemetry/batches")!)
        let task = URLSession.shared.dataTask(with: original)
        let response = HTTPURLResponse(
            url: original.url!, statusCode: 307, httpVersion: nil, headerFields: nil
        )!
        let rejected = expectation(description: "redirect rejected")
        manager.urlSession(
            .shared,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://other.example")!)
        ) { request in
            XCTAssertNil(request)
            rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 1)
    }

    func testBackgroundEventCompletionWaitsForAsyncFinalizationAndFiresOnce() async {
        let gate = BackgroundEventCompletionGate()
        let completed = expectation(description: "background completion")
        completed.expectedFulfillmentCount = 1
        gate.install { completed.fulfill() }
        gate.startupDidBecomeReady()
        gate.beginFinalization()
        gate.sessionFinishedEvents()

        gate.endFinalization()
        await fulfillment(of: [completed], timeout: 0.05, enforceOrder: false)
    }

    func testBackgroundEventCompletionAlsoWaitsForStartupReadiness() async {
        let gate = BackgroundEventCompletionGate()
        let completed = expectation(description: "background completion")
        let counter = CompletionCounter()
        gate.install {
            counter.increment()
            completed.fulfill()
        }
        gate.sessionFinishedEvents()

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(counter.value, 0)
        gate.startupDidBecomeReady()
        gate.sessionFinishedEvents()
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(counter.value, 1)
    }

    func testBackgroundStagingFlagDefaultsOff() {
        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: BackgroundTelemetryUploadManager.stagingFeatureFlagKey)
        defer {
            if let prior {
                defaults.set(prior, forKey: BackgroundTelemetryUploadManager.stagingFeatureFlagKey)
            } else {
                defaults.removeObject(forKey: BackgroundTelemetryUploadManager.stagingFeatureFlagKey)
            }
        }
        defaults.removeObject(forKey: BackgroundTelemetryUploadManager.stagingFeatureFlagKey)
        XCTAssertFalse(defaults.bool(forKey: BackgroundTelemetryUploadManager.stagingFeatureFlagKey))
    }

    private func successfulCompletion(
        envelopeID: UUID,
        url: URL
    ) -> BackgroundTransferResponses.Completed {
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return BackgroundTransferResponses.Completed(
            response: response,
            data: Data("""
                {"acknowledgedEnvelopeIds":["\(envelopeID.uuidString)"],"serverTime":"2026-07-19T12:00:00Z"}
                """.utf8),
            redirected: false
        )
    }

    private func preparedBatch(
        taskID: Int,
        fence: TelemetryUploadFence,
        offset: TimeInterval
    ) -> BackgroundUploadQueue.PreparedBatch {
        let batchID = UUID()
        return BackgroundUploadQueue.PreparedBatch(
            metadata: BackgroundUploadMetadata(
                batchID: batchID,
                envelopeIDs: [UUID()],
                activityIDs: [UUID()],
                configurationGeneration: fence.configurationGeneration,
                destinationFingerprint: fence.destinationFingerprint,
                deleteEpoch: fence.deleteEpoch,
                taskIdentifier: taskID,
                createdAt: Date(timeIntervalSince1970: offset)
            ),
            bodyURL: URL(fileURLWithPath: "/tmp/\(batchID.uuidString).json")
        )
    }
}

private final class CompletionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private struct LegacyBackgroundUploadMetadata: Encodable {
    let batchID: UUID
    let envelopeIDs: [UUID]
    let activityIDs: [UUID]
    let configurationGeneration: UInt64
    let destinationFingerprint: String
    let deleteEpoch: UInt64
    let taskIdentifier: Int
    let createdAt: Date
}

private actor BackgroundRecordingTelemetrySink: TelemetrySink {
    private(set) var submissionCount = 0
    private(set) var submittedIDs: [UUID] = []

    func submit(_ envelopes: [TelemetryEnvelope]) -> [UUID] {
        submissionCount += 1
        let identifiers = envelopes.map(\.id)
        submittedIDs.append(contentsOf: identifiers)
        return identifiers
    }
}

private final class AssignmentCommitFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = false

    func failNextReplacementAssignment() {
        lock.withLock { shouldFail = true }
    }

    func check(_ metadata: BackgroundUploadMetadata) throws {
        let fail = lock.withLock { () -> Bool in
            guard shouldFail, metadata.taskIdentifier >= 0, metadata.retryAttempt > 0 else {
                return false
            }
            shouldFail = false
            return true
        }
        if fail { throw CocoaError(.fileWriteUnknown) }
    }
}

private actor BackgroundCheckpoint {
    private var suspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

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

private actor FirstBindingCheckpoint {
    private var didPause = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func pauseFirst(revision: UInt64) async {
        guard !didPause else { return }
        didPause = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { resumeContinuation = $0 }
    }

    func waitUntilSuspended() async {
        guard didPause else {
            await withCheckedContinuation { suspensionWaiters.append($0) }
            return
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private actor AsyncCounter {
    private var count = 0
    var value: Int { count }
    func increment() { count += 1 }
}

private final class FlakyStateLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    var loadCount: Int { lock.withLock { attempts } }

    func load(_ url: URL) throws -> Data {
        let attempt = lock.withLock { () -> Int in
            attempts += 1
            return attempts
        }
        if attempt == 1 { throw CocoaError(.fileReadNoPermission) }
        return try Data(contentsOf: url)
    }
}

private final class TestEnvironment: @unchecked Sendable {
    let rootURL: URL
    let storageURL: URL
    let runsURL: URL
    let queueURL: URL
    let gate: TelemetryUploadFenceGate
    let control: TelemetryUploadControlStore
    let archive: TelemetryArchive
    let queue: BackgroundUploadQueue
    let server = ServerConfiguration(
        baseURL: URL(string: "https://telemetry.example/api")!,
        token: "super-secret-token"
    )

    init() throws {
        rootURL = try TelemetryTestSupport.temporaryDirectory()
        storageURL = rootURL.appendingPathComponent("RunSync", isDirectory: true)
        runsURL = storageURL.appendingPathComponent("Runs", isDirectory: true)
        queueURL = storageURL.appendingPathComponent("UploadQueue", isDirectory: true)
        gate = TelemetryUploadFenceGate()
        control = TelemetryUploadControlStore(rootURL: storageURL, gate: gate)
        archive = TelemetryArchive(
            rootURL: runsURL,
            storageRootURL: storageURL,
            uploadFenceGate: gate
        )
        queue = BackgroundUploadQueue(rootURL: queueURL)
    }

    func synchronize(installationID: UUID) async throws -> TelemetryUploadFence {
        let synchronization = try await control.synchronize(
            configuration: server,
            installationID: installationID
        )
        return try XCTUnwrap(synchronization.fence)
    }

    func remove() { try? FileManager.default.removeItem(at: rootURL) }
}
