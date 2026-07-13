# RunSync iOS

Generate the Xcode project and resolve Garmin's package:

```sh
xcodegen generate
xcodebuild -resolvePackageDependencies -project RunSync.xcodeproj -scheme RunSync
```

The app targets iOS 17 and uses Garmin Connect IQ Companion SDK 1.8.0. Before installing on an iPhone, select your Apple Development team for the RunSync target. Garmin authorization requires Garmin Connect to be installed and the Forerunner 965 to already be paired there.

Configure the telemetry server in the app's **Telemetry server** section. The base URL is stored in UserDefaults; the bearer token is stored in Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Production server URLs must use HTTPS (plain HTTP is accepted only for loopback development hosts).
