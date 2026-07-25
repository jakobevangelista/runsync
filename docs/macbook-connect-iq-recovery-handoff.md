# MacBook Handoff: Connect IQ Transport Recovery

## Purpose

Build, install, and physically verify the iOS recovery implementation that
repairs a wedged Garmin Connect IQ app-message stream without ending the Garmin
activity.

The implementation is based on merged `master` commit `8e74040a` and is pushed
to the `connect-iq-transport-recovery-implementation` bookmark.

The Linux workspace can parse the Swift source and run the server/web tests, but
only macOS with Xcode can type-check the Garmin binary SDK, run the iOS tests,
sign the app, and exercise the real iPhone/watch BLE path.

## What Changed

- RunSync explicitly unregisters old app-message and device-event listeners
  before registering replacements.
- Every replacement receives a visible registration generation.
- `Recover & Retry` now performs Connect IQ transport repair in parallel with
  capture/session/upload recovery.
- Tier 1 replaces the app-message subscription.
- Tier 2 replaces both device-event and app-message registrations.
- Recovery succeeds only after a new valid `receivedMessage` callback.
- Failed automatic recovery backs off and eventually requests fresh Garmin
  authorization.
- A stale active stream is checked while RunSync is foreground/runnable.
- A watch reconnect schedules a receipt check even when the scene is
  backgrounded; actual execution remains subject to iOS scheduling.
- App status now separates `Watch`, `Data field`, `App messages`,
  `Registration`, and `Transport repair`.
- The test build identifies itself as iOS build `1.0 (2)`.

The watch sender is unchanged. It still keeps only the newest useful sample, so
live telemetry resumes after repair but samples superseded during the outage
are not replayed.

## Important Safety Rules

- Do not uninstall RunSync before collecting diagnostics. Uninstalling can
  remove the local telemetry archive, cached Garmin device, and diagnostic
  timeline.
- Install the new build over the existing app using the same bundle ID and
  signing team.
- Do not end or restart the Garmin activity during a recovery test.
- Do not use force-quit for the first outage test. First prove normal
  foreground/background recovery.
- Garmin authorization, app-status success, and `Watch: Ready` are not recovery.
  Require an increasing `Received` count.

## 1. Get the Bookmark

From the MacBook checkout:

```sh
jj git fetch --remote origin
jj bookmark list connect-iq-transport-recovery-implementation
jj new connect-iq-transport-recovery-implementation@origin
jj log -r '@ | @-' --no-graph
```

Confirm the recovery commit's parent is merged `master`, not the old PR head:

```sh
jj log -r 'connect-iq-transport-recovery-implementation@origin-'
```

Expected parent description:

```text
Merge pull request #2 from jakobevangelista/telemetry-transport-observability-implementation
```

If the remote bookmark does not appear after fetching, stop rather than
creating a similarly named bookmark from `master`; verify the configured
`origin` first.

## 2. Regenerate and Resolve

```sh
cd ios
xcodegen generate
xcodebuild -resolvePackageDependencies \
  -project RunSync.xcodeproj \
  -scheme RunSync
```

Confirm Swift Package Manager resolves Garmin Connect IQ Companion SDK `1.8.0`.

Because `xcodegen generate` rewrites the checked-in project, inspect the result:

```sh
cd ..
jj status
jj diff --summary
```

`CURRENT_PROJECT_VERSION = 2` must remain in both Debug and Release
configurations. Project generation should not create unrelated source changes.

## 3. Run the iOS Test Suite

List available simulator names if necessary:

```sh
xcrun simctl list devices available
```

Then run:

```sh
cd ios
xcodebuild test \
  -project RunSync.xcodeproj \
  -scheme RunSync \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro"
```

Use another available iOS 26 simulator if that exact device is unavailable.

The new tests must cover:

- complete unregister-before-register ordering;
- duplicate device-ID collapse;
- repair only for a stale, expected stream;
- bounded 15/30/60/120-second repair backoff.

### Compile checkpoints

Pay particular attention to the Garmin SDK adapter calls:

```text
unregister(forAppMessages:delegate:)
unregister(forDeviceEvents:delegate:)
```

