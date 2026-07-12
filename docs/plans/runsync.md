# RunSync Watch-to-iPhone Telemetry

## Implementation specification

**Status:** Ready for implementation of the watch-to-phone MVP  
**Research date:** 2026-07-12  
**Watch:** Garmin Forerunner 965  
**Watch platform:** Connect IQ / Monkey C  
**Phone platform:** iOS 17+ / Swift  
**Connect IQ Mobile SDK:** iOS 1.8.0  
**Server:** Deferred; represented by an in-app mock sink

## 1. Product decisions

The following decisions are approved for the first implementation:

- RunSync is a live-state relay, not an authoritative activity recorder.
- An occasional missing one-second sample is acceptable. Garmin's native activity recording remains authoritative.
- The watch uses a Connect IQ Data Field inside Garmin's native Run activity.
- The phone app must be opened before each run.
- The supported background case is normal iOS suspension while the screen is locked.
- Force-quit, reboot, crash recovery, and recovery after iOS terminates the process are not first-release guarantees.
- The minimum phone deployment target is iOS 17.
- Cadence is transported exactly as Garmin supplies it: revolutions per minute (RPM).
- The iOS MVP displays status, archives samples locally, and sends them to an in-process mock server sink.
- No production HTTP endpoint, authentication, or server implementation is in scope yet.
- The first release targets only the Forerunner 965.

## 2. Terminology and applications

Only two applications are built in this repository:

1. **RunSync Connect IQ Data Field**
   A Monkey C app installed on the Forerunner 965 and added to a native Run activity data screen.

2. **RunSync iOS companion**
   A Swift app that uses Garmin's Connect IQ Companion App SDK to authorize the watch and receive app messages.

Garmin Connect is Garmin's existing iOS application. RunSync does not build or modify it. Garmin Connect is used for Garmin account/device pairing, Connect IQ app management, and the initial companion authorization flow.

## 3. MVP architecture

```text
Garmin native Run activity
  -> RunSync Data Field compute(Activity.Info), nominally once/second
  -> latest-value-wins Communications.transmit()
  -> Garmin Connect IQ Companion SDK over BLE
  -> validate Foundation object graph on iPhone
  -> append envelope to a per-run NDJSON archive
  -> submit a small batch to an in-process mock telemetry sink
  -> append exact mock acknowledgements to an acknowledgement journal
  -> update SwiftUI status
```

The BLE payload is a Monkey C dictionary. It is not JSON on the wire. Garmin's iOS SDK bridges the payload into Foundation objects such as `NSDictionary` and `NSNumber`.

## 4. Verified platform constraints

### 4.1 Forerunner 965

The Forerunner 965 device reference reports:

- Connect IQ API level 5.2
- Data Field support
- 262,144 bytes of Data Field memory
- 65,536 bytes of background-process memory
- Communications support

The project shall use a minimum Connect IQ API level of 5.0 because Garmin added Communications support for foreground Data Fields in API 5.0.

`ByteArray` transmission was added in Connect IQ API 6.0 and is therefore unavailable on the Forerunner 965. The protocol shall use a dictionary containing supported primitive values.

### 4.2 Foreground Data Field meaning

Garmin documents Communications as available to a **foreground Data Field**. Garmin does not clearly document whether this means that the field must be on the currently visible native activity page.

Consequently:

- `compute(info)` is the sampling entry point.
- `onUpdate(dc)` is display-only and shall not drive telemetry.
- The product initially instructs the user to keep the RunSync field visible.
- Visible field, another data page, map, and music screens are separate physical-device tests.
- If testing proves hidden-page delivery reliable, the user instruction may be relaxed.
- The implementation shall not infer visibility from `onHide()`; Garmin's documented Data Field lifecycle does not provide a reliable visibility contract for this purpose.

### 4.3 Sampling rate

Garmin documents `DataField.compute(info)` as being called once per second. This is the nominal generation rate, not a real-time deadline or a guarantee of one delivered phone message per second.

`compute()` and `onUpdate()` are asynchronous, and no ordering between them shall be assumed.

### 4.4 iOS background behavior

The iOS target enables the Core Bluetooth central background mode. After the user opens RunSync and establishes the Garmin connection, iOS may resume the suspended app to process Bluetooth events while the screen is locked.

The implementation must not claim:

- continuous background execution;
- exact one-second callback delivery;
- automatic relaunch after force-quit;
- reliable relaunch after reboot, crash, or system process eviction;
- completion of an ordinary HTTPS request during every BLE wake;
- that supplying a restoration identifier alone guarantees restoration.

Garmin SDK 1.8.0 accepts a Core Bluetooth restoration identifier, but its published implementation only logs `willRestoreState` and does not expose or process the restored peripheral list for the app.

