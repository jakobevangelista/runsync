import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppContainer.shared.start()
        return true
    }

    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        AppContainer.shared.garmin.handleAuthorizationCallback(
            url,
            sourceApplication: options[.sourceApplication] as? String
        )
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundTelemetryUploadManager.sessionIdentifier else {
            completionHandler()
            return
        }
        AppContainer.shared.backgroundUploader.handleEvents(completionHandler: completionHandler)
    }
}
