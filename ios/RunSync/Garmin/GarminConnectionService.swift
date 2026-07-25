@preconcurrency import ConnectIQ
import Foundation

enum GarminMessageStreamState: Equatable, Sendable {
    case unconfigured
    case waitingForDevice
    case waitingForReceipt
    case healthy
    case delayed
    case stale
    case repairing(tier: Int)
    case authorizationRequired

    var label: String {
        switch self {
        case .unconfigured: "Not authorized"
        case .waitingForDevice: "Waiting for watch"
        case .waitingForReceipt: "Waiting for telemetry"
        case .healthy: "Receiving"
        case .delayed: "Delayed"
        case .stale: "Unavailable"
        case .repairing(let tier): "Repairing (tier \(tier))"
        case .authorizationRequired: "Authorization required"
        }
    }
}

enum GarminTransportRepairOutcome: String, Equatable, Sendable {
    case recovered
    case waitingForReceipt
    case authorizationRequired
    case unavailable
    case coolingDown

    var label: String {
        switch self {
        case .recovered: "Recovered"
        case .waitingForReceipt: "Re-registered; waiting for telemetry"
        case .authorizationRequired: "Garmin authorization required"
        case .unavailable: "Transport unavailable"
        case .coolingDown: "Waiting before another automatic repair"
        }
    }
}

struct GarminTransportRepairResult: Equatable, Sendable {
    let outcome: GarminTransportRepairOutcome
    let tier: Int
    let registrationGeneration: UInt64
    let receiptSequence: Int?
}

struct GarminRecoveryResult: Equatable, Sendable {
    let transport: GarminTransportRepairResult
    let captureResumed: Bool
    let sessionReconciled: Bool
    let currentActivityID: UUID?
    let pendingEnvelopeCount: Int
    let oldestPendingAge: TimeInterval?
    let uploadState: TelemetryUploadState
    let lastSafeErrorCategory: String?
}

enum GarminRegistrationAction: Equatable {
    case unregisterApp(UUID)
    case unregisterDevice(UUID)
    case registerDevice(UUID)
    case registerApp(UUID)
}

struct GarminRegistrationPlanner {
    static func replacement<RegisteredDevices, RegisteredApps, ReplacementDevices>(
        registeredDeviceIDs: RegisteredDevices,
        registeredAppIDs: RegisteredApps,
        replacementDeviceIDs: ReplacementDevices
    ) -> [GarminRegistrationAction]
    where RegisteredDevices: Sequence,
          RegisteredApps: Sequence,
          ReplacementDevices: Sequence,
          RegisteredDevices.Element == UUID,
          RegisteredApps.Element == UUID,
          ReplacementDevices.Element == UUID {
        let oldApps = Set(registeredAppIDs).sorted { $0.uuidString < $1.uuidString }
        let oldDevices = Set(registeredDeviceIDs).sorted { $0.uuidString < $1.uuidString }
        let replacements = Set(replacementDeviceIDs).sorted { $0.uuidString < $1.uuidString }
        return oldApps.map(GarminRegistrationAction.unregisterApp)
            + oldDevices.map(GarminRegistrationAction.unregisterDevice)
            + replacements.map(GarminRegistrationAction.registerDevice)
            + replacements.map(GarminRegistrationAction.registerApp)
    }
}

struct GarminTransportRecoveryPolicy: Equatable, Sendable {
    let staleAfter: TimeInterval
    let reconnectGrace: TimeInterval
    let receiptWait: TimeInterval
    let monitorInterval: TimeInterval
    let repairBackoff: [TimeInterval]

    static let production = GarminTransportRecoveryPolicy(
        staleAfter: 30,
        reconnectGrace: 10,
        receiptWait: 20,
        monitorInterval: 5,
        repairBackoff: [15, 30, 60, 120]
    )

    func isStale(
        captureEnabled: Bool,
        streamExpected: Bool,
        lastReceiptAt: Date?,
        now: Date
    ) -> Bool {
        guard captureEnabled, streamExpected, let lastReceiptAt else { return false }
        return now.timeIntervalSince(lastReceiptAt) > staleAfter
    }

    func backoff(afterFailureCount failureCount: Int) -> TimeInterval {
        guard !repairBackoff.isEmpty else { return 0 }
        let index = min(max(0, failureCount - 1), repairBackoff.count - 1)
        return repairBackoff[index]
    }
}

@MainActor
protocol GarminConnectIQClient: AnyObject {
    func initialize(
        urlScheme: String,
        restorationIdentifier: String
    )
    func showDeviceSelection()
    func parseDeviceSelectionResponse(from url: URL) -> [IQDevice]?
    func registerDeviceEvents(_ device: IQDevice, delegate: any IQDeviceEventDelegate)
    func unregisterDeviceEvents(_ device: IQDevice, delegate: any IQDeviceEventDelegate)
    func registerAppMessages(_ app: IQApp, delegate: any IQAppMessageDelegate)
    func unregisterAppMessages(_ app: IQApp, delegate: any IQAppMessageDelegate)
    func getAppStatus(_ app: IQApp, completion: @escaping (IQAppStatus?) -> Void)
}

@MainActor
final class GarminConnectIQSDKClient: GarminConnectIQClient {
    private let connectIQ: ConnectIQ

