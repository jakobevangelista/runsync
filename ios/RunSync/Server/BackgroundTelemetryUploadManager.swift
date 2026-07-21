import Foundation

struct BackgroundUploadMetadata: Codable, Equatable, Sendable {
    let batchID: UUID
    let envelopeIDs: [UUID]
    let activityIDs: [UUID]
    let configurationGeneration: UInt64
    let destinationFingerprint: String
    let deleteEpoch: UInt64
    var taskIdentifier: Int
    var retryAttempt: Int
    var retryNotBefore: Date?
    let createdAt: Date

    init(
        batchID: UUID,
        envelopeIDs: [UUID],
        activityIDs: [UUID],
        configurationGeneration: UInt64,
        destinationFingerprint: String,
        deleteEpoch: UInt64,
        taskIdentifier: Int,
        retryAttempt: Int = 0,
        retryNotBefore: Date? = nil,
        createdAt: Date
    ) {
        self.batchID = batchID
        self.envelopeIDs = envelopeIDs
        self.activityIDs = activityIDs
        self.configurationGeneration = configurationGeneration
        self.destinationFingerprint = destinationFingerprint
        self.deleteEpoch = deleteEpoch
        self.taskIdentifier = taskIdentifier
        self.retryAttempt = retryAttempt
        self.retryNotBefore = retryNotBefore
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case batchID
        case envelopeIDs
        case activityIDs
        case configurationGeneration
        case destinationFingerprint
        case deleteEpoch
        case taskIdentifier
        case retryAttempt
        case retryNotBefore
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        batchID = try container.decode(UUID.self, forKey: .batchID)
        envelopeIDs = try container.decode([UUID].self, forKey: .envelopeIDs)
        activityIDs = try container.decode([UUID].self, forKey: .activityIDs)
        configurationGeneration = try container.decode(UInt64.self, forKey: .configurationGeneration)
        destinationFingerprint = try container.decode(String.self, forKey: .destinationFingerprint)
        deleteEpoch = try container.decode(UInt64.self, forKey: .deleteEpoch)
        taskIdentifier = try container.decode(Int.self, forKey: .taskIdentifier)
        retryAttempt = try container.decodeIfPresent(Int.self, forKey: .retryAttempt) ?? 0
        retryNotBefore = try container.decodeIfPresent(Date.self, forKey: .retryNotBefore)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    var fence: TelemetryUploadFence {
        TelemetryUploadFence(
            configurationGeneration: configurationGeneration,
            destinationFingerprint: destinationFingerprint,
            deleteEpoch: deleteEpoch
        )
    }
}

enum BackgroundUploadRetryPolicy {
    static let delays: [TimeInterval] = [1, 2, 4, 8, 16, 32, 60, 120, 300]

    static func delay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let exponential = delays[min(max(attempt, 1), delays.count) - 1]
        guard let retryAfter, retryAfter.isFinite, retryAfter >= 0 else { return exponential }
        return max(exponential, retryAfter)
    }
}

