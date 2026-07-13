import Foundation

@MainActor
final class AppContainer {
    static let shared = AppContainer()

    let model: AppModel
    let garmin: GarminConnectionService

    private init() {
        let model = AppModel()
        let archive = TelemetryArchive()
        let configuration = ServerConfigurationStore()
        let sink = HTTPTelemetrySink(configuration: configuration)
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: InstallationIdentity.loadOrCreate()
        )
        self.model = model
        self.garmin = GarminConnectionService(
            model: model,
            ingestor: ingestor,
            serverConfiguration: configuration
        )
    }
}