Apple's iOS 26 restoration guidance further restricts process relaunch to accessories configured through AccessorySetupKit. Garmin's public SDK does not document that integration. Normal suspended-in-memory locked-screen operation is therefore the MVP acceptance target; process relaunch is not.

### 4.5 Physical hardware is required

The Connect IQ simulator can validate Data Field logic and payload construction. It cannot validate the production iPhone BLE path. End-to-end and locked-screen tests require the actual Forerunner 965 and an iPhone.

## 5. Repository layout

```text
runsync/
├── docs/
│   └── plans/
│       └── runsync.md
├── watch/
│   ├── manifest.xml
│   ├── monkey.jungle
│   ├── source/
│   │   ├── RunSyncApp.mc
│   │   ├── RunSyncField.mc
│   │   ├── TelemetryEncoder.mc
│   │   └── TelemetrySender.mc
│   └── resources/
│       ├── drawables/
│       ├── layouts/
│       └── strings/
└── ios/
    └── RunSync/
        ├── App/
        ├── Garmin/
        ├── Telemetry/
        ├── Storage/
        ├── MockIngest/
        └── UI/
```

Keep the watch implementation small. Separate files are justified only for the asynchronous sender and payload encoder; do not create a large domain layer on the watch.

## 6. Connect IQ Data Field

### 6.1 Manifest

Create a Data Field application targeting only `fr965`. Keep the generated application UUID stable for the lifetime of the project.

Required permissions:

```xml
<iq:permissions>
    <iq:uses-permission id="Communications"/>
    <iq:uses-permission id="Background"/>
    <iq:uses-permission id="Positioning"/>
</iq:permissions>
```

Important details:

- Garmin's manifest documentation requires `Background` in addition to `Communications` when Communications is used by a Data Field.
- `Positioning` is required for `Activity.Info.currentLocation` to be populated.
- No background service will be implemented. The permission is a Communications requirement, not a plan to sample in a `ServiceDelegate`.
- A Connect IQ background process cannot replace the Data Field: temporal events have multi-minute scheduling and do not receive native Run `Activity.Info` at one-second cadence.

Restrict the field to running activities using the current SDK-generated manifest schema and running activity filter.

### 6.2 Data source

Implement:

```monkeyc
function compute(info as Activity.Info) as Void
```

Read these nullable fields when present:

| `Activity.Info` field | Meaning | Garmin unit | Wire encoding |
| --- | --- | --- | --- |
| `timerState` | Native timer state | Garmin enum | RunSync integer enum |
| `startTime` | Activity start time | `Time.Moment` | Unix epoch seconds |
| `elapsedTime` | Elapsed activity time | milliseconds | integer milliseconds |
| `elapsedDistance` | Distance | metres | rounded decimetres |
| `currentSpeed` | Current speed | metres/second | rounded millimetres/second |
| `currentHeartRate` | Heart rate | beats/minute | integer BPM |
| `currentCadence` | Cadence | revolutions/minute | integer RPM |
| `currentLocation` | GPS location | `Position.Location` | rounded microdegrees |
| `currentLocationAccuracy` | Position quality | Garmin enum | mapped integer enum |
| `altitude` | Current altitude | metres | rounded decimetres |
| `totalAscent` | Accumulated ascent | metres | rounded integer metres |

Do not invent precision. In particular, total ascent is transported as metres, not decimetres.

### 6.3 Feature and null handling

Every optional value must be checked for API availability and nullability before use.

```monkeyc
if (info has :currentHeartRate && info.currentHeartRate != null) {
    payload["hr"] = info.currentHeartRate;
}
```

Rules:

- Omit an unavailable field rather than sending zero.
- Never send one coordinate without the other.
- Validate latitude and longitude ranges before encoding.
- Negative scaled coordinates must be rounded correctly, not accidentally truncated toward zero.
- Continue sending timer, distance, and sensor state if GPS is unavailable.
- Preserve raw Garmin cadence RPM. Do not multiply by two on the watch.
- Do not reuse an old sensor value as though it were current.

### 6.4 Canonical wire payload

Use a flat dictionary with short string keys and integer values:

```text
{
  "v": 1,
  "q": 175,
  "st": 1,
  "rt": 1783884160,
  "tm": 523000,
  "d": 184260,
  "sp": 3710,
  "hr": 154,
  "cad": 87,
  "lat": 37774920,
  "lon": -122419380,
  "gps": 4,
  "alt": 382,
  "asc": 22
}
```

Field definitions:

| Key | Required | Meaning | Encoding |
| --- | --- | --- | --- |
| `v` | yes | Protocol version | `1` |
| `q` | yes | Watch generation sequence | signed 32-bit integer |
| `st` | yes | Normalized timer state | RunSync enum |
| `rt` | no | Garmin activity start | Unix epoch seconds |
| `tm` | no | Elapsed time | milliseconds |
| `d` | no | Distance | decimetres |
| `sp` | no | Speed | millimetres/second |
| `hr` | no | Heart rate | BPM |
| `cad` | no | Raw Garmin cadence | RPM |
| `lat` | no | Latitude | degrees times 1,000,000 |
| `lon` | no | Longitude | degrees times 1,000,000 |
| `gps` | no | Normalized GPS quality | RunSync enum |
| `alt` | no | Altitude | decimetres |
| `asc` | no | Total ascent | metres |

All expected values fit a Connect IQ signed 32-bit `Number`. Do not add formatted strings, historical arrays, credentials, or debug logs.

### 6.5 State mapping

Map Garmin timer states explicitly rather than exposing Garmin enum ordinals as protocol values:

```text
0 = unknown/waiting
1 = running
2 = paused
3 = stopped
4 = ended
```

The sample's canonical state comes from `Activity.Info.timerState` when available. Lifecycle callbacks update the fallback state and diagnostics but are not the sole source of truth.

Implement and test:

```monkeyc
onTimerStart()
onTimerPause()
onTimerResume()
onTimerStop()
onTimerReset()
```

Important Garmin semantics:

- `onTimerPause()` includes Garmin's paused state, such as auto-pause.
- Manual Stop invokes `onTimerStop()`.
- Returning from stopped to running can invoke `onTimerStart()`, so `onTimerStart()` must not blindly create a new run or reset sequence state.
- `onTimerReset()` means the activity ended.
- A field loaded into an activity already in progress may immediately receive a lifecycle callback.

Each ordinary sample carries the current state, so losing a one-off lifecycle transmission does not permanently lose state.

### 6.6 Sequence and run identity

`q` increments when a sample is generated, whether or not it is delivered. Gaps are expected and diagnostic.

The watch does not generate a random session ID in the MVP. A small random number adds collision risk without providing a durable identity. When available, `Activity.Info.startTime` supplies a stable activity-start hint in `rt`; the iOS app still owns the canonical local run UUID.

The iOS run assembler primarily uses Garmin device identity plus `rt`, timer transitions, elapsed-time regression, and activity end to delimit local recordings. A sequence reset without a changed `rt` or regressed elapsed time indicates a watch field-process restart and must not automatically split the activity. Ambiguous transitions must be logged and covered by physical-device tests before this logic is treated as stable.

### 6.7 Sender state machine

`Communications.transmit(content, options, listener)` is asynchronous. The listener exposes parameterless `onComplete()` and `onError()` methods; it does not provide a usable error code. Do not implement `lastErrorCode` from this callback.

Maintain only:

```text
inFlight: Boolean
pending: Dictionary or null
generatedCount: Number
completedCount: Number
errorCount: Number
droppedPendingCount: Number
lastAttemptMonotonic: Number or null
lastCompleteMonotonic: Number or null
```

Algorithm:

1. If no transmission is in flight, transmit the new payload with empty options.
2. If a transmission is in flight, replace `pending` with the new payload.
3. Replacing an existing pending payload increments `droppedPendingCount`.
4. On completion, clear `inFlight` and immediately send the newest pending payload, if any.
5. On error, clear `inFlight` and send the newest pending payload, if any.
6. Do not retry the failed stale payload. Newly generated current state is the retry mechanism.
7. Never create an unbounded watch queue.

No exponential backoff or Connect IQ timer is needed for the first implementation. The async operation itself serializes attempts, and fresh `compute()` samples provide retry opportunities. Add backoff only if physical testing shows rapid failed operations consuming material battery or CPU.

Garmin publishes communication error constants, but the `ConnectionListener` callback does not pass one. The UI can distinguish recent completion from delayed/no completion; it cannot truthfully display a detailed BLE failure code.

### 6.8 Watch display

The field displays transport health rather than duplicating Garmin's Run metrics.

Minimum states:

```text
READY
LIVE
PAUSED
WAIT GPS
DELAYED
NO PHONE
ENDED
```

Display:

- normalized state;
- seconds since the most recent successful transmit callback;
- sequence number in a diagnostic layout;
- a compact error indicator after recent transmit failures.

A successful callback means only that the Connect IQ communication operation completed. It does not prove that iOS persisted the sample, the mock sink acknowledged it, or a future server accepted it.

## 7. iOS companion

### 7.1 Project configuration

Create a SwiftUI iOS application with an application delegate attached using `UIApplicationDelegateAdaptor` for Garmin initialization and callback URL handling.