actor BackgroundUploadQueue {
    struct PreparedBatch: Sendable {
        let metadata: BackgroundUploadMetadata
        let bodyURL: URL
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let commitCheckpoint: @Sendable (BackgroundUploadMetadata) throws -> Void

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        commitCheckpoint: @escaping @Sendable (BackgroundUploadMetadata) throws -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        self.commitCheckpoint = commitCheckpoint
        self.rootURL = rootURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RunSync", isDirectory: true)
            .appendingPathComponent("UploadQueue", isDirectory: true)
    }

    func prepare(_ envelopes: [TelemetryEnvelope], fence: TelemetryUploadFence) throws -> PreparedBatch {
        let batchID = UUID()
        try createDirectory()
        let bodyURL = self.bodyURL(batchID: batchID)
        try TelemetryBatchCodec.encode(envelopes).write(
            to: bodyURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        let metadata = BackgroundUploadMetadata(
            batchID: batchID,
            envelopeIDs: envelopes.map(\.id),
            activityIDs: envelopes.map(\.localRunID),
            configurationGeneration: fence.configurationGeneration,
            destinationFingerprint: fence.destinationFingerprint,
            deleteEpoch: fence.deleteEpoch,
            taskIdentifier: -1,
            retryAttempt: 0,
            retryNotBefore: nil,
            createdAt: Date()
        )
        do {
            try commit(metadata)
        } catch {
            try? fileManager.removeItem(at: bodyURL)
            throw error
        }
        return PreparedBatch(metadata: metadata, bodyURL: bodyURL)
    }

    func commit(_ metadata: BackgroundUploadMetadata) throws {
        try commitCheckpoint(metadata)
        try createDirectory()
        let data = try JSONEncoder().encode(metadata)
        try data.write(
            to: metadataURL(batchID: metadata.batchID),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    func batches() throws -> [PreparedBatch] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let contents = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let batches = try contents.filter { $0.lastPathComponent.hasSuffix(".metadata.json") }.map { url in
            let metadata = try JSONDecoder().decode(BackgroundUploadMetadata.self, from: Data(contentsOf: url))
            return PreparedBatch(metadata: metadata, bodyURL: bodyURL(batchID: metadata.batchID))
        }
        .sorted { $0.metadata.createdAt < $1.metadata.createdAt }
        let expectedBodies = Set(batches.map(\.bodyURL))
        for url in contents where url.pathExtension == "json"
            && !url.lastPathComponent.hasSuffix(".metadata.json")
            && !expectedBodies.contains(url) {
            try fileManager.removeItem(at: url)
        }
        return batches
    }

    func remove(batchID: UUID) throws {
        for url in [bodyURL(batchID: batchID), metadataURL(batchID: batchID)]
            where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        if fileManager.fileExists(atPath: rootURL.path),
           (try fileManager.contentsOfDirectory(atPath: rootURL.path)).isEmpty {
            try fileManager.removeItem(at: rootURL)
        }
    }

    func remove(batchID: UUID, expectedTaskIdentifier: Int) throws -> Bool {
        guard let prepared = try batches().first(where: { $0.metadata.batchID == batchID }),
              prepared.metadata.taskIdentifier == expectedTaskIdentifier else {
            return false
        }
        try remove(batchID: batchID)
        return true
    }

    func removeAll() throws {
        if fileManager.fileExists(atPath: rootURL.path) { try fileManager.removeItem(at: rootURL) }
    }

    func resetForRetry(_ prepared: PreparedBatch) throws -> PreparedBatch {
        var metadata = prepared.metadata
        metadata.taskIdentifier = -1
        try commit(metadata)
        return PreparedBatch(metadata: metadata, bodyURL: prepared.bodyURL)
    }

    func prepareRetry(
        batchID: UUID,
        expectedTaskIdentifier: Int,
        retryAfter: TimeInterval?,
        now: Date
    ) throws -> PreparedBatch? {
        guard let prepared = try batches().first(where: { $0.metadata.batchID == batchID }),
              fileManager.fileExists(atPath: prepared.bodyURL.path),
              prepared.metadata.taskIdentifier == expectedTaskIdentifier else {
            return nil
        }
        var metadata = prepared.metadata
        metadata.taskIdentifier = -1
        metadata.retryAttempt = min(metadata.retryAttempt + 1, BackgroundUploadRetryPolicy.delays.count)
        metadata.retryNotBefore = now.addingTimeInterval(BackgroundUploadRetryPolicy.delay(
            attempt: metadata.retryAttempt,
            retryAfter: retryAfter
        ))
        try commit(metadata)
        return PreparedBatch(metadata: metadata, bodyURL: prepared.bodyURL)
    }

    func durablePreparedBatch(batchID: UUID, fence: TelemetryUploadFence) throws -> PreparedBatch? {
        guard let prepared = try batches().first(where: {
            $0.metadata.batchID == batchID
                && $0.metadata.taskIdentifier < 0
                && $0.metadata.fence == fence
        }), fileManager.fileExists(atPath: prepared.bodyURL.path) else {
            return nil
        }
        return prepared
    }

    func removePrepared(batchID: UUID, fence: TelemetryUploadFence) throws -> Bool {
        guard let prepared = try batches().first(where: {
            $0.metadata.batchID == batchID
                && $0.metadata.taskIdentifier < 0
                && $0.metadata.fence == fence
        }) else {
            return false
        }
        try remove(batchID: prepared.metadata.batchID)
        return true
    }

    func exists() -> Bool { fileManager.fileExists(atPath: rootURL.path) }

    private func createDirectory() throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
    }

    private func bodyURL(batchID: UUID) -> URL {
        rootURL.appendingPathComponent("\(batchID.uuidString).json")
    }

    private func metadataURL(batchID: UUID) -> URL {
        rootURL.appendingPathComponent("\(batchID.uuidString).metadata.json")
    }
}

final class BackgroundEventCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?
    private var finishedEvents = false
    private var finalizationCount = 0
    private var startupReady = false

    func install(_ handler: @escaping () -> Void) {
        let completion = lock.withLock { () -> (() -> Void)? in
            if let existing = self.handler {
                self.handler = {
                    existing()
                    handler()
                }
            } else {
                self.handler = handler
            }
            return takeCompletionIfReady()
        }
        completion?()
    }

    func beginFinalization() {
        lock.withLock { finalizationCount += 1 }
    }

    func endFinalization() {
        let completion = lock.withLock { () -> (() -> Void)? in
            finalizationCount = max(0, finalizationCount - 1)
            return takeCompletionIfReady()
        }
        completion?()
    }

    func sessionFinishedEvents() {
        let completion = lock.withLock { () -> (() -> Void)? in
            finishedEvents = true
            return takeCompletionIfReady()
        }
        completion?()
    }

    func startupDidBecomeReady() {
        let completion = lock.withLock { () -> (() -> Void)? in
            startupReady = true
            return takeCompletionIfReady()
        }
        completion?()
    }

    private func takeCompletionIfReady() -> (() -> Void)? {
        guard startupReady, finishedEvents, finalizationCount == 0, let handler else { return nil }
        self.handler = nil
        finishedEvents = false
        return handler
    }
}

private actor BackgroundStartupGate {
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReady() async {
        guard !ready else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func markReady() {
        ready = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }


    func isReady() -> Bool { ready }
}

private actor BackgroundAssignmentGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

private final class BackgroundManagerOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var deletionInProgress = false
    private var activeOperations = 0
    private var deletionWaiters: [CheckedContinuation<Void, Never>] = []

    func begin() -> UInt64? {
        lock.withLock {
            guard !deletionInProgress else { return nil }
            activeOperations += 1
            return generation
        }
    }

    func isCurrent(_ token: UInt64) -> Bool {
        lock.withLock { !deletionInProgress && token == generation }
    }

    func end() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            activeOperations = max(0, activeOperations - 1)
            guard activeOperations == 0, deletionInProgress else { return [] }
            let pending = deletionWaiters
            deletionWaiters.removeAll()
            return pending
        }
        waiters.forEach { $0.resume() }
    }

    func beginDeletion() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if !deletionInProgress {
                    deletionInProgress = true
                    generation &+= 1
                }
                guard activeOperations > 0 else { return true }
                deletionWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func endDeletion() {
        lock.withLock { deletionInProgress = false }
    }
}

