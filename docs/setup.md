# Physical-device setup

## Current local state

- Xcode 26.4.1 and Swift 6.3 are installed.
- OpenJDK 17 and XcodeGen 2.45.4 are installed through Homebrew.
- Garmin Connect IQ Companion SDK 1.8.0 resolves through Swift Package Manager.
- The iOS simulator build and unit tests pass.
- Apple team `W6MVZPAS4Y` is configured in `ios/project.yml`.
- The signed iOS app has been built and installed on the paired iPhone 17 Pro.
- Garmin Connect IQ SDK Manager, the Monkey C compiler, and a Garmin developer key are not installed yet.

## iPhone setup

1. Keep the iPhone unlocked while Xcode mounts its developer disk image.
2. Enable Developer Mode under **Settings > Privacy & Security > Developer Mode** if iOS requests it.
3. Trust the Mac if iOS presents **Trust This Computer**.
4. Open RunSync and allow Bluetooth access.
5. Turn on **Store live activity and location**. It is intentionally off by default because samples include precise location.
6. Install Garmin Connect from the App Store if it is not already installed.
7. Pair and sync the Forerunner 965 in Garmin Connect before pressing **Authorize Garmin Watch** in RunSync.

Regenerate the Xcode project after changing `ios/project.yml`:

```sh
cd ios
xcodegen generate
```

Run tests:

```sh
xcodebuild test \
  -project RunSync.xcodeproj \
  -scheme RunSync \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro"
```

The generated project is checked in so Xcode can be opened directly at `ios/RunSync.xcodeproj`.

## Garmin SDK setup requiring user acceptance

Downloading Garmin's SDK signifies acceptance of Garmin's Connect IQ Developer Agreement. Complete this step manually:

1. Open [Garmin Get the SDK](https://developer.garmin.com/connect-iq/sdk/).
2. Choose **Accept & Download for Mac** under **Install the SDK Manager**.
3. Open the downloaded DMG and launch Connect IQ SDK Manager.
4. Complete first-time setup.
5. Install the current Connect IQ SDK, currently 9.2.0, and the Forerunner 965 device files.
6. Select the new SDK as the active SDK when prompted.

The SDK Manager normally installs SDKs below:

```text
~/Library/Application Support/Garmin/ConnectIQ/Sdks/
```

## Garmin developer key

The `.prg` must be signed with a persistent developer key. Do not commit this key.

Recommended setup:

1. Install Visual Studio Code if needed.
2. Install Garmin's official **Monkey C** extension.
3. Run **Monkey C: Verify Installation** from the command palette.
4. Run **Monkey C: Generate a Developer Key**.
5. Store it outside the repository, for example at `~/.garmin/developer_key.der`.
6. Back it up securely. Replacing the key changes developer identity and complicates upgrades.

## Build the Data Field

With the active SDK `bin` directory on `PATH`:

```sh
cd watch
mkdir -p bin
monkeyc \
  -d fr965 \
  -f monkey.jungle \
  -o bin/RunSync.prg \
  -y "$HOME/.garmin/developer_key.der"
```

Simulator launch:

```sh
connectiq
monkeyc \
  -d fr965 \
  -f simulator.jungle \
  -o bin/RunSync-simulator.prg \
  -y "$HOME/.garmin/developer_key.der"
monkeydo bin/RunSync-simulator.prg fr965
```

The simulator build uses a deterministic local transport because Garmin's simulator companion messaging is Android-only. It completes transmissions immediately by default and supports injected failures for sender recovery testing, but it cannot validate the iPhone BLE path.

Compile and run the deterministic sender tests with:

```sh
monkeyc -t \
  -d fr965 \
  -f test.jungle \
  -o bin/RunSync-tests.prg \
  -y "$HOME/.garmin/developer_key.der"
monkeydo bin/RunSync-tests.prg fr965 -t
```

## Sideload onto the Forerunner 965

The Forerunner 965 exposes its files over MTP, which macOS Finder generally does not browse.

1. Install [OpenMTP](https://openmtp.ganeshrvel.com/) if Finder cannot access the watch.
2. Fully quit Garmin Express because only one application can own the MTP connection.
3. Connect the watch with a data-capable USB cable.
4. Select MTP/file-transfer mode on the watch if prompted.
5. Copy `watch/bin/RunSync.prg` into `GARMIN/APPS/` on the watch.
6. Eject/disconnect the watch cleanly and restart it if the field is not processed immediately.

Garmin Express installs Store applications but does not provide a reliable arbitrary `.prg` sideload action.

## Add RunSync to native Run

On the Forerunner 965:

1. Hold **UP/MENU**.
2. Open **Activities & Apps > Run > Run Settings > Data Screens**.
3. Select an existing screen or choose **Add New**.
4. Select a field position.
5. Choose **Connect IQ Fields > RunSync**. The exact category label can vary by firmware.
6. Return to Run and leave the screen containing RunSync visible for the first test.

## First end-to-end test

1. Open Garmin Connect and confirm the watch is connected.
2. Open RunSync on the iPhone.
3. Allow Bluetooth and enable telemetry storage.
4. Press **Authorize Garmin Watch**, choose the Forerunner 965 in Garmin Connect, and return to RunSync.
5. Confirm RunSync changes from **Connected, discovering** to **Ready**.
6. Confirm the Data Field status is **Installed**.
7. Open Run on the watch and display RunSync.
8. Wait for RunSync's received count to increase.
9. Start with a five-minute foreground-phone test.
10. Follow with a 30-minute locked-screen test after foreground delivery is stable.

## Important identifiers

```text
Connect IQ manifest UUID: C2ABF013-EA3B-49DD-82E6-FC0B87C27474
Development Store UUID:   3B320CDC-AD38-47D4-BFCB-4F6CFBC32C96
iOS bundle ID:            com.jakobevangelista.runsync
iOS callback scheme:      runsync
```

The development Store UUID is a stable placeholder for the unpublished sideloaded app. BLE message routing uses the manifest UUID. Replace the Store UUID only if RunSync later receives a real Connect IQ Store listing UUID.