    init(connectIQ: ConnectIQ = ConnectIQ.sharedInstance()!) {
        self.connectIQ = connectIQ
    }

    func initialize(urlScheme: String, restorationIdentifier: String) {
        connectIQ.initialize(
            withUrlScheme: urlScheme,
            uiOverrideDelegate: nil,
            stateRestorationIdentifier: restorationIdentifier
        )
    }

    func showDeviceSelection() {
        connectIQ.showDeviceSelection()
    }

    func parseDeviceSelectionResponse(from url: URL) -> [IQDevice]? {
        connectIQ.parseDeviceSelectionResponse(from: url) as? [IQDevice]
    }

    func registerDeviceEvents(_ device: IQDevice, delegate: any IQDeviceEventDelegate) {
        connectIQ.register(forDeviceEvents: device, delegate: delegate)
    }

    func unregisterDeviceEvents(_ device: IQDevice, delegate: any IQDeviceEventDelegate) {
        connectIQ.unregister(forDeviceEvents: device, delegate: delegate)
    }

    func registerAppMessages(_ app: IQApp, delegate: any IQAppMessageDelegate) {
        connectIQ.register(forAppMessages: app, delegate: delegate)
    }

    func unregisterAppMessages(_ app: IQApp, delegate: any IQAppMessageDelegate) {
        connectIQ.unregister(forAppMessages: app, delegate: delegate)
    }

    func getAppStatus(_ app: IQApp, completion: @escaping (IQAppStatus?) -> Void) {
        connectIQ.getAppStatus(app, completion: completion)
    }
}

private enum GarminTransportRepairReason: String {
    case manual
    case staleReceipt
    case foreground
    case reconnected
    case authorization
}

@MainActor
final class GarminConnectionService: NSObject {
    private let model: AppModel
    private let ingestor: TelemetryIngestor
    private let deviceStore: GarminDeviceStore
    private let captureSettings: CaptureSettingsStore
    private let serverConfiguration: ServerConfigurationStore?
    private let connectIQ: GarminConnectIQClient
    private let recoveryPolicy: GarminTransportRecoveryPolicy
    private var devicesByID: [UUID: IQDevice] = [:]
    private var appsByDeviceID: [UUID: IQApp] = [:]
    private var recoveryTask: Task<GarminRecoveryResult, Never>?
    private var transportRepairTask: Task<GarminTransportRepairResult, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var reconnectVerificationTask: Task<Void, Never>?
    private var registrationGeneration: UInt64 = 0
    private var lastSelectedReceiptAt: Date?
    private var lastSelectedReceiptSequence: Int?
    private var lastSelectedActivityState: ActivityState?
    private var transportRepairFailureCount = 0
    private var transportRepairCooldownUntil: Date?
    private var applicationIsActive = false
    private var selectedDeviceWasDisconnected = false
    nonisolated private let receiptPipeline: GarminReceiptPipeline

    init(
        model: AppModel,
        ingestor: TelemetryIngestor,
        deviceStore: GarminDeviceStore = GarminDeviceStore(),
        captureSettings: CaptureSettingsStore = CaptureSettingsStore(),
        serverConfiguration: ServerConfigurationStore? = nil,
        connectIQ: GarminConnectIQClient = GarminConnectIQSDKClient(),
        recoveryPolicy: GarminTransportRecoveryPolicy = .production
    ) {
        self.model = model
        self.ingestor = ingestor
        self.deviceStore = deviceStore
        self.captureSettings = captureSettings
        self.serverConfiguration = serverConfiguration
        self.connectIQ = connectIQ
        self.recoveryPolicy = recoveryPolicy
        self.receiptPipeline = GarminReceiptPipeline(
            consume: { [model, ingestor, captureSettings] receipt in
                let settings = captureSettings.load()
                do {
                    let result = try await ingestor.ingest(
                        receipt.sample,
                        from: receipt.deviceID,
                        phoneReceivedAt: receipt.phoneReceivedAt,
                        selectedDeviceID: settings.selectedDeviceID,
                        captureEnabled: settings.captureEnabled
                    )
                    await MainActor.run { model.received(result, callbackOrdinal: receipt.callbackOrdinal) }
                    return .processed
                } catch let error as TelemetryIngestionFailure {
                    await MainActor.run { model.ingestFailed(error) }
                    return .pause(retryCurrent: !error.receiptPersisted)
                } catch {
                    await MainActor.run { model.ingestFailed(error) }
                    return .pause(retryCurrent: true)
                }
            },
            onPause: { [model, ingestor, captureSettings] in
                captureSettings.setCaptureEnabled(false)
                Task { await ingestor.captureChanged(enabled: false) }
                Task { @MainActor in
                    model.captureEnabled = false
                    model.capturePausedForReconciliation()
                }
            }
        )
        super.init()
    }