final class BackgroundTransferResponses: @unchecked Sendable {
    struct Completed {
        let response: HTTPURLResponse?
        let data: Data
        let redirected: Bool
    }

    private struct Value {
        var response: HTTPURLResponse?
        var data = Data()
        var redirected = false
    }

    private let lock = NSLock()
    private var values: [Int: Value] = [:]

    func received(response: HTTPURLResponse?, taskID: Int) {
        lock.withLock { values[taskID, default: Value()].response = response }
    }

    func received(data: Data, taskID: Int) {
        lock.withLock { values[taskID, default: Value()].data.append(data) }
    }

    func rejectedRedirect(taskID: Int) {
        lock.withLock { values[taskID, default: Value()].redirected = true }
    }

    func complete(taskID: Int) -> Completed {
        lock.withLock {
            let value = values.removeValue(forKey: taskID) ?? Value()
            return Completed(response: value.response, data: value.data, redirected: value.redirected)
        }
    }
}

struct BackgroundLeasePlan {
    let active: BackgroundUploadMetadata?
    let prepared: BackgroundUploadQueue.PreparedBatch?
    let orphanAssigned: [BackgroundUploadQueue.PreparedBatch]
    let taskIDsToCancel: Set<Int>
    let batchIDsToRemove: Set<UUID>

    static func make(
        taskIDs: [Int],
        batches: [BackgroundUploadQueue.PreparedBatch],
        fence: TelemetryUploadFence?,
        callbackOwnedTaskIDs: Set<Int> = [],
        preserveAssignedBatches: Bool = false
    ) -> BackgroundLeasePlan {
        let sortedTaskIDs = taskIDs.sorted()
        let active = sortedTaskIDs.lazy.compactMap { taskID in
            batches.first {
                !callbackOwnedTaskIDs.contains(taskID)
                    && $0.metadata.taskIdentifier == taskID && $0.metadata.fence == fence
            }?.metadata
        }.first
        let activeTaskID = active?.taskIdentifier
        let taskIDsToCancel = Set(sortedTaskIDs.filter {
            $0 != activeTaskID && !callbackOwnedTaskIDs.contains($0)
        })
        let orphanAssigned = batches.filter {
            $0.metadata.taskIdentifier >= 0
                && !sortedTaskIDs.contains($0.metadata.taskIdentifier)
                && !callbackOwnedTaskIDs.contains($0.metadata.taskIdentifier)
        }
        let candidates = batches.filter {
            $0.metadata.batchID != active?.batchID
                && $0.metadata.taskIdentifier < 0
                && !callbackOwnedTaskIDs.contains($0.metadata.taskIdentifier)
                && $0.metadata.fence == fence
        } + orphanAssigned.filter { $0.metadata.fence == fence }
        let prepared = candidates.first
        let callbackOwnedBatchIDs = batches.filter {
            callbackOwnedTaskIDs.contains($0.metadata.taskIdentifier)
        }.map(\.metadata.batchID)
        let assignedBatchIDs = preserveAssignedBatches ? batches.filter {
            $0.metadata.taskIdentifier >= 0
                && !orphanAssigned.map(\.metadata.batchID).contains($0.metadata.batchID)
        }.map(\.metadata.batchID) : []
        let retained = Set(
            [active?.batchID, prepared?.metadata.batchID].compactMap { $0 }
                + callbackOwnedBatchIDs
                + assignedBatchIDs
        )
        let batchIDsToRemove = Set(batches.map(\.metadata.batchID)).subtracting(retained)
        return BackgroundLeasePlan(
            active: active,
            prepared: prepared,
            orphanAssigned: orphanAssigned,
            taskIDsToCancel: taskIDsToCancel,
            batchIDsToRemove: batchIDsToRemove
        )
    }
}

enum BackgroundUploadOutcome: Equatable, Sendable {
    case stale
    case acknowledged([UUID])
    case partial([UUID])
    case failed(TelemetrySinkError)
}