Add Garmin's official package:

```text
https://github.com/garmin/connectiq-companion-app-sdk-ios
```

Pin version `1.8.0` initially. The package contains a binary `ConnectIQ.xcframework` and supports Swift Package Manager.

Add to Other Linker Flags:

```text
-ObjC
```

Required configuration:

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>runsync</string>
        </array>
    </dict>
</array>

<key>LSApplicationQueriesSchemes</key>
<array>
    <string>gcm-ciq</string>
</array>

<key>NSBluetoothAlwaysUsageDescription</key>
<string>RunSync uses Bluetooth to receive live activity telemetry from your Garmin watch.</string>

<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
</array>
```

Also provide `CFBundleDisplayName`. `NSBluetoothPeripheralUsageDescription` is not required because RunSync targets iOS 17 rather than a version earlier than iOS 13.

Use a bundle-specific, stable restoration identifier, for example:

```text
com.jakobevangelista.runsync.garmin-central
```

The final bundle ID and URL scheme must be globally appropriate before implementation; changing the scheme later requires matching changes to Garmin initialization and URL handling.

### 7.2 SDK initialization

Initialize once at application startup, before restoring cached devices or registering delegates:

```swift
ConnectIQ.sharedInstance().initialize(
    withUrlScheme: "runsync",
    uiOverrideDelegate: nil,
    stateRestorationIdentifier: "com.jakobevangelista.runsync.garmin-central"
)
```

The Garmin service must be strongly owned at application scope. SwiftUI view appearance and disappearance must not register or unregister the core message listener.

### 7.3 Authorization callback

Start authorization with:

```swift
ConnectIQ.sharedInstance().showDeviceSelection()
```

Garmin Connect presents its compatible paired-device selection and returns the complete authorized device set through the `runsync` callback URL.

The app delegate shall:

1. Require the expected URL scheme.
2. Validate Garmin Connect as the source application using Garmin's `IQGCMBundle` constant when supplied by iOS.
3. Call `parseDeviceSelectionResponse(from:)`.
4. Validate the bridged result as `[IQDevice]`.
5. Replace the entire persisted authorization set with this latest result; do not merge stale devices.
6. Register the returned Forerunner 965 and rebuild its `IQApp` instance.

### 7.4 Device persistence

`IQDevice` conforms to `NSSecureCoding`. Persist Garmin-returned devices using `NSKeyedArchiver` with `requiringSecureCoding: true` in Application Support.

Restore with an explicit allowed-class set that includes the collection classes, `IQDevice`, `UUID`/`NSUUID`, and required string classes. Decode failure means no cached authorization and must not crash startup.

Do not persist only a device UUID and synthesize a replacement `IQDevice`; that does not recreate or prove authorization.

At launch:

1. Initialize Garmin's SDK.
2. Securely unarchive authorized devices.
3. Register for each device's events.
4. Create the corresponding `IQApp`.
5. Register the long-lived app-message delegate.

### 7.5 Device readiness

Implement `IQDeviceEventDelegate`:

```swift
func deviceStatusChanged(_ device: IQDevice!, status: IQDeviceStatus)
func deviceCharacteristicsDiscovered(_ device: IQDevice!)
```

SDK 1.8.0 changed readiness semantics. `IQDeviceStatus_Connected` does not prove that Connect IQ communication is ready. Wait for `deviceCharacteristicsDiscovered(_:)` before treating the device as app-message ready or requesting app status.

Represent at least:

```text
unauthorized
bluetoothUnavailable
notFound
disconnected
connectedDiscovering
ready
appNotInstalled
receiving
stale
```

### 7.6 Connect IQ app identity

An `IQApp` requires three values in SDK 1.8.0:

```swift
let app = IQApp(
    uuid: manifestApplicationUUID,
    store: storeUUID,
    device: device
)
```

- `manifestApplicationUUID` is the stable UUID from `watch/manifest.xml`.
- `storeUUID` is a separate Connect IQ Store listing UUID.
- For a private, unpublished development build, use one stable placeholder store UUID and do not invoke Store-navigation APIs.
- Replace the placeholder with the real Store UUID if the field is later published.

Do not use the stale two-argument constructor shown in older Garmin prose documentation.

After `deviceCharacteristicsDiscovered`, call `getAppStatus` to report whether the Data Field is installed. A nil status means the operation failed or timed out; it is not equivalent to `isInstalled == false`.

### 7.7 Message registration and decoding

Register once per authorized watch/app pair:

```swift
ConnectIQ.sharedInstance().register(
    forAppMessages: app,
    delegate: garminService
)
```

Implement:

```swift
func receivedMessage(_ message: Any!, from app: IQApp!)
```

The callback may arrive on a queue not controlled by RunSync. It must do minimal synchronous work and hand the value to an actor or serial ingestion queue.

Decoder rules:

- Require a dictionary root with string keys.
- Read numeric values as `NSNumber`.
- Reject Core Foundation booleans masquerading as integer `NSNumber` values.
- Check integral representation and range before conversion.
- Require supported protocol version, sequence, and state.
- Require latitude and longitude together and validate their ranges.
- Ignore unknown keys for forward compatibility.
- Reject a malformed required field rather than partially guessing its meaning.
- Preserve missing optional fields as nil.
- Do not pass the SDK callback directly to `JSONDecoder`.

### 7.8 Swift telemetry model

```swift
struct TelemetrySample: Codable, Sendable {
    let protocolVersion: Int
    let sequence: Int
    let state: ActivityState
    let activityStartEpochSeconds: Int?
    let elapsedTimeMilliseconds: Int?
    let distanceDecimeters: Int?
    let speedMillimetersPerSecond: Int?
    let heartRateBPM: Int?
    let cadenceRPM: Int?
    let latitudeMicrodegrees: Int?
    let longitudeMicrodegrees: Int?
    let gpsQuality: GPSQuality?
    let altitudeDecimeters: Int?
    let totalAscentMeters: Int?
}