    func start() {
        let settings = captureSettings.load()
        model.captureEnabled = settings.captureEnabled
        model.selectedCaptureDeviceID = settings.selectedDeviceID
        model.record("Initializing Garmin SDK")
        connectIQ.initialize(
            urlScheme: RunSyncConstants.callbackScheme,
            restorationIdentifier: RunSyncConstants.restorationIdentifier
        )
        model.persistDiagnostic("garmin_sdk_initialized")
        replaceDevices(deviceStore.load(), persist: false, reason: "launch_restore")
        model.persistDiagnostic("authorized_device_cache_restored", details: [
            "count": "\(devicesByID.count)"
        ])
        model.record("Restored \(devicesByID.count) authorized device(s)")
        Task { [weak self, ingestor] in
            do {
                _ = await ingestor.captureChanged(enabled: settings.captureEnabled)
                await ingestor.startConnectivityMonitoring()
                _ = try await ingestor.applicationBecameActive()
                let session = try await ingestor.currentActivitySession()
                let restoredStatus = await ingestor.currentStatus()
                let configurationState = await self?.serverConfiguration?.displayState()
                await MainActor.run {
                    self?.model.updateServerStatus(restoredStatus)
                    self?.model.restoreSession(session)
                    self?.restoreTransportState(
                        lastReceiptAt: restoredStatus.lastWatchReceiptAt,
                        activityState: session?.lastActivityState
                    )
                    if let configurationState {
                        self?.model.serverBaseURL = configurationState.baseURL
                        self?.model.serverTokenConfigured = configurationState.tokenConfigured
                    }
                }
            } catch {
                await MainActor.run { self?.model.ingestFailed(error) }
            }
        }
    }

    func authorizeDevice() {
        model.record("Opening Garmin device selection")
        model.persistDiagnostic("authorization_refresh_requested", details: [
            "generation": "\(registrationGeneration)"
        ])
        connectIQ.showDeviceSelection()
    }

    func handleAuthorizationCallback(_ url: URL, sourceApplication: String?) -> Bool {
        let sourceDescription = sourceApplication ?? "not supplied"
        model.record("Authorization callback scheme=\(url.scheme ?? "nil"), host=\(url.host ?? "nil"), source=\(sourceDescription)")
        guard url.scheme == RunSyncConstants.callbackScheme else {
            model.authorizationStatus = "Invalid callback"
            model.record("Rejected callback scheme")
            return false
        }

        if let sourceApplication,
           sourceApplication != IQGCMBundle,
           sourceApplication != IQGCMInternalBetaBundle {
            model.authorizationStatus = "Invalid callback source"
            model.record("Rejected callback source")
            return false
        }

        guard let devices = connectIQ.parseDeviceSelectionResponse(from: url) else {
            model.authorizationStatus = "Invalid Garmin response"
            model.record("Garmin response could not be parsed")
            return false
        }
        model.record("Garmin response contained \(devices.count) device(s)")
        guard !devices.isEmpty else {
            model.authorizationStatus = "No device returned"
            model.record("No authorized device returned")
            return false
        }
        replaceDevices(devices, persist: true, reason: "authorization")
        model.record("Authorization accepted")
        Task { [weak self] in
            _ = await self?.repairTransport(reason: .authorization, bypassCooldown: true)
        }
        return true
    }

    func saveServerConfiguration(baseURL: String, token: String) {
        guard let serverConfiguration else { return }
        Task { [weak self, ingestor] in
            do {
                try await serverConfiguration.save(baseURL: baseURL, token: token.isEmpty ? nil : token)
                let state = await serverConfiguration.displayState()
                let status = await ingestor.configurationChanged(
                    configured: !state.baseURL.isEmpty && state.tokenConfigured
                )
                await MainActor.run {
                    self?.model.serverBaseURL = state.baseURL
                    self?.model.serverTokenConfigured = state.tokenConfigured
                    self?.model.serverConfigurationStatus = "Saved"
                    self?.model.updateServerStatus(status)
                }
            } catch {
                await MainActor.run { self?.model.serverConfigurationStatus = "Invalid URL or token" }
            }
        }
    }

    func retryUploads(force: Bool = false) {
        Task { [weak self, ingestor] in
            let status = await ingestor.retryPending(force: force)
            await MainActor.run { self?.model.updateServerStatus(status) }
        }
    }

    func retryQuarantinedEnvelopes() {
        Task { [weak self, ingestor] in
            let status = await ingestor.retryQuarantined()
            await MainActor.run {
                self?.model.updateServerStatus(status)
                self?.model.record("Explicitly retried quarantined envelopes")
            }
        }
    }

    func applicationBecameActive() {
        applicationIsActive = true
        startWatchdog()
        let settings = captureSettings.load()
        model.captureEnabled = settings.captureEnabled
        model.selectedCaptureDeviceID = settings.selectedDeviceID
        Task { [weak self, ingestor] in
            do {
                _ = try await ingestor.applicationBecameActive()
                let session = try await ingestor.currentActivitySession()
                let restoredStatus = await ingestor.currentStatus()
                await MainActor.run {
                    self?.model.updateServerStatus(restoredStatus)
                    self?.model.restoreSession(session)
                    self?.restoreTransportState(
                        lastReceiptAt: restoredStatus.lastWatchReceiptAt,
                        activityState: session?.lastActivityState
                    )
                    self?.evaluateTransportFreshness(reason: .foreground)
                }
            } catch {
                await MainActor.run { self?.model.ingestFailed(error) }
            }
        }
    }

