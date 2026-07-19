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

    func testPartialAndAuthenticationCompletionsAreClassifiedAndUnstaged() async throws {
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
            queue: environment.queue
        )
        let partial = try await environment.queue.prepare(envelopes, fence: fence)
        let partialResponse = HTTPURLResponse(
            url: environment.server.baseURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let partialOutcome = await finalizer.finalize(
            metadata: partial.metadata,
            completed: .init(
                response: partialResponse,
                data: Data("{\"acknowledgedEnvelopeIds\":[\"\(envelopes[0].id.uuidString)\"],\"serverTime\":\"2026-07-19T12:00:00Z\"}".utf8),
                redirected: false
            ),
            error: nil
        )
        XCTAssertEqual(partialOutcome, .partial([envelopes[0].id]))

        let authentication = try await environment.queue.prepare([envelopes[0]], fence: fence)
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
        let remainingBatches = try await environment.queue.batches()
        XCTAssertTrue(remainingBatches.isEmpty)
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