struct TelemetryEnvelope: Codable, Sendable, Identifiable {
    let id: UUID
    let installationID: UUID
    let localRunID: UUID
    let phoneReceivedAt: Date
    let garminDeviceIdentifier: UUID
    let appVersion: String
    let sample: TelemetrySample
}
```

The installation ID is generated once and stored locally. It is not a secret. The local run ID is generated by iOS and identifies the archive. Each envelope gets a stable record UUID for future exact acknowledgement and idempotency.

### 7.9 Ingestion ordering

For every valid message:

```text
decode
-> assign local run and envelope IDs
-> append and sync to archive
-> update in-memory latest state
-> offer archived envelope to mock uploader
-> return
```

Persistence occurs before mock acknowledgement. A failed archive append must increment a visible error count and must not be reported as accepted by the mock sink.

## 8. Local archive

### 8.1 Format

Use one newline-delimited JSON file per local run in Application Support:

```text
Application Support/RunSync/Runs/<localRunID>/samples.ndjson
Application Support/RunSync/Runs/<localRunID>/mock-acks.ndjson
Application Support/RunSync/Runs/<localRunID>/metadata.json
```

This is intentionally simpler than Core Data, SwiftData, SQLite, or GRDB. At one sample per second, files remain small and are directly inspectable during endurance testing.

### 8.2 File behavior

- Serialize all archive operations through one actor.
- Use file protection `.completeUntilFirstUserAuthentication` so an already-unlocked phone can append after the screen locks.
- Create directories with protection attributes before the run.
- Append one complete UTF-8 JSON object plus newline per record.
- Flush promptly after each received record; measure the battery cost before attempting grouped flushes.
- On recovery, ignore or truncate one partial final line caused by abrupt termination.
- Never log precise coordinates through `Logger`; coordinates exist only in the protected run archive unless explicitly exported in a later feature.

### 8.3 Run boundaries

The run assembler starts a local run when it receives a running sample not belonging to the current open run. It closes a run after an ended/reset state.

Because real Garmin callback ordering must be measured, also close or split on strongly indicative discontinuities:

- Garmin activity start time changes;
- elapsed time decreases materially;
- device identity changes;
- an explicit new-run action is taken in the iOS UI.

A sequence reset with a stable activity start and non-regressing elapsed time is recorded as a transport restart within the same local run.

Do not discard ambiguous samples. Archive them and record a boundary reason in metadata.

### 8.4 Retention

For the MVP, retain local run archives until the user deletes them. Provide a "Delete all local telemetry" action before broader distribution. Automatic age-based retention and export are deferred product decisions.

## 9. In-app mock sink

The mock sink exists to exercise the future pipeline shape, not to claim real networking reliability.

### 9.1 Contract

Submit batches of 1 to 3 archived envelopes. The mock sink:

1. waits for a configurable short latency, default 100 ms;
2. accepts each submitted envelope ID exactly once;
3. returns the exact set of accepted envelope IDs;
4. can inject deterministic timeout, transient failure, and rejection modes for testing;
5. never uses sequence `acceptedThrough` semantics.

Exact-ID acknowledgement is required because sequence gaps and out-of-order delivery are normal. A future server may acknowledge a highest contiguous sequence only if it actually tracks contiguity; merely observing sequence 178 does not prove 177 was accepted.

### 9.2 Durable mock acknowledgement

After a successful mock response, append acknowledged envelope IDs to `mock-acks.ndjson`. On launch, archive plus acknowledgement journal reconstructs accepted and pending records.

The raw sample archive is retained even after mock acknowledgement because it is the endurance-test artifact. A future production uploader may compact acknowledged records under a defined retention policy.

### 9.3 Triggering

Do not use a repeating background timer. Evaluate upload work when:

- a Garmin message is persisted;
- the previous mock submission completes;
- the app enters foreground;
- the user requests retry.

Only one mock submission may be in flight. The in-app mock does not require exponential backoff, but failure injection shall prove that archived data remains available for retry.

## 10. iOS user interface

Keep the UI to one operational status screen and one diagnostics screen.

### 10.1 Operational status

Show:

```text
Garmin authorization    Authorized / Action required
Watch                   Ready / Discovering / Disconnected
RunSync field           Installed / Missing / Unknown
Last sample             age or Never
Activity                Waiting / Running / Paused / Stopped
Local archive           Healthy / Error
Mock ingest             Current / Delayed / Error
Pending mock records    count
Current run             local run ID, abbreviated
```

Actions:

- Authorize or change Garmin device
- Retry app-status check
- Start a new local test recording if automatic boundary detection is uncertain
- Inject mock failure on/off in debug builds
- Delete all local telemetry

### 10.2 Pre-run instructions

Display:

```text
1. Open RunSync before the run.
2. Confirm the watch is Ready and samples are arriving.
3. Open Garmin Run and show the screen containing the RunSync field.
4. Start the activity.
5. Lock the iPhone normally. Do not force-quit RunSync.
```

The iOS app cannot prevent starting Garmin's native activity. It can only show readiness and warnings.

### 10.3 Diagnostics

Track without logging precise coordinates:

- messages received and rejected;
- last receive timestamp;
- sequence gaps, duplicates, and regressions;
- archive append successes and failures;
- mock submissions, acknowledgements, and failures;
- app foreground/background transitions;
- Garmin device-state transitions;
- time from phone receipt to archive completion;
- maximum observed receive gap.

## 11. Concurrency and lifecycle

Use one application-scoped Garmin bridge object for Objective-C delegate conformance and one Swift actor for telemetry ingestion/storage state.

Suggested ownership:

```text
RunSyncApp
  -> AppModel (@MainActor, observable UI state)
  -> GarminConnectionService (NSObject delegates, app lifetime)
  -> TelemetryIngestor actor
       -> RunArchive actor or actor-isolated implementation
       -> MockTelemetrySink actor