    func applicationBecameInactive() {
        applicationIsActive = false
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    func recoverAndRetry() async -> GarminRecoveryResult {
        if let recoveryTask { return await recoveryTask.value }
        let task = Task { [weak self] in
            guard let self else {
                return GarminRecoveryResult(
                    transport: GarminTransportRepairResult(
                        outcome: .unavailable,
                        tier: 0,
                        registrationGeneration: 0,
                        receiptSequence: nil
                    ),
                    captureResumed: false,
                    sessionReconciled: false,
                    currentActivityID: nil,
                    pendingEnvelopeCount: 0,
                    oldestPendingAge: nil,
                    uploadState: .idle,
                    lastSafeErrorCategory: "service_unavailable"
                )
            }
            return await self.performRecovery()
        }
        recoveryTask = task
        let result = await task.value
        recoveryTask = nil
        return result
    }

    func setCaptureEnabled(_ enabled: Bool) {
        let accepted = receiptPipeline.enqueueOperation { [model, ingestor, captureSettings] in
            if enabled {
                do {
                    try await ingestor.reconcileSession()
                } catch {
                    await MainActor.run { model.ingestFailed(error) }
                    return false
                }
            }
            _ = await ingestor.captureChanged(enabled: enabled)
            captureSettings.setCaptureEnabled(enabled)
            await MainActor.run {
                model.captureEnabled = enabled
                model.record(enabled ? "Capture enabled" : "Capture disabled")
            }
            return true
        }
        guard accepted else {
            stopCaptureAfterQueueFailure()
            return
        }
        if enabled { receiptPipeline.resume() }
    }

    func selectCaptureDevice(_ deviceID: UUID) {
        guard deviceID != captureSettings.load().selectedDeviceID else { return }
        let accepted = receiptPipeline.enqueueOperation { [model, ingestor, captureSettings] in
            do {
                guard try await ingestor.canChangeCaptureDevice() else {
                    await MainActor.run {
                        model.record("End the current RunSync session before changing watches")
                        model.selectedCaptureDeviceID = captureSettings.load().selectedDeviceID
                    }
                    return true
                }
                captureSettings.setSelectedDeviceID(deviceID)
                await MainActor.run {
                    model.selectedCaptureDeviceID = deviceID
                    model.record("Selected telemetry capture watch")
                }
                return true
            } catch {
                await MainActor.run { model.ingestFailed(error) }
                return false
            }
        }
        if !accepted { stopCaptureAfterQueueFailure() }
        lastSelectedReceiptAt = nil
        lastSelectedReceiptSequence = nil
        lastSelectedActivityState = nil
        updateMessageStreamState(devicesByID[deviceID] == nil ? .unconfigured : .waitingForReceipt)
    }

    func deleteAllTelemetry() {
        let accepted = receiptPipeline.enqueueOperation { [model, ingestor, captureSettings] in
            do {
                captureSettings.setCaptureEnabled(false)
                _ = await ingestor.captureChanged(enabled: false)
                try await ingestor.deleteAllTelemetry()
                await MainActor.run {
                    model.captureEnabled = false
                    model.telemetryDeleted()
                }
                return true
            } catch {
                await MainActor.run { model.ingestFailed(error) }
                return false
            }
        }
        if !accepted { stopCaptureAfterQueueFailure() }
        lastSelectedReceiptAt = nil
        lastSelectedReceiptSequence = nil
        lastSelectedActivityState = nil
        updateMessageStreamState(devicesByID.isEmpty ? .unconfigured : .waitingForReceipt)
    }

    private func performRecovery() async -> GarminRecoveryResult {
        model.recoveryInProgress = true
        defer { model.recoveryInProgress = false }
        let transportTask = Task { [weak self] in
            guard let self else {
                return GarminTransportRepairResult(
                    outcome: .unavailable,
                    tier: 0,
                    registrationGeneration: 0,
                    receiptSequence: nil
                )
            }
            return await self.repairTransport(reason: .manual, bypassCooldown: true)
        }

        do {
            _ = try await ingestor.prepareManualRecovery()
        } catch {
            model.ingestFailed(error)
        }

        let localResult = await withCheckedContinuation { continuation in
            let accepted = receiptPipeline.requestRecovery { [ingestor, captureSettings] in
                let settings = captureSettings.load()
                do {
                    try await ingestor.reconcileSession()
                    captureSettings.setSelectedDeviceID(settings.selectedDeviceID)
                    captureSettings.setCaptureEnabled(true)
                    _ = await ingestor.captureChanged(enabled: true)
                    let session = try await ingestor.currentActivitySession()
                    continuation.resume(returning: (true, session?.localRunID, Optional<String>.none))
                    return true
                } catch {
                    captureSettings.setCaptureEnabled(false)
                    _ = await ingestor.captureChanged(enabled: false)
                    continuation.resume(returning: (false, Optional<UUID>.none, "session_reconciliation"))
                    return false
                }
            }
            if !accepted {
                continuation.resume(returning: (false, Optional<UUID>.none, "recovery_already_running"))
            }
        }

        let initialStatus = await ingestor.currentStatus()
        let settings = captureSettings.load()
        model.captureEnabled = localResult.0
        model.selectedCaptureDeviceID = settings.selectedDeviceID
        model.updateServerStatus(initialStatus)
        if localResult.0 {
            if initialStatus.localArchiveIssueCount == 0 {
                model.archiveStatus = "Healthy"
            }
            model.record("Recovery completed; capture resumed")
            receiptPipeline.resume()
        } else {
            model.capturePausedForReconciliation()
        }
        let transportResult = await transportTask.value
        let status = await ingestor.currentStatus()
        model.updateServerStatus(status)
        refreshGarminStatus()
        model.record("Watch transport recovery: \(transportResult.outcome.label)")

        let result = GarminRecoveryResult(
            transport: transportResult,
            captureResumed: localResult.0,
            sessionReconciled: localResult.0,
            currentActivityID: localResult.1,
            pendingEnvelopeCount: status.pendingCount,
            oldestPendingAge: status.oldestPendingAge,
            uploadState: status.uploadState,
            lastSafeErrorCategory: localResult.2
                ?? status.lastSafeErrorCategory
                ?? safeUploadErrorCategory(status.uploadState)
        )
        model.recoveryResult = result
        return result
    }

    private func safeUploadErrorCategory(_ state: TelemetryUploadState) -> String? {
        switch state {
        case .notConfigured:
            return "upload_not_configured"
        case .blocked(let reason):
            return reason == "Authentication rejected" ? "upload_authentication" : "upload_blocked"
        default:
            return nil
        }
    }

    private func refreshGarminStatus() {
        for device in devicesByID.values {
            updateAppStatus(for: device)
        }
        model.record("Refreshed Garmin device and data field status")
    }

    private func replaceDevices(_ devices: [IQDevice], persist: Bool, reason: String) {
        if persist {
            do {
                try deviceStore.save(devices)
            } catch {
                model.archiveStatus = "Device cache error"
            }
        }

        let previousDevices = devicesByID
        let previousApps = appsByDeviceID
        let replacements = Dictionary(
            devices.map { ($0.uuid, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let canonicalDevices = replacements.values.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
        let actions = GarminRegistrationPlanner.replacement(
            registeredDeviceIDs: previousDevices.keys,
            registeredAppIDs: previousApps.keys,
            replacementDeviceIDs: replacements.keys
        )
        registrationGeneration &+= 1
        let generation = registrationGeneration
        model.registrationGeneration = generation
        model.persistDiagnostic("registration_replace_started", details: [
            "generation": "\(generation)",
            "reason": reason,
            "oldDeviceCount": "\(previousDevices.count)",
            "newDeviceCount": "\(replacements.count)"
        ])
        devicesByID.removeAll()
        appsByDeviceID.removeAll()

        for action in actions {
            switch action {
            case .unregisterApp(let deviceID):
                guard let app = previousApps[deviceID] else { continue }
                connectIQ.unregisterAppMessages(app, delegate: self)
                model.persistDiagnostic("app_messages_unregistered", details: [
                    "device": abbreviated(deviceID.uuidString),
                    "generation": "\(generation)"
                ])
            case .unregisterDevice(let deviceID):
                guard let device = previousDevices[deviceID] else { continue }
                connectIQ.unregisterDeviceEvents(device, delegate: self)
                model.persistDiagnostic("device_events_unregistered", details: [
                    "device": abbreviated(deviceID.uuidString),
                    "generation": "\(generation)"
                ])
            case .registerDevice(let deviceID):
                guard let device = replacements[deviceID] else { continue }
                devicesByID[deviceID] = device
                connectIQ.registerDeviceEvents(device, delegate: self)
                model.persistDiagnostic("device_events_registered", details: [
                    "device": abbreviated(deviceID.uuidString),
                    "generation": "\(generation)"
                ])
            case .registerApp(let deviceID):
                guard let device = replacements[deviceID],
                      let app = makeApp(for: device) else { continue }
                appsByDeviceID[deviceID] = app
                connectIQ.registerAppMessages(app, delegate: self)
                model.persistDiagnostic("app_messages_registered", details: [
                    "device": abbreviated(deviceID.uuidString),
                    "generation": "\(generation)"
                ])
            }
        }

        devicesByID = replacements
        model.authorizationStatus = canonicalDevices.isEmpty ? "Action required" : "Authorized"
        model.authorizedDevices = canonicalDevices
            .map { GarminDeviceOption(id: $0.uuid, name: $0.friendlyName ?? $0.modelName ?? "Garmin device") }
            .sorted { $0.name < $1.name }
        let selected = captureSettings.load().selectedDeviceID
        if let selectedDeviceID = selected, devicesByID[selectedDeviceID] == nil {
            model.record("Selected capture watch is not currently authorized")
        }
        if selected == nil, canonicalDevices.count == 1, let deviceID = canonicalDevices.first?.uuid {
            captureSettings.setSelectedDeviceID(deviceID)
            model.selectedCaptureDeviceID = deviceID
            model.record("Selected the only authorized watch for capture")
        } else {
            model.selectedCaptureDeviceID = selected
        }
        updateMessageStreamState(canonicalDevices.isEmpty ? .unconfigured : .waitingForReceipt)
        model.persistDiagnostic("registration_replace_completed", details: [
            "generation": "\(generation)",
            "deviceCount": "\(devicesByID.count)",
            "appCount": "\(appsByDeviceID.count)"
        ])
    }

    private func replaceAppMessageRegistrations(reason: String) {
        let previousApps = appsByDeviceID
        registrationGeneration &+= 1
        let generation = registrationGeneration
        model.registrationGeneration = generation
        model.persistDiagnostic("app_registration_replace_started", details: [
            "generation": "\(generation)",
            "reason": reason,
            "appCount": "\(previousApps.count)"
        ])
        for deviceID in previousApps.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let app = previousApps[deviceID] else { continue }
            connectIQ.unregisterAppMessages(app, delegate: self)
            model.persistDiagnostic("app_messages_unregistered", details: [
                "device": abbreviated(deviceID.uuidString),
                "generation": "\(generation)"
            ])
        }
        appsByDeviceID.removeAll()
        for deviceID in devicesByID.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let device = devicesByID[deviceID],
                  let app = makeApp(for: device) else { continue }
            appsByDeviceID[deviceID] = app
            connectIQ.registerAppMessages(app, delegate: self)
            model.persistDiagnostic("app_messages_registered", details: [
                "device": abbreviated(deviceID.uuidString),
                "generation": "\(generation)"
            ])
        }
        model.persistDiagnostic("app_registration_replace_completed", details: [
            "generation": "\(generation)",
            "appCount": "\(appsByDeviceID.count)"
        ])
    }

    private func makeApp(for device: IQDevice) -> IQApp? {
        IQApp(
            uuid: RunSyncConstants.manifestApplicationID,
            store: RunSyncConstants.developmentStoreID,
            device: device
        )
    }

    private func updateAppStatus(for device: IQDevice) {
        guard let app = appsByDeviceID[device.uuid] else { return }
        let generation = registrationGeneration
        connectIQ.getAppStatus(app) { [weak self] status in
            Task { @MainActor in
                guard let self, self.registrationGeneration == generation else {
                    self?.model.persistDiagnostic("stale_app_status_ignored", details: [
                        "generation": "\(generation)"
                    ])
                    return
                }
                if let status {
                    self.model.fieldStatus = status.isInstalled ? "Installed" : "Missing"
                    self.model.record("Data field status: \(status.isInstalled ? "installed" : "missing")")
                    self.model.persistDiagnostic("app_status_request_completed", details: [
                        "device": abbreviated(device.uuid.uuidString),
                        "generation": "\(generation)",
                        "installed": "\(status.isInstalled)"
                    ])
                } else {
                    self.model.fieldStatus = "Unknown"
                    self.model.record("Data field status request failed")
                    self.model.persistDiagnostic("app_status_request_failed", details: [
                        "device": abbreviated(device.uuid.uuidString),
                        "generation": "\(generation)"
                    ])
                }
            }
        }
    }

    private func restoreTransportState(lastReceiptAt: Date?, activityState: ActivityState?) {
        if let lastReceiptAt,
           lastSelectedReceiptAt.map({ lastReceiptAt > $0 }) ?? true {
            lastSelectedReceiptAt = lastReceiptAt
        }
        if let activityState {
            lastSelectedActivityState = activityState
        }
        updateFreshnessLabel(now: Date())
    }

    private var streamExpected: Bool {
        switch lastSelectedActivityState {
        case .some(.running), .some(.paused):
            true
        default:
            false
        }
    }

    private func startWatchdog() {
        guard watchdogTask == nil else { return }
        let interval = recoveryPolicy.monitorInterval
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                self.evaluateTransportFreshness(reason: .staleReceipt)
            }
        }
    }

