@preconcurrency import ConnectIQ
import Foundation
import UIKit

@MainActor
final class GarminConnectionService: NSObject {
    private let model: AppModel
    private let ingestor: TelemetryIngestor
    private let deviceStore: GarminDeviceStore
    private let serverConfiguration: ServerConfigurationStore?
    private let connectIQ = ConnectIQ.sharedInstance()!
    private var devicesByID: [UUID: IQDevice] = [:]
    private var appsByDeviceID: [UUID: IQApp] = [:]

    init(
        model: AppModel,
        ingestor: TelemetryIngestor,
        deviceStore: GarminDeviceStore = GarminDeviceStore(),
        serverConfiguration: ServerConfigurationStore? = nil
    ) {
        self.model = model
        self.ingestor = ingestor
        self.deviceStore = deviceStore
        self.serverConfiguration = serverConfiguration
        super.init()
    }

    func start() {
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
                let status = try await ingestor.recoverPending()
                let configurationState = await self?.serverConfiguration?.displayState()
                await MainActor.run {
                    self?.model.updateServerStatus(status)
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

    func setCaptureEnabled(_ enabled: Bool) {
        model.captureEnabled = enabled
    }

    func deleteAllTelemetry() {
        Task { [weak self, ingestor] in
            do {
                try await ingestor.deleteAllTelemetry()
                await MainActor.run { self?.model.telemetryDeleted() }
            } catch {
                await MainActor.run { self?.model.ingestFailed(error) }
            }
        }
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

    private func ingest(_ sample: TelemetrySample, deviceID: UUID) {
        Task { [weak self, ingestor] in
            do {
                let result = try await ingestor.ingest(sample, from: deviceID)
                await MainActor.run { self?.model.received(result) }
            } catch {
                await MainActor.run { self?.model.ingestFailed(error) }
            }
        }
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
        guard let message else { return }
        do {
            let sample = try GarminMessageDecoder.decode(message)
            guard let deviceID = app?.device?.uuid else { return }
            Task { @MainActor [weak self] in
                guard let self, self.model.captureEnabled else { return }
                self.ingest(sample, deviceID: deviceID)
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
