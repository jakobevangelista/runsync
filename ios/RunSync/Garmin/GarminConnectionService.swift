@preconcurrency import ConnectIQ
import Foundation
import UIKit

struct GarminRecoveryResult: Equatable, Sendable {
    let captureResumed: Bool
    let sessionReconciled: Bool
    let currentActivityID: UUID?
    let pendingEnvelopeCount: Int
    let oldestPendingAge: TimeInterval?
    let uploadState: TelemetryUploadState
    let lastSafeErrorCategory: String?
}

@MainActor
final class GarminConnectionService: NSObject {
    private let model: AppModel
    private let ingestor: TelemetryIngestor
    private let deviceStore: GarminDeviceStore
    private let captureSettings: CaptureSettingsStore
    private let serverConfiguration: ServerConfigurationStore?
    private let connectIQ = ConnectIQ.sharedInstance()!
    private var devicesByID: [UUID: IQDevice] = [:]
    private var appsByDeviceID: [UUID: IQApp] = [:]
    private var recoveryTask: Task<GarminRecoveryResult, Never>?
    nonisolated private let receiptPipeline: GarminReceiptPipeline

    init(
        model: AppModel,
        ingestor: TelemetryIngestor,
        deviceStore: GarminDeviceStore = GarminDeviceStore(),
        captureSettings: CaptureSettingsStore = CaptureSettingsStore(),
        serverConfiguration: ServerConfigurationStore? = nil
    ) {
        self.model = model
        self.ingestor = ingestor
        self.deviceStore = deviceStore
        self.captureSettings = captureSettings
        self.serverConfiguration = serverConfiguration
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
            withUrlScheme: RunSyncConstants.callbackScheme,
            uiOverrideDelegate: nil,
            stateRestorationIdentifier: RunSyncConstants.restorationIdentifier
        )
        replaceDevices(deviceStore.load(), persist: false)
        model.record("Restored \(devicesByID.count) authorized device(s)")
        Task { [weak self, ingestor] in
            do {
                _ = await ingestor.captureChanged(enabled: settings.captureEnabled)
                await ingestor.startConnectivityMonitoring()
                let status = try await ingestor.applicationBecameActive()
                let session = try await ingestor.currentActivitySession()
                let configurationState = await self?.serverConfiguration?.displayState()
                await MainActor.run {
                    self?.model.updateServerStatus(status)
                    self?.model.restoreSession(session)
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

        guard let devices = connectIQ.parseDeviceSelectionResponse(from: url) as? [IQDevice] else {
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
        replaceDevices(devices, persist: true)
        model.record("Authorization accepted")
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
        let settings = captureSettings.load()
        model.captureEnabled = settings.captureEnabled
        model.selectedCaptureDeviceID = settings.selectedDeviceID
        Task { [weak self, ingestor] in
            do {
                let status = try await ingestor.applicationBecameActive()
                let session = try await ingestor.currentActivitySession()
                await MainActor.run {
                    self?.model.updateServerStatus(status)
                    self?.model.restoreSession(session)
                }
            } catch {
                await MainActor.run { self?.model.ingestFailed(error) }
            }
        }
    }

    func recoverAndRetry() async -> GarminRecoveryResult {
        if let recoveryTask { return await recoveryTask.value }
        let task = Task { [weak self] in
            guard let self else {
                return GarminRecoveryResult(
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
    }

    private func performRecovery() async -> GarminRecoveryResult {
        model.recoveryInProgress = true
        defer { model.recoveryInProgress = false }

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

        let status = await ingestor.currentStatus()
        let settings = captureSettings.load()
        model.captureEnabled = localResult.0
        model.selectedCaptureDeviceID = settings.selectedDeviceID
        model.updateServerStatus(status)
        if localResult.0 {
            if status.localArchiveIssueCount == 0 {
                model.archiveStatus = "Healthy"
            }
            model.record("Recovery completed; capture resumed")
            receiptPipeline.resume()
        } else {
            model.capturePausedForReconciliation()
        }
        refreshGarminStatus()

        let result = GarminRecoveryResult(
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

    private func replaceDevices(_ devices: [IQDevice], persist: Bool) {
        devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.uuid, $0) })
        appsByDeviceID.removeAll()

        if persist {
            do {
                try deviceStore.save(devices)
            } catch {
                model.archiveStatus = "Device cache error"
            }
        }

        model.authorizationStatus = devices.isEmpty ? "Action required" : "Authorized"
        model.authorizedDevices = devices
            .map { GarminDeviceOption(id: $0.uuid, name: $0.friendlyName ?? $0.modelName ?? "Garmin device") }
            .sorted { $0.name < $1.name }
        let selected = captureSettings.load().selectedDeviceID
        if let selectedDeviceID = selected, devicesByID[selectedDeviceID] == nil {
            model.record("Selected capture watch is not currently authorized")
        }
        if selected == nil, devices.count == 1, let deviceID = devices.first?.uuid {
            captureSettings.setSelectedDeviceID(deviceID)
            model.selectedCaptureDeviceID = deviceID
            model.record("Selected the only authorized watch for capture")
        } else {
            model.selectedCaptureDeviceID = selected
        }
        for device in devices {
            model.record("Registering \(device.friendlyName ?? device.modelName ?? "Garmin device")")
            connectIQ.register(forDeviceEvents: device, delegate: self)
            guard let app = IQApp(
                uuid: RunSyncConstants.manifestApplicationID,
                store: RunSyncConstants.developmentStoreID,
                device: device
            ) else { continue }
            appsByDeviceID[device.uuid] = app
            connectIQ.register(forAppMessages: app, delegate: self)
        }
    }

    private func updateAppStatus(for device: IQDevice) {
        guard let app = appsByDeviceID[device.uuid] else { return }
        connectIQ.getAppStatus(app) { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                if let status {
                    self.model.fieldStatus = status.isInstalled ? "Installed" : "Missing"
                    self.model.record("Data field status: \(status.isInstalled ? "installed" : "missing")")
                } else {
                    self.model.fieldStatus = "Unknown"
                    self.model.record("Data field status request failed")
                }
            }
        }
    }

    private func stopCaptureAfterQueueFailure() {
        captureSettings.setCaptureEnabled(false)
        Task { [ingestor] in _ = await ingestor.captureChanged(enabled: false) }
        model.captureEnabled = false
        model.receiptQueueOverflowed(total: receiptPipeline.droppedReceiptCount)
    }

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
        Task { @MainActor [weak self] in self?.model.watchStatus = label }
        Task { @MainActor [weak self] in self?.model.record("Watch status: \(label)") }
    }

    nonisolated func deviceCharacteristicsDiscovered(_ device: IQDevice!) {
        Task { @MainActor [weak self] in
            guard let self, let device else { return }
            self.model.watchStatus = "Ready: \(device.friendlyName ?? device.modelName ?? "Garmin")"
            self.model.record("Watch characteristics discovered")
            self.updateAppStatus(for: device)
        }
    }
}

extension GarminConnectionService: IQAppMessageDelegate {
    nonisolated func receivedMessage(_ message: Any!, from app: IQApp!) {
        let callbackTime = Date()
        guard let message else { return }
        do {
            let sample = try GarminMessageDecoder.decode(message)
            guard let deviceID = app?.device?.uuid else { return }
            guard receiptPipeline.enqueue(sample, from: deviceID, at: callbackTime) else {
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