actor BackgroundUploadFinalizer {
    private let archive: TelemetryArchive
    private let control: TelemetryUploadControlStore
    private let queue: BackgroundUploadQueue
    private let now: @Sendable () -> Date

    init(
        archive: TelemetryArchive,
        control: TelemetryUploadControlStore,
        queue: BackgroundUploadQueue,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.archive = archive
        self.control = control
        self.queue = queue
        self.now = now
    }

    func finalize(
        metadata: BackgroundUploadMetadata,
        completed: BackgroundTransferResponses.Completed,
        error: Error?
    ) async -> BackgroundUploadOutcome {
        guard await control.isCurrent(metadata.fence) else {
            try? await queue.remove(batchID: metadata.batchID)
            return .stale
        }

        let result: Result<[UUID], TelemetrySinkError>
        if error != nil {
            result = .failure(.transient(retryAfter: nil))
        } else if completed.redirected {
            result = .failure(.permanent(reason: "Unexpected server redirect"))
        } else if let response = completed.response {
            if (200...299).contains(response.statusCode) {
                if response.value(forHTTPHeaderField: "Content-Type")?
                    .lowercased().contains("application/json") == true {
                    do {
                        result = .success(try TelemetryBatchCodec.decodeAcknowledgements(
                            completed.data,
                            requested: Set(metadata.envelopeIDs)
                        ))
                    } catch let sinkError as TelemetrySinkError {
                        result = .failure(sinkError)
                    } catch {
                        result = .failure(.transient(retryAfter: nil))
                    }
                } else {
                    result = .failure(.transient(retryAfter: nil))
                }
            } else {
                result = .failure(HTTPTelemetrySink.classify(response, data: completed.data))
            }
        } else {
            result = .failure(.transient(retryAfter: nil))
        }

        switch result {
        case .success(let acknowledged):
            do {
                let acknowledgedSet = Set(acknowledged)
                let pairs = zip(metadata.envelopeIDs, metadata.activityIDs).filter {
                    acknowledgedSet.contains($0.0)
                }
                let grouped = Dictionary(grouping: pairs, by: { $0.1 })
                for (runID, entries) in grouped {
                    let didAppend = try await archive.appendAcknowledgements(
                        entries.map(\.0),
                        runID: runID,
                        fence: metadata.fence
                    )
                    guard didAppend else {
                        try? await queue.remove(batchID: metadata.batchID)
                        return .stale
                    }
                }
            } catch {
                let outcome = BackgroundUploadOutcome.failed(.transient(retryAfter: nil))
                return await prepareRetry(metadata: metadata, outcome: outcome) ? outcome : .stale
            }
            if acknowledged.count == metadata.envelopeIDs.count {
                guard (try? await queue.remove(
                    batchID: metadata.batchID,
                    expectedTaskIdentifier: metadata.taskIdentifier
                )) == true else { return .stale }
                return .acknowledged(acknowledged)
            }
            let outcome = BackgroundUploadOutcome.partial(acknowledged)
            return await prepareRetry(metadata: metadata, outcome: outcome) ? outcome : .stale
        case .failure(let error):
            if Self.shouldRetainForRetry(error) {
                let outcome = BackgroundUploadOutcome.failed(error)
                return await prepareRetry(metadata: metadata, outcome: outcome) ? outcome : .stale
            } else {
                guard (try? await queue.remove(
                    batchID: metadata.batchID,
                    expectedTaskIdentifier: metadata.taskIdentifier
                )) == true else { return .stale }
            }
            return .failed(error)
        }
    }

    private func prepareRetry(
        metadata: BackgroundUploadMetadata,
        outcome: BackgroundUploadOutcome
    ) async -> Bool {
        let retryAfter: TimeInterval?
        if case .failed(.transient(let serverDelay)) = outcome {
            retryAfter = serverDelay
        } else {
            retryAfter = nil
        }
        do {
            return try await queue.prepareRetry(
                batchID: metadata.batchID,
                expectedTaskIdentifier: metadata.taskIdentifier,
                retryAfter: retryAfter,
                now: now()
            ) != nil
        } catch {
            return false
        }
    }

    private nonisolated static func shouldRetainForRetry(_ error: TelemetrySinkError) -> Bool {
        switch error {
        case .transient:
            true
        case .rejected(let rejection):
            rejection.retryable == true
        case .notConfigured, .authentication, .permanent, .rejected:
            false
        }
    }
}