    private func evaluateTransportFreshness(reason: GarminTransportRepairReason) {
        let now = Date()
        updateFreshnessLabel(now: now)
        guard applicationIsActive,
              recoveryPolicy.isStale(
                  captureEnabled: captureSettings.load().captureEnabled,
                  streamExpected: streamExpected,
                  lastReceiptAt: lastSelectedReceiptAt,
                  now: now
              ) else { return }
        guard transportRepairTask == nil else { return }
        if let cooldown = transportRepairCooldownUntil, cooldown > now {
            model.transportRepairStatus = GarminTransportRepairOutcome.coolingDown.label
            return
        }
        Task { [weak self] in
            _ = await self?.repairTransport(reason: reason, bypassCooldown: false)
        }
    }

    private func updateFreshnessLabel(now: Date) {
        guard !devicesByID.isEmpty else {
            updateMessageStreamState(.unconfigured)
            return
        }
        guard let lastSelectedReceiptAt else {
            updateMessageStreamState(.waitingForReceipt)
            return
        }
        let age = max(0, now.timeIntervalSince(lastSelectedReceiptAt))
        if age <= WatchReceiptFreshness.currentThreshold {
            updateMessageStreamState(.healthy)
        } else if age <= recoveryPolicy.staleAfter {
            updateMessageStreamState(.delayed)
        } else if streamExpected {
            updateMessageStreamState(.stale)
        } else {
            updateMessageStreamState(.waitingForReceipt)
        }
    }