These names follow Garmin's Objective-C declarations as imported by Swift. If
Xcode reports a different imported name, stop and preserve the exact compiler
diagnostic. Do not remove unregistration to make the build pass.

## 4. Install Without Deleting Existing Data

1. Open `ios/RunSync.xcodeproj`.
2. Select the RunSync scheme.
3. Select the paired iPhone.
4. Confirm team `W6MVZPAS4Y` and bundle ID
   `com.jakobevangelista.runsync`.
5. Build and run from Xcode.
6. Accept Bluetooth permission if iOS asks.
7. Do not remove the old app manually first.

On the status screen require:

```text
iOS build          1.0 (2)
Authorization      Authorized
Registration       Generation 1 or higher
```

The existing watch build may still display:

```text
a7457b656cb4
```

That is expected; this change is iOS-only.

## 5. Establish a Clean Baseline

Do this before inducing any failure:

1. Open Garmin Connect and confirm the Forerunner is connected.
2. Open RunSync.
3. Enable `Store live activity and location`.
4. Authorize the watch if necessary.
5. Open native Run on the watch and display the RunSync field.
6. Start an activity.
7. Keep RunSync foregrounded for at least two minutes.

Require all of the following:

```text
Watch              Ready
Data field         Installed
App messages       Receiving
Watch receipt      Current
Received           increasing
Watch Q            increasing
Watch T/F          zero during healthy delivery
```

The phone's received count should increase roughly once per second. It must not
increase twice per watch sequence; that would indicate duplicate delegate
delivery.

If this baseline fails, do not proceed to outage testing. Capture diagnostics
and resolve installation/authorization first.

## 6. Healthy Manual-Recovery Check

While the activity and receipts are healthy:

1. Record the current registration generation and received count.
2. Press `Recover & Retry` once.
3. Keep the data field visible.

If a receipt arrives during the initial observation window, the result may be:

```text
Watch: Recovered
```

without increasing the registration generation. That is correct: an already
healthy stream does not need forced churn.

Capture/session/upload results are reported separately. A server error must not
turn a healthy app-message result into a transport failure.

## 7. Primary Bluetooth Recovery Test

1. Keep the same Garmin activity running.
2. Record UTC time, received count, watch Q/T/F, and registration generation.
3. Put RunSync in the background normally; do not swipe it away.
4. In iPhone Settings, turn Bluetooth fully off for 60 seconds.
5. Confirm watch failures rise while Bluetooth is off.
6. Turn Bluetooth back on.
7. Confirm Garmin Connect reports the watch connected.
8. Bring RunSync to the foreground if it does not resume in the background.
9. Wait up to 60 seconds.

Expected recovery:

- `Registration` increases if a rebind is needed.
- `App messages` transitions through `Repairing (tier 1)` or
  `Repairing (tier 2)`.
- `Received` begins increasing again.
- `Watch receipt` returns to `Current`.
- `Transport repair` becomes `Recovered`.
- The Garmin activity remains the same activity.
- A sequence jump is acceptable because the watch is latest-value-only.

Do not treat these as recovery by themselves:

- watch failures returning to zero;
- Garmin Connect saying connected;
- `Watch: Ready`;
- `Data field: Installed`.

## 8. Reproduce the Original Wedged Shape

If the phone again shows disconnected/unavailable while Garmin Connect is
connected and watch Q increases with T/F at zero:

1. Leave the Garmin activity running.
2. Record the received count, receipt age, registration generation, and watch
   Q/T/F.
3. Press `Recover & Retry` once.
4. Observe for up to 45 seconds.

The button now performs:

```text
1-second observation
Tier 1 app-message unregister/register
20-second receipt wait
Tier 2 device + app unregister/register
20-second receipt wait
```

Pass:

- a new receipt arrives;
- `Received` increases;
- result says `Watch: Recovered`.

Escalation:

- if both tiers fail, RunSync displays `Garmin authorization required`;
- press `Authorize Garmin Watch`;
- choose the same watch;
- require a new receipt after authorization.

Authorization parsing alone is not a pass.