final class BackgroundTelemetryUploadManager: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private enum ReplacementOwnership {
        case activeTask
        case prepared
        case none
    }

    static let sessionIdentifier = "com.jakobevangelista.runsync.telemetry-background"
    static let stagingFeatureFlagKey = "RunSyncBackgroundStagingEnabled"
    static let backgroundRetryDelays = BackgroundUploadRetryPolicy.delays

    private let archive: TelemetryArchive
    private let configuration: ServerConfigurationStore
    private let installationID: UUID
    private let control: TelemetryUploadControlStore
    private let queue: BackgroundUploadQueue
    private let stagingEnabled: @Sendable () -> Bool
    private let finalizer: BackgroundUploadFinalizer
    private let responses = BackgroundTransferResponses()
    private let completionGate = BackgroundEventCompletionGate()
    private let startupGate = BackgroundStartupGate()
    private let assignmentGate = BackgroundAssignmentGate()
    private let operationGate = BackgroundManagerOperationGate()
    private let lock = NSLock()
    private var leasedByTask: [Int: BackgroundUploadMetadata] = [:]
    private var finalizingByTask: [Int: BackgroundUploadMetadata] = [:]
    private var preparedLease: BackgroundUploadMetadata?
    private var submissionInProgress = false
    private var callbackOwnedTaskIDs: Set<Int> = []
    private var startupAttempt: (generation: UInt64, task: Task<Void, Error>)?
    private var nextStartupAttemptGeneration: UInt64 = 0
    private var startupReady = false
    private var startupRetryInProgress = false
    private var completionHandler: (@Sendable (BackgroundUploadMetadata, BackgroundUploadOutcome) async -> Void)?
    private let stageCheckpoint: @Sendable () async -> Void
    private let assignmentCheckpoint: @Sendable () async -> Void
    private let finalizationCheckpoint: @Sendable () async -> Void
    private let replacementCheckpoint: @Sendable () async -> Void
    private let bindingCheckpoint: @Sendable (UInt64) async -> Void
    private let bindingDidChangeCheckpoint: @Sendable () async -> Void
    private let startupRetrySleep: @Sendable () async -> Void
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(
        archive: TelemetryArchive,
        configuration: ServerConfigurationStore,
        installationID: UUID,
        control: TelemetryUploadControlStore,
        queue: BackgroundUploadQueue = BackgroundUploadQueue(),
        activateSession: Bool = true,
        stagingEnabled: @escaping @Sendable () -> Bool = {
            UserDefaults.standard.bool(forKey: BackgroundTelemetryUploadManager.stagingFeatureFlagKey)
        },
        stageCheckpoint: @escaping @Sendable () async -> Void = {},
        assignmentCheckpoint: @escaping @Sendable () async -> Void = {},
        finalizationCheckpoint: @escaping @Sendable () async -> Void = {},
        replacementCheckpoint: @escaping @Sendable () async -> Void = {},
        bindingCheckpoint: @escaping @Sendable (UInt64) async -> Void = { _ in },
        bindingDidChangeCheckpoint: @escaping @Sendable () async -> Void = {},
        startupRetrySleep: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .seconds(1))
        }
    ) {
        self.archive = archive
        self.configuration = configuration
        self.installationID = installationID
        self.control = control
        self.queue = queue
        self.finalizer = BackgroundUploadFinalizer(archive: archive, control: control, queue: queue)
        self.stagingEnabled = stagingEnabled
        self.stageCheckpoint = stageCheckpoint
        self.assignmentCheckpoint = assignmentCheckpoint
        self.finalizationCheckpoint = finalizationCheckpoint
        self.replacementCheckpoint = replacementCheckpoint
        self.bindingCheckpoint = bindingCheckpoint
        self.bindingDidChangeCheckpoint = bindingDidChangeCheckpoint
        self.startupRetrySleep = startupRetrySleep
        super.init()
        if activateSession { _ = session }
    }

    func start() async throws {
        let attempt: (generation: UInt64, task: Task<Void, Error>) = lock.withLock {
            if let startupAttempt { return startupAttempt }
            nextStartupAttemptGeneration &+= 1
            let created = Task { [weak self] in
                guard let self else { return }
                try await self.performStart()
            }
            let attempt = (generation: nextStartupAttemptGeneration, task: created)
            startupAttempt = attempt
            return attempt
        }
        do {
            try await attempt.task.value
        } catch {
            lock.withLock {
                if Self.startupAttemptCanClear(
                    currentGeneration: startupAttempt?.generation,
                    completedGeneration: attempt.generation
                ) { startupAttempt = nil }
            }
            throw error
        }
        let becameReady = lock.withLock { () -> Bool in
            guard Self.startupAttemptCanClear(
                currentGeneration: startupAttempt?.generation,
                completedGeneration: attempt.generation
            ) else { return false }
            startupAttempt = nil
            guard !startupReady else { return false }
            startupReady = true
            return true
        }
        if becameReady {
            await startupGate.markReady()
            completionGate.startupDidBecomeReady()
        }
    }

    private func performStart() async throws {
        guard let operation = operationGate.begin() else { throw CancellationError() }
        defer { operationGate.end() }
        let binding = try await requestBinding(operation: operation)
        guard operationGate.isCurrent(operation) else { throw CancellationError() }
        let tasks = await allTasks()
        guard operationGate.isCurrent(operation) else { throw CancellationError() }
        let deletionInProgress = await control.snapshot().deletionInProgress
        if !stagingEnabled() || deletionInProgress {
            tasks.forEach { $0.cancel() }
            clearAllLeasesAndSubmissionState()
            try await queue.removeAll()
        } else {
            try await reconstruct(tasks: tasks, fence: binding?.fence, operation: operation)
        }
        guard operationGate.isCurrent(operation) else { throw CancellationError() }
        try await completeInterruptedDeletionIfNeeded(tasks: tasks)
    }

    func configurationDidChange() async throws {
        _ = try await requestBinding()
    }

    func requestBinding() async throws -> TelemetryUploadBinding? {
        guard let operation = operationGate.begin() else { return nil }
        defer { operationGate.end() }
        return try await requestBinding(operation: operation)
    }

    private func requestBinding(operation: UInt64) async throws -> TelemetryUploadBinding? {
        var snapshot = try await configuration.snapshot()
        for _ in 0..<4 where operationGate.isCurrent(operation) {
            await bindingCheckpoint(snapshot.revision)
            guard operationGate.isCurrent(operation) else { return nil }
            let result = try await control.bind(snapshot: snapshot, installationID: installationID)
            guard operationGate.isCurrent(operation) else { return nil }
            if result.stale {
                guard let requiredRevision = result.requiredRevision else {
                    throw ServerConfigurationError.staleRevision
                }
                snapshot = try await configuration.snapshot(atLeastRevision: requiredRevision)
                continue
            }
            if result.changed {
                let tasks = await allTasks()
                guard operationGate.isCurrent(operation) else { return nil }
                tasks.forEach { $0.cancel() }
                clearTransferLeases()
                try await queue.removeAll()
                await bindingDidChangeCheckpoint()
                guard operationGate.isCurrent(operation) else { return nil }
            }
            return result.binding
        }
        guard !operationGate.isCurrent(operation) else {
            throw ServerConfigurationError.staleRevision
        }
        return nil
    }

    func currentFence() async -> TelemetryUploadFence? {
        await control.snapshot().fence
    }

    func isCurrent(_ fence: TelemetryUploadFence) async -> Bool {
        await control.isCurrent(fence)
    }

    func leasedEnvelopeIDs() -> Set<UUID> {
        lock.withLock {
            Set(
                leasedByTask.values.flatMap(\.envelopeIDs)
                    + finalizingByTask.values.flatMap(\.envelopeIDs)
                    + (preparedLease?.envelopeIDs ?? [])
            )
        }
    }

    func setCompletionHandler(
        _ handler: @escaping @Sendable (BackgroundUploadMetadata, BackgroundUploadOutcome) async -> Void
    ) {
        lock.withLock { completionHandler = handler }
    }

    func stageIfEnabled(_ envelopes: [TelemetryEnvelope]) async {
        guard stagingEnabled(), !envelopes.isEmpty,
              let operation = operationGate.begin() else { return }
        guard beginSubmissionIfIdle() else {
            operationGate.end()
            return
        }
        defer {
            endSubmission()
            operationGate.end()
        }
        do {
            await stageCheckpoint()
            guard operationGate.isCurrent(operation),
                  let binding = try await requestBinding(operation: operation),
                  binding.server.baseURL.scheme?.lowercased() == "https" else { return }
            guard operationGate.isCurrent(operation) else { return }
            if let prepared = try await queue.batches().first {
                guard operationGate.isCurrent(operation) else { return }
                setPreparedLease(prepared.metadata)
                try await submit(prepared, binding: binding, operation: operation)
                return
            }
            let batch = Array(envelopes.prefix(100))
            let prepared = try await queue.prepare(batch, fence: binding.fence)
            guard operationGate.isCurrent(operation) else {
                try? await queue.remove(batchID: prepared.metadata.batchID)
                return
            }
            setPreparedLease(prepared.metadata)
            try await submit(prepared, binding: binding, operation: operation)
        } catch {
            // The archive remains authoritative; a later trigger can retry staging.
        }
    }

    func resumePreparedIfEnabled() async {
        guard stagingEnabled(), let operation = operationGate.begin() else { return }
        guard beginSubmissionIfIdle() else {
            operationGate.end()
            return
        }
        defer {
            endSubmission()
            operationGate.end()
        }
        guard let binding = try? await requestBinding(operation: operation),
              operationGate.isCurrent(operation),
              let prepared = try? await queue.batches().first else { return }
        setPreparedLease(prepared.metadata)
        try? await submit(prepared, binding: binding, operation: operation)
    }

    func deleteAllTelemetry() async throws {
        await operationGate.beginDeletion()
        defer { operationGate.endDeletion() }
        let epoch = try await control.beginDeletion()
        let tasks = await allTasks()
        tasks.forEach { $0.cancel() }
        clearAllLeasesAndSubmissionState()
        try await queue.removeAll()
        try await archive.deleteAll()
        guard !(await queue.exists()), !(await archive.hasTelemetryFiles()) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try await control.completeDeletion(epoch: epoch)
    }

    func handleEvents(completionHandler: @escaping () -> Void) {
        completionGate.install { DispatchQueue.main.async(execute: completionHandler) }
        scheduleStartupRetryIfNeeded()
    }

    static func makeRequest(server: ServerConfiguration) -> URLRequest {
        var request = URLRequest(url: server.baseURL.appendingPathComponent("v1/telemetry/batches"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func backgroundRetryDelay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        BackgroundUploadRetryPolicy.delay(attempt: attempt, retryAfter: retryAfter)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        responses.rejectedRedirect(taskID: task.taskIdentifier)
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        responses.received(response: response as? HTTPURLResponse, taskID: dataTask.taskIdentifier)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responses.received(data: data, taskID: dataTask.taskIdentifier)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let completed = responses.complete(taskID: task.taskIdentifier)
        beginCallbackOwnership(taskID: task.taskIdentifier)
        completionGate.beginFinalization()
        Task { [self] in
            await self.startupGate.waitUntilReady()
            await self.finalize(taskID: task.taskIdentifier, completed: completed, error: error)
            self.completionGate.endFinalization()
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        completionGate.beginFinalization()
        completionGate.sessionFinishedEvents()
        Task { [self] in
            await self.startupGate.waitUntilReady()
            await self.removeUnownedSubmittedBatches()
            self.completionGate.endFinalization()
        }
    }

    private func submit(
        _ prepared: BackgroundUploadQueue.PreparedBatch,
        binding: TelemetryUploadBinding,
        operation: UInt64
    ) async throws {
        guard prepared.metadata.taskIdentifier < 0 else { return }
        guard operationGate.isCurrent(operation),
              !isCallbackOwned(taskID: prepared.metadata.taskIdentifier),
              binding.fence == prepared.metadata.fence,
              FileManager.default.fileExists(atPath: prepared.bodyURL.path) else {
            clearPreparedLease(batchID: prepared.metadata.batchID)
            try? await queue.remove(batchID: prepared.metadata.batchID)
            return
        }
        guard await control.isCurrent(binding.fence), operationGate.isCurrent(operation) else {
            clearPreparedLease(batchID: prepared.metadata.batchID)
            try? await queue.remove(batchID: prepared.metadata.batchID)
            return
        }
        let request = Self.makeRequest(server: binding.server)
        let task = session.uploadTask(with: request, fromFile: prepared.bodyURL)
        task.taskDescription = prepared.metadata.batchID.uuidString
        task.earliestBeginDate = prepared.metadata.retryNotBefore
        var metadata = prepared.metadata
        metadata.taskIdentifier = task.taskIdentifier
        await assignmentGate.acquire()
        do {
            try await queue.commit(metadata)
            await assignmentCheckpoint()
        } catch {
            await assignmentGate.release()
            task.cancel()
            try? await queue.remove(batchID: metadata.batchID)
            clearPreparedLease(batchID: metadata.batchID)
            throw error
        }
        guard operationGate.isCurrent(operation) else {
            await assignmentGate.release()
            task.cancel()
            try? await queue.remove(batchID: metadata.batchID)
            clearPreparedLease(batchID: metadata.batchID)
            return
        }
        setLease(metadata, taskID: task.taskIdentifier)
        await assignmentGate.release()
        task.resume()
    }

    private func reconstruct(
        tasks: [URLSessionTask],
        fence: TelemetryUploadFence?,
        operation: UInt64
    ) async throws {
        let batches = try await queue.batches()
        let callbackOwned = lock.withLock { callbackOwnedTaskIDs }
        let plan = BackgroundLeasePlan.make(
            taskIDs: tasks.map(\.taskIdentifier),
            batches: batches,
            fence: fence,
            callbackOwnedTaskIDs: callbackOwned,
            preserveAssignedBatches: true
        )
        for batch in batches where callbackOwned.contains(batch.metadata.taskIdentifier)
            && batch.metadata.fence == fence {
            setFinalizing(batch.metadata, taskID: batch.metadata.taskIdentifier)
        }
        var prepared = plan.prepared
        if let candidate = prepared, candidate.metadata.taskIdentifier >= 0 {
            prepared = try await queue.resetForRetry(candidate)
        }
        tasks.filter { plan.taskIDsToCancel.contains($0.taskIdentifier) }.forEach { $0.cancel() }
        for batchID in plan.batchIDsToRemove { try await queue.remove(batchID: batchID) }
        if let active = plan.active {
            setLease(active, taskID: active.taskIdentifier)
            tasks.first { $0.taskIdentifier == active.taskIdentifier }?.resume()
        }
        if let prepared { setPreparedLease(prepared.metadata) }
        if plan.active == nil, let prepared,
           !isCallbackOwned(taskID: prepared.metadata.taskIdentifier),
           let binding = try await requestBinding(operation: operation) {
            try await submit(prepared, binding: binding, operation: operation)
        }
    }

    func finalize(
        taskID: Int,
        completed: BackgroundTransferResponses.Completed,
        error: Error?
    ) async {
        defer { _ = lock.withLock { callbackOwnedTaskIDs.remove(taskID) } }
        let metadata: BackgroundUploadMetadata?
        if let owned = finalizingMetadata(taskID: taskID) {
            metadata = owned
        } else {
            let restored = try? await queue.batches().first {
                $0.metadata.taskIdentifier == taskID
            }?.metadata
            if let restored, await control.isCurrent(restored.fence) {
                setFinalizing(restored, taskID: taskID)
            }
            metadata = restored
        }
        guard let metadata else { return }
        await finalizationCheckpoint()
        let outcome = await finalizer.finalize(metadata: metadata, completed: completed, error: error)
        if Self.shouldScheduleReplacement(for: outcome) {
            await replacementCheckpoint()
            let replacement = await scheduleReplacementTask(
                batchID: metadata.batchID,
                fence: metadata.fence
            )
            if case .none = replacement {
                clearPreparedLease(batchID: metadata.batchID)
                clearFinalizing(taskID: taskID)
            }
        }
        let handler = lock.withLock { completionHandler }
        await handler?(metadata, outcome)
        if !Self.shouldScheduleReplacement(for: outcome) {
            clearFinalizing(taskID: taskID)
        }
    }

    private func scheduleReplacementTask(
        batchID: UUID,
        fence: TelemetryUploadFence
    ) async -> ReplacementOwnership {
        guard let operation = operationGate.begin() else { return .none }
        defer { operationGate.end() }
        guard beginSubmissionIfIdle() else {
            let ownership = replacementOwnership(batchID: batchID)
            guard case .none = ownership else { return ownership }
            await discardRetryStaging(batchID: batchID, fence: fence)
            return replacementOwnership(batchID: batchID)
        }
        defer { endSubmission() }
        guard operationGate.isCurrent(operation), await control.isCurrent(fence),
              let prepared = try? await queue.durablePreparedBatch(batchID: batchID, fence: fence),
              prepared.metadata.retryNotBefore != nil else {
            await discardRetryStaging(batchID: batchID, fence: fence)
            return replacementOwnership(batchID: batchID)
        }
        guard await retirePreparedSuccessor(replacingBatchID: batchID) else {
            await discardRetryStaging(batchID: batchID, fence: fence)
            return replacementOwnership(batchID: batchID)
        }
        guard operationGate.isCurrent(operation), await control.isCurrent(fence) else {
            await discardRetryStaging(batchID: batchID, fence: fence)
            return replacementOwnership(batchID: batchID)
        }
        publishPreparedReplacement(prepared.metadata)
        guard let binding = try? await requestBinding(operation: operation),
              binding.fence == fence, operationGate.isCurrent(operation) else {
            return replacementOwnership(batchID: batchID)
        }
        try? await submit(prepared, binding: binding, operation: operation)
        return replacementOwnership(batchID: batchID)
    }

    private func retirePreparedSuccessor(replacingBatchID: UUID) async -> Bool {
        guard let existing = lock.withLock({ preparedLease }),
              existing.batchID != replacingBatchID else {
            return true
        }
        do {
            _ = try await queue.remove(
                batchID: existing.batchID,
                expectedTaskIdentifier: existing.taskIdentifier
            )
            clearPreparedLease(batchID: existing.batchID)
            return true
        } catch {
            return false
        }
    }

    private func discardRetryStaging(batchID: UUID, fence: TelemetryUploadFence) async {
        _ = try? await queue.removePrepared(batchID: batchID, fence: fence)
        clearPreparedLease(batchID: batchID)
    }

    private static func shouldScheduleReplacement(for outcome: BackgroundUploadOutcome) -> Bool {
        switch outcome {
        case .partial, .failed(.transient):
            true
        case .failed(.rejected(let rejection)):
            rejection.retryable == true
        case .stale, .acknowledged, .failed:
            false
        }
    }

    private func completeInterruptedDeletionIfNeeded(tasks: [URLSessionTask]) async throws {
        let snapshot = await control.snapshot()
        guard snapshot.deletionInProgress else { return }
        tasks.forEach { $0.cancel() }
        clearAllLeasesAndSubmissionState()
        try await TelemetryDeletionTransaction.resumeIfNeeded(
            control: control,
            queue: queue,
            archive: archive
        )
    }

    private func allTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    private func setLease(_ metadata: BackgroundUploadMetadata, taskID: Int) {
        lock.withLock {
            leasedByTask[taskID] = metadata
            finalizingByTask = finalizingByTask.filter { $0.value.batchID != metadata.batchID }
            if preparedLease?.batchID == metadata.batchID { preparedLease = nil }
        }
    }

    private func beginCallbackOwnership(taskID: Int) {
        lock.withLock {
            callbackOwnedTaskIDs.insert(taskID)
            if let metadata = leasedByTask.removeValue(forKey: taskID) {
                finalizingByTask[taskID] = metadata
            }
        }
    }

    private func finalizingMetadata(taskID: Int) -> BackgroundUploadMetadata? {
        lock.withLock {
            if let metadata = finalizingByTask[taskID] { return metadata }
            guard let metadata = leasedByTask.removeValue(forKey: taskID) else { return nil }
            finalizingByTask[taskID] = metadata
            return metadata
        }
    }

    private func setFinalizing(_ metadata: BackgroundUploadMetadata, taskID: Int) {
        lock.withLock { finalizingByTask[taskID] = metadata }
    }

    private func clearFinalizing(taskID: Int) {
        lock.withLock { finalizingByTask.removeValue(forKey: taskID) }
    }

    private func clearTransferLeases() {
        lock.withLock {
            leasedByTask.removeAll()
            finalizingByTask.removeAll()
            preparedLease = nil
        }
    }

    private func clearAllLeasesAndSubmissionState() {
        lock.withLock {
            leasedByTask.removeAll()
            finalizingByTask.removeAll()
            preparedLease = nil
            submissionInProgress = false
        }
    }

    private func beginSubmissionIfIdle() -> Bool {
        lock.withLock {
            guard leasedByTask.isEmpty, !submissionInProgress else { return false }
            submissionInProgress = true
            return true
        }
    }

    private func endSubmission() {
        lock.withLock { submissionInProgress = false }
    }

    func setPreparedLease(_ metadata: BackgroundUploadMetadata) {
        lock.withLock { preparedLease = metadata }
    }

    private func publishPreparedReplacement(_ metadata: BackgroundUploadMetadata) {
        lock.withLock {
            preparedLease = metadata
            finalizingByTask = finalizingByTask.filter { $0.value.batchID != metadata.batchID }
        }
    }

    private func replacementOwnership(batchID: UUID) -> ReplacementOwnership {
        lock.withLock {
            if leasedByTask.values.contains(where: { $0.batchID == batchID }) { return .activeTask }
            if preparedLease?.batchID == batchID { return .prepared }
            return .none
        }
    }

    private func clearPreparedLease(batchID: UUID) {
        lock.withLock {
            if preparedLease?.batchID == batchID { preparedLease = nil }
        }
    }

    private func isCallbackOwned(taskID: Int) -> Bool {
        lock.withLock { callbackOwnedTaskIDs.contains(taskID) }
    }

    private func scheduleStartupRetryIfNeeded() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !startupReady, !startupRetryInProgress else { return false }
            startupRetryInProgress = true
            return true
        }
        guard shouldStart else { return }
        Task { [weak self] in
            guard let self else { return }
            while !(await self.startupGate.isReady()) {
                do {
                    try await self.start()
                } catch {
                    await self.startupRetrySleep()
                }
            }
            self.lock.withLock { self.startupRetryInProgress = false }
        }
    }

    func removeUnownedSubmittedBatches() async {
        guard let operation = operationGate.begin() else { return }
        defer { operationGate.end() }
        await assignmentGate.acquire()
        guard operationGate.isCurrent(operation) else {
            await assignmentGate.release()
            return
        }
        let (leasedTaskIDs, callbackOwned) = lock.withLock {
            (Set(leasedByTask.keys), callbackOwnedTaskIDs)
        }
        guard let batches = try? await queue.batches() else {
            await assignmentGate.release()
            return
        }
        for batch in batches where batch.metadata.taskIdentifier >= 0
            && !leasedTaskIDs.contains(batch.metadata.taskIdentifier)
            && !callbackOwned.contains(batch.metadata.taskIdentifier) {
            try? await queue.remove(batchID: batch.metadata.batchID)
            clearPreparedLease(batchID: batch.metadata.batchID)
        }
        await assignmentGate.release()
    }

    static func startupAttemptCanClear(
        currentGeneration: UInt64?,
        completedGeneration: UInt64
    ) -> Bool {
        currentGeneration == completedGeneration
    }
}