    private func repairTransport(
        reason: GarminTransportRepairReason,
        bypassCooldown: Bool
    ) async -> GarminTransportRepairResult {
        if let transportRepairTask {
            return await transportRepairTask.value
        }
        let now = Date()
        if !bypassCooldown,
           let cooldown = transportRepairCooldownUntil,
           cooldown > now {
            let result = GarminTransportRepairResult(
                outcome: .coolingDown,
                tier: 0,
                registrationGeneration: registrationGeneration,
                receiptSequence: nil
            )
            model.transportRepairStatus = result.outcome.label
            return result
        }
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return GarminTransportRepairResult(
                    outcome: .unavailable,
                    tier: 0,
                    registrationGeneration: 0,
                    receiptSequence: nil
                )
            }
            return await self.performTransportRepair(reason: reason)
        }
        transportRepairTask = task
        let result = await task.value
        transportRepairTask = nil
        return result
    }

    private func performTransportRepair(
        reason: GarminTransportRepairReason
    ) async -> GarminTransportRepairResult {
        guard !devicesByID.isEmpty else {
            updateMessageStreamState(.authorizationRequired)
            model.transportRepairStatus = GarminTransportRepairOutcome.authorizationRequired.label
            return GarminTransportRepairResult(
                outcome: .authorizationRequired,
                tier: 0,
                registrationGeneration: registrationGeneration,
                receiptSequence: nil
            )
        }

        model.persistDiagnostic("transport_repair_started", details: [
            "reason": reason.rawValue,
            "generation": "\(registrationGeneration)",
            "receiptAgeSeconds": lastSelectedReceiptAt
                .map { "\(max(0, Int(Date().timeIntervalSince($0))))" } ?? "never"
        ])

        if !streamExpected {
            let devices = devicesByID.values.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
            replaceDevices(devices, persist: false, reason: "\(reason.rawValue)_no_active_stream")
            let result = GarminTransportRepairResult(
                outcome: .waitingForReceipt,
                tier: 2,
                registrationGeneration: registrationGeneration,
                receiptSequence: nil
            )
            model.transportRepairStatus = result.outcome.label
            model.persistDiagnostic("transport_repair_waiting_for_activity", details: [
                "generation": "\(registrationGeneration)"
            ])
            return result
        }

        let observationStartedAt = Date()
        refreshGarminStatus()
        if let sequence = await waitForSelectedReceipt(after: observationStartedAt, timeout: 1) {
            return completeTransportRepair(tier: 0, sequence: sequence)
        }

        updateMessageStreamState(.repairing(tier: 1))
        replaceAppMessageRegistrations(reason: reason.rawValue)
        let tierOneStartedAt = Date()
        model.persistDiagnostic("transport_repair_waiting_for_receipt", details: [
            "tier": "1",
            "generation": "\(registrationGeneration)"
        ])
        if let sequence = await waitForSelectedReceipt(
            after: tierOneStartedAt,
            timeout: recoveryPolicy.receiptWait
        ) {
            return completeTransportRepair(tier: 1, sequence: sequence)
        }

        let devices = devicesByID.values.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
        replaceDevices(devices, persist: false, reason: "\(reason.rawValue)_tier_2")
        updateMessageStreamState(.repairing(tier: 2))
        let tierTwoStartedAt = Date()
        model.persistDiagnostic("transport_repair_waiting_for_receipt", details: [
            "tier": "2",
            "generation": "\(registrationGeneration)"
        ])
        if let sequence = await waitForSelectedReceipt(
            after: tierTwoStartedAt,
            timeout: recoveryPolicy.receiptWait
        ) {
            return completeTransportRepair(tier: 2, sequence: sequence)
        }

        transportRepairFailureCount += 1
        let delay = recoveryPolicy.backoff(afterFailureCount: transportRepairFailureCount)
        transportRepairCooldownUntil = Date().addingTimeInterval(delay)
        updateMessageStreamState(.authorizationRequired)
        model.transportRepairStatus = GarminTransportRepairOutcome.authorizationRequired.label
        model.authorizationStatus = "Refresh required"
        model.persistDiagnostic("transport_repair_failed", details: [
            "tier": "2",
            "generation": "\(registrationGeneration)",
            "nextAttemptDelaySeconds": "\(Int(delay))",
            "failureCount": "\(transportRepairFailureCount)"
        ])
        return GarminTransportRepairResult(
            outcome: .authorizationRequired,
            tier: 2,
            registrationGeneration: registrationGeneration,
            receiptSequence: nil
        )
    }

    private func waitForSelectedReceipt(after startedAt: Date, timeout: TimeInterval) async -> Int? {
        let deadline = startedAt.addingTimeInterval(timeout)
        while Date() < deadline {
            if let receiptAt = lastSelectedReceiptAt,
               receiptAt > startedAt {
                return lastSelectedReceiptSequence
            }
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private func completeTransportRepair(tier: Int, sequence: Int?) -> GarminTransportRepairResult {
        transportRepairFailureCount = 0
        transportRepairCooldownUntil = nil
        updateMessageStreamState(.healthy)
        model.authorizationStatus = "Authorized"
        model.transportRepairStatus = GarminTransportRepairOutcome.recovered.label
        model.persistDiagnostic("transport_repair_succeeded", details: [
            "tier": "\(tier)",
            "generation": "\(registrationGeneration)",
            "watchSequence": sequence.map(String.init) ?? "unknown"
        ])
        return GarminTransportRepairResult(
            outcome: .recovered,
            tier: tier,
            registrationGeneration: registrationGeneration,
            receiptSequence: sequence
        )
    }

    private func updateMessageStreamState(_ state: GarminMessageStreamState) {
        model.watchMessageStatus = state.label
        model.registrationGeneration = registrationGeneration
    }

    private func selectedTransportMessageReceived(
        from deviceID: UUID,
        sequence: Int,
        activityState: ActivityState,
        at receivedAt: Date
    ) {
        guard devicesByID[deviceID] != nil else {
            model.persistDiagnostic("unauthorized_device_message_ignored", details: [
                "device": abbreviated(deviceID.uuidString)
            ])
            return
        }
        let selectedDeviceID = captureSettings.load().selectedDeviceID
        guard selectedDeviceID == nil || selectedDeviceID == deviceID else { return }
        let repairWasRunning = transportRepairTask != nil
        lastSelectedReceiptAt = receivedAt
        lastSelectedReceiptSequence = sequence
        lastSelectedActivityState = activityState
        transportRepairFailureCount = 0
        transportRepairCooldownUntil = nil
        selectedDeviceWasDisconnected = false
        updateMessageStreamState(.healthy)
        model.authorizationStatus = "Authorized"
        model.transportRepairStatus = repairWasRunning ? "Receipt received; verifying" : "Healthy"
        if repairWasRunning {
            model.persistDiagnostic("transport_receipt_during_repair", details: [
                "generation": "\(registrationGeneration)",
                "watchSequence": "\(sequence)"
            ])
        }
    }

    private func scheduleReconnectVerification(for deviceID: UUID) {
        guard captureSettings.load().selectedDeviceID == deviceID,
              captureSettings.load().captureEnabled,
              selectedDeviceWasDisconnected,
              streamExpected else { return }
        selectedDeviceWasDisconnected = false
        reconnectVerificationTask?.cancel()
        let baseline = lastSelectedReceiptAt
        let grace = recoveryPolicy.reconnectGrace
        reconnectVerificationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard let self, !Task.isCancelled else { return }
            if let current = self.lastSelectedReceiptAt,
               baseline.map({ current > $0 }) ?? true {
                return
            }
            _ = await self.repairTransport(reason: .reconnected, bypassCooldown: false)
        }
    }

    private func stopCaptureAfterQueueFailure() {
        captureSettings.setCaptureEnabled(false)
        Task { [ingestor] in _ = await ingestor.captureChanged(enabled: false) }
        model.captureEnabled = false
        model.receiptQueueOverflowed(total: receiptPipeline.droppedReceiptCount)
    }

}