## 9. Force-Quit and Reboot Tests

Run these only after the primary test passes.

### Force-quit

1. Keep the activity running.
2. Force-quit RunSync.
3. Wait at least 60 seconds.
4. Reopen RunSync manually.
5. Wait up to 60 seconds.

iOS is not expected to relaunch a force-quit Bluetooth app automatically.
Passing behavior is recovery after manual reopen without restarting the Garmin
activity.

### iPhone reboot

1. Keep the Garmin activity running if practical.
2. Reboot the iPhone.
3. Unlock the phone once after startup.
4. Open RunSync.
5. Confirm build `1.0 (2)`.
6. Wait up to 60 seconds for receipts.

Passing behavior is a clean registration generation and resumed receipts after
the app becomes runnable.

## 10. Endurance Tests

After forced-outage recovery works:

1. Run a 30-minute locked-screen activity past the previous six-to-seven-minute
   cutoff.
2. Repeat the previous route.
3. Run a different route or stationary test to separate elapsed time from
   location.
4. Run a two-hour locked/pocketed activity.
5. Repeat the Bluetooth-off/on cycle at least five times before attempting the
   full 20-cycle acceptance run.

Fail the test for:

- a permanent cutoff after foregrounding;
- continuous registration-generation growth while receipts are healthy;
- duplicate receipt callbacks;
- recovery reporting success without a new receipt;
- excessive battery drain or repeated repair loops;
- a new local activity ID created solely because transport disconnected.

## 11. Server Check

The merged observability client adds diagnostic payload fields. The deployed API
must include migration `002_watch_transport_diagnostics.sql` before judging
upload behavior.

Transport and upload are separate:

- increasing `Received` proves watch-to-iOS app-message delivery;
- increasing server rows/acknowledgements proves iOS-to-server delivery.

After the compatible API is deployed, press `Recover & Retry` once to clear the
old `request_malformed` upload block and retry the protected backlog.

## 12. Collect Evidence on Failure

Record:

- UTC timestamp;
- iOS build `1.0 (2)`;
- iOS version and iPhone model;
- Garmin Connect version;
- watch firmware and watch build;
- received count and receipt age;
- registration generation;
- app-message and repair status;
- watch Q/T/F;
- whether Tier 1, Tier 2, authorization, foreground, or reboot changed
  delivery.

In macOS Console, filter for:

```text
subsystem:com.jakobevangelista.runsync
```

To retrieve the durable diagnostic timeline:

1. Open Xcode's **Window > Devices and Simulators**.
2. Select the iPhone and RunSync.
3. Download the application container.
4. Preserve:

```text
AppData/Library/Application Support/RunSync/Diagnostics/garmin-events.ndjson
AppData/Library/Application Support/RunSync/Diagnostics/garmin-events.1.ndjson
```

The useful recovery events are:

```text
registration_replace_started
app_messages_unregistered
device_events_unregistered
device_events_registered
app_messages_registered
transport_repair_started
transport_repair_waiting_for_receipt
transport_receipt_during_repair
transport_repair_succeeded
transport_repair_failed
```

Do not share telemetry archive files containing location unless intentionally
needed.

## Acceptance Checklist

- [ ] Xcode project regenerates with build number 2.
- [ ] Garmin SDK 1.8.0 resolves.
- [ ] iOS simulator build and all unit tests pass.
- [ ] Existing app data survives installation.
- [ ] Device shows iOS build `1.0 (2)`.
- [ ] Baseline receives one stream without duplicates.
- [ ] Replacement logs unregister before register.
- [ ] Bluetooth off/on resumes receipts without ending the activity.
- [ ] `Recover & Retry` repairs the Connect IQ stream.
- [ ] Success is displayed only after a new receipt.
- [ ] Fresh authorization recovers if Tier 1 and Tier 2 fail.
- [ ] Force-quit recovers after manual reopen.
- [ ] Phone reboot recovers after unlock/open.
- [ ] Thirty-minute locked-screen run passes.
- [ ] Two-hour locked-screen run passes.
- [ ] Server accepts diagnostic payloads and drains the protected backlog.