```

Rules:

- Never block the Garmin callback on UI work or simulated upload latency.
- The archive append completes before submission to the mock sink.
- Publish UI changes on the main actor.
- Do not add `Timer` for background liveness.
- Do not register listeners in SwiftUI `onAppear`.
- Do not assume delegate callbacks arrive on the main thread.

## 12. Testing plan

### 12.1 Watch unit and simulator tests

Validate:

- nullable field handling;
- rounding of positive and negative scaled numbers;
- coordinate bounds;
- timer and GPS state mapping;
- sequence increment on generation;
- one in-flight and one replaceable pending payload;
- no unbounded memory growth;
- an hour of simulated `compute()` calls;
- layouts for the FR965 display configurations used by the field.

Do not count simulator success as BLE validation.

### 12.2 iOS tests without Garmin hardware

Use captured Foundation object graphs to test:

- valid dictionary decoding;
- missing optionals;
- invalid types and boolean `NSNumber` rejection;
- integer range checks;
- paired-coordinate rules;
- unknown-key compatibility;
- NDJSON append and partial-last-line recovery;
- local run boundary heuristics;
- exact-ID mock acknowledgement;
- duplicate and out-of-order records;
- deterministic mock failures and retry.

### 12.3 Physical milestone 1: minimal message

Transmit only:

```text
{"v": 1, "q": n, "st": state}
```

Prove:

- Garmin authorization returns a cacheable `IQDevice`;
- `deviceCharacteristicsDiscovered` occurs;
- the iOS app identifies whether the Data Field is installed;
- foreground iPhone delivery works;
- sequence gaps can be measured;
- Bluetooth off/on and watch reconnection behavior are observable.

### 12.4 Physical milestone 2: telemetry

Add and validate one field at a time:

1. elapsed time and timer state;
2. distance;
3. heart rate;
4. raw cadence RPM;
5. speed;
6. location and GPS quality;
7. altitude;
8. total ascent.

Compare values with the native Garmin activity display. Specifically determine whether FR965 running cadence RPM corresponds to strides, cycles, or the user-facing cadence shown by Garmin. Preserve raw transport semantics regardless.

### 12.5 Physical milestone 3: screen matrix

Run each condition for at least five minutes:

| Watch screen | Phone state | Measure |
| --- | --- | --- |
| RunSync visible | foreground | baseline delivery |
| RunSync visible | locked | suspended delivery |
| another data page | locked | hidden-page behavior |
| map | locked | hidden-page behavior |
| music controls | locked | hidden-page behavior |

The result determines whether "keep RunSync visible" remains a hard instruction or only a conservative recommendation.

### 12.6 Physical milestone 4: lifecycle matrix

Test:

- start from waiting;
- manual pause/resume if supported by native flow;
- auto-pause/resume;
- Stop followed by resume;
- Stop followed by save;
- Stop followed by discard;
- add/load the field when an activity is already running;
- start a second activity without restarting the phone app.

Record every `Activity.Info.timerState` and Data Field lifecycle callback to establish actual FR965 ordering.

### 12.7 Locked-screen gates

Progress through:

1. 15 minutes foreground;
2. 30 minutes locked;
3. two hours locked;
4. four hours locked.

For each run, compare watch-generated sequences, iPhone archives, receive gaps, app lifecycle transitions, and battery use.

Initial targets, subject to measured feasibility:

- at least 95% of generated one-second samples received during a two-hour locked run;
- at least 95% of received samples archived within one second of callback delivery;
- no crash or unbounded memory growth over four hours;
- automatic continuation after normal lock/unlock and foreground/background transitions;
- no requirement to keep the iPhone screen on.

These are RunSync product gates, not Garmin or Apple guarantees.

### 12.8 Explicitly unsupported tests

Record behavior but do not block the MVP on:

- user force-quits RunSync;
- phone reboots during a run;
- iOS kills the process under memory pressure;
- app updates during a run;
- Garmin Connect or RunSync is uninstalled;
- watch restarts during a run.

The UI shall tell the user to reopen RunSync before the next activity after any such event.

## 13. Implementation milestones

### Milestone 1: project skeletons

- Generate the Connect IQ Data Field for `fr965`.
- Create the iOS 17 SwiftUI project.
- Add Garmin SDK 1.8.0 and required configuration.
- Freeze manifest app UUID, placeholder Store UUID, bundle ID, and callback scheme.

### Milestone 2: local watch field

- Display state and incrementing sequence.
- Encode nullable telemetry.
- Validate in the Connect IQ simulator.

### Milestone 3: foreground BLE

- Authorize the watch.
- Persist `IQDevice` securely.
- Wait for characteristics discovery.
- Receive minimal messages on a physical iPhone.
- Implement latest-value-wins watch sending.

### Milestone 4: durable iOS ingestion

- Decode the full protocol.
- Create local run IDs and envelope IDs.
- Append protected NDJSON files before any sink submission.
- Surface decoder and archive health.

### Milestone 5: mock ingest

- Submit small batches to the in-app mock sink.
- Journal exact acknowledgements.
- Inject failure and recover from the archive.

### Milestone 6: locked-screen proof

- Complete screen and lifecycle matrices.
- Pass 30-minute, two-hour, then four-hour locked tests.
- Document tested iPhone model and exact iOS version.

### Milestone 7: server contract design

Only after the watch-to-phone path is measured, define the real endpoint, authentication, privacy/retention, batching, retries, and acknowledgement semantics with the server implementation.

## 14. Deferred server requirements

No server code is part of this phase. The following facts must be preserved for later design:

- A future upload record already has a stable envelope UUID.
- Watch sequences can have gaps, duplicates, resets, and out-of-order arrival.
- HTTP delivery should be at least once and server writes idempotent.
- The server should acknowledge exact submitted envelope IDs unless it deliberately computes highest-contiguous sequence state.
- iOS must retain records until acknowledgement according to a defined retention policy.
- Ingest credentials belong in iOS Keychain, never on the watch or in source control.
- Production traffic must use HTTPS.
- Precise live location requires an explicit privacy model, including stream access, expiry, and possible start/end masking.
- Ordinary `URLSession` work initiated during a BLE wake is not guaranteed to finish before suspension.
- Background URL sessions are system-scheduled file transfers, not a guarantee of low-latency one-second livestream requests.

The eventual server design must answer:

- endpoint and request schema;
- authentication and token provisioning;
- exact acknowledgement contract;
- maximum acceptable live latency;
- whether old samples should catch up or be dropped after an outage;
- retention and deletion policy;
- public versus private stream identifiers;
- location masking and publication delay;
- maximum batch size and rate limits.

These decisions do not block the watch-to-phone MVP.

## 15. Rejected or deferred alternatives

### 15.1 Complete watch-side queue

Rejected for the live-state product. It increases memory and reconnection complexity while old positions lose livestream value. Garmin's native recording remains the complete activity source.

### 15.2 Core Data, SwiftData, SQLite, or GRDB

Deferred until real server delivery creates query, compaction, or migration needs. Per-run NDJSON is sufficient for MVP volume and better for endurance diagnostics.

### 15.3 Direct watch HTTP

`Communications.makeWebRequest()` is available to foreground Data Fields and can use a phone bridge or watch connectivity. It is not automatically simpler: it puts credentials, retries, request limits, and observability on the resource-constrained watch and may still depend on Garmin Connect.

Reconsider it only after a real endpoint exists and only as a measured comparison. It is not the MVP transport.

### 15.4 Connect IQ background service

Rejected. It does not receive native Run `Activity.Info` at one-second cadence and cannot provide this continuous stream.

### 15.5 Production uploader before server contract

Rejected. An invented endpoint and cumulative acknowledgement scheme would create rework and could lose gapped samples. The mock sink validates local flow without pretending to validate networking.

## 16. Acceptance criteria

The watch-to-phone MVP is complete when:

- the Data Field installs and runs on a Forerunner 965;
- Garmin's native Run activity remains the activity recorder;
- all selected nullable metrics are encoded with documented units;
- the watch never retains more than one in-flight and one pending payload;
- the iOS app authorizes and securely restores the selected watch;
- iOS waits for SDK 1.8.0 characteristics discovery before declaring readiness;
- malformed Foundation payloads cannot crash ingestion;
- each accepted message is archived before mock submission;
- the mock sink acknowledges exact envelope IDs and can recover from injected failure;
- the status UI clearly distinguishes authorization, device connection, communication readiness, recent telemetry, archive health, and mock status;
- actual visible/hidden watch-screen behavior is documented from hardware tests;
- a two-hour locked-screen test meets the provisional continuity target;
- a four-hour test has no crash or uncontrolled memory growth;
- documentation clearly states that force-quit and process relaunch are unsupported.

No claim about production server latency or delivery is made in this phase.

## 17. Authoritative references

### Garmin Connect IQ

- [Forerunner 965 device reference](https://developer.garmin.com/connect-iq/device-reference/fr965/)
- [Compatible devices](https://developer.garmin.com/connect-iq/compatible-devices/)
- [DataField API](https://developer.garmin.com/connect-iq/api-docs/Toybox/WatchUi/DataField.html)
- [Activity.Info API](https://developer.garmin.com/connect-iq/api-docs/Toybox/Activity/Info.html)
- [Communications API](https://developer.garmin.com/connect-iq/api-docs/Toybox/Communications.html)
- [ConnectionListener API](https://developer.garmin.com/connect-iq/api-docs/Toybox/Communications/ConnectionListener.html)
- [Manifest and permissions](https://developer.garmin.com/connect-iq/core-topics/manifest-and-permissions/)
- [Connect IQ Number](https://developer.garmin.com/connect-iq/api-docs/Toybox/Lang/Number.html)

### Garmin iOS Companion SDK

- [Official SDK repository](https://github.com/garmin/connectiq-companion-app-sdk-ios)
- [SDK 1.8.0 release](https://github.com/garmin/connectiq-companion-app-sdk-ios/releases/tag/1.8.0)
- [SDK Package.swift](https://github.com/garmin/connectiq-companion-app-sdk-ios/blob/1.8.0/Package.swift)
- [ConnectIQ.h](https://github.com/garmin/connectiq-companion-app-sdk-ios/blob/1.8.0/ConnectIQ.xcframework/ios-arm64/ConnectIQ.framework/Headers/ConnectIQ.h)
- [IQDevice.h](https://github.com/garmin/connectiq-companion-app-sdk-ios/blob/1.8.0/ConnectIQ.xcframework/ios-arm64/ConnectIQ.framework/Headers/IQDevice.h)
- [IQApp.h](https://github.com/garmin/connectiq-companion-app-sdk-ios/blob/1.8.0/ConnectIQ.xcframework/ios-arm64/ConnectIQ.framework/Headers/IQApp.h)
- [Official iOS example](https://github.com/garmin/connectiq-companion-app-example-ios)
- [Garmin iOS Mobile SDK guide](https://developer.garmin.com/connect-iq/core-topics/mobile-sdk-for-ios/)

### Apple

- [Core Bluetooth background processing](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
- [TN3115: Bluetooth state restoration app relaunch rules](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules)
- [Configuring background execution modes](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes)
- [NSBluetoothAlwaysUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothalwaysusagedescription)
- [FileProtectionType.completeUntilFirstUserAuthentication](https://developer.apple.com/documentation/foundation/fileprotectiontype/completeuntilfirstuserauthentication)