private func abbreviated(_ value: String) -> String {
    String(value.prefix(8))
}

extension GarminConnectionService: IQDeviceEventDelegate {
    nonisolated func deviceStatusChanged(_ device: IQDevice!, status: IQDeviceStatus) {
        let label: String
        switch status {
        case .invalidDevice: label = "Invalid device"
        case .bluetoothNotReady: label = "Bluetooth unavailable"
        case .notFound: label = "Not found"
        case .notConnected: label = "Disconnected"
        case .connected: label = "Connected, discovering"
        @unknown default: label = "Unknown"
        }
        let deviceTag = device?.uuid.uuidString
        Task { @MainActor [weak self] in
            guard let self, let device, self.devicesByID[device.uuid] != nil else { return }
            self.model.watchStatus = label
            self.model.record("Watch status: \(label)")
            self.model.persistDiagnostic("device_status_changed", details: [
                "device": deviceTag.map(abbreviated) ?? "unknown",
                "status": label,
                "generation": "\(self.registrationGeneration)"
            ])
            if self.captureSettings.load().selectedDeviceID == device.uuid {
                switch status {
                case .bluetoothNotReady, .notFound, .notConnected, .invalidDevice:
                    self.selectedDeviceWasDisconnected = true
                case .connected:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    nonisolated func deviceCharacteristicsDiscovered(_ device: IQDevice!) {
        Task { @MainActor [weak self] in
            guard let self, let device else { return }
            self.model.watchStatus = "Ready: \(device.friendlyName ?? device.modelName ?? "Garmin")"
            self.model.record("Watch characteristics discovered")
            self.model.persistDiagnostic("device_characteristics_discovered", details: [
                "device": abbreviated(device.uuid.uuidString),
                "generation": "\(self.registrationGeneration)"
            ])
            self.updateAppStatus(for: device)
            self.scheduleReconnectVerification(for: device.uuid)
        }
    }
}

extension GarminConnectionService: IQAppMessageDelegate {
    nonisolated func receivedMessage(_ message: Any!, from app: IQApp!) {
        let callbackTime = Date()
        guard let message else { return }
        do {
            let decoded = try GarminMessageDecoder.decode(message)
            guard let deviceID = app?.device?.uuid else { return }
            Task { @MainActor [weak self] in
                self?.selectedTransportMessageReceived(
                    from: deviceID,
                    sequence: decoded.sample.sequence,
                    activityState: decoded.sample.state,
                    at: callbackTime
                )
            }
            for warning in decoded.warnings {
                Task { @MainActor [weak self] in
                    self?.model.invalidWatchDiagnostic(warning, sequence: decoded.sample.sequence)
                }
            }
            guard receiptPipeline.enqueue(decoded.sample, from: deviceID, at: callbackTime) else {
                Task { @MainActor [weak self] in
                    self?.stopCaptureAfterQueueFailure()
                }
                return
            }
        } catch {
            let reason = GarminMessageDecoder.diagnosticReason(for: error)
            let shape = GarminMessageDecoder.diagnosticShape(of: message)
            Task { @MainActor [weak self] in
                self?.model.rejectedMessage(reason: reason, shape: shape)
            }
        }
    }
}
