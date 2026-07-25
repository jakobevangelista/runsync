import Foundation
import SwiftUI

@MainActor
final class AppContainer {
    static let shared = AppContainer()

    let model: AppModel
    let garmin: GarminConnectionService
    let backgroundUploader: BackgroundTelemetryUploadManager
    private var startupTask: Task<Bool, Never>?

    private init() {
        let model = AppModel()
        let installationID = InstallationIdentity.loadOrCreate()
        let fenceGate = TelemetryUploadFenceGate()
        let control = TelemetryUploadControlStore(gate: fenceGate)
        let archive = TelemetryArchive(uploadFenceGate: fenceGate)
        let configuration = ServerConfigurationStore()
        let backgroundUploader = BackgroundTelemetryUploadManager(
            archive: archive,
            configuration: configuration,
            installationID: installationID,
            control: control
        )
        let sink = HTTPTelemetrySink(configuration: configuration)
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: installationID,
            statusDidChange: { [model] status in
                await MainActor.run { model.updateServerStatus(status) }
            },
            connectivityMonitor: TelemetryConnectivityMonitor(),
            backgroundUploader: backgroundUploader
        )
        backgroundUploader.setCompletionHandler { [weak ingestor] metadata, outcome in
            await ingestor?.backgroundUploadCompleted(metadata: metadata, outcome: outcome)
        }
        self.model = model
        self.backgroundUploader = backgroundUploader
        self.garmin = GarminConnectionService(
            model: model,
            ingestor: ingestor,
            serverConfiguration: configuration
        )
    }

    func start() {
        guard startupTask == nil else { return }
        startupTask = Task { [backgroundUploader, garmin, model] in
            do {
                try await backgroundUploader.start()
                garmin.start()
                return true
            } catch {
                model.ingestFailed(error)
                model.record("Startup blocked until protected telemetry cleanup succeeds")
                return false
            }
        }
    }

    func applicationBecameActive() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let startupTask = self.startupTask, await !startupTask.value {
                self.startupTask = nil
            }
            self.start()
            guard let startupTask = self.startupTask else { return }
            if await startupTask.value { self.garmin.applicationBecameActive() }
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            model.persistDiagnostic("scene_active")
            applicationBecameActive()
        case .inactive:
            model.persistDiagnostic("scene_inactive")
        case .background:
            model.persistDiagnostic("scene_background")
        @unknown default:
            model.persistDiagnostic("scene_unknown")
        }
    }
}
