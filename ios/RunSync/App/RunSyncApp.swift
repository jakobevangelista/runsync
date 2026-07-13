import SwiftUI

@main
struct RunSyncApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppContainer.shared.model
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            StatusView(model: model, garmin: AppContainer.shared.garmin)
                .onOpenURL { url in
                    _ = AppContainer.shared.garmin.handleAuthorizationCallback(
                        url,
                        sourceApplication: nil
                    )
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { AppContainer.shared.garmin.retryUploads() }
                }
        }
    }
}
