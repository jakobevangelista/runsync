# RunSync Telemetry Transport Observability Plan

## 1. Status

Proposed.

This plan covers three related changes:

1. attach an exact watch build identifier and bounded watch-transport diagnostics to telemetry;
2. make the iPhone receipt-health UI become visibly stale when watch messages stop;
3. persist privacy-safe iPhone application and Garmin BLE lifecycle events across process launches.

It complements `docs/plans/watch-transport-recovery.md` and
`docs/plans/telemetry-upload-recovery.md`. It does not replace either recovery
state machine.

## 2. Purpose

Make the next telemetry cutoff attributable from stored evidence instead of
requiring inference from the final server sample.

The system has three distinct delivery boundaries:

```text
watch compute
  -> Garmin Communications transmit result
  -> iPhone Connect IQ callback and local archive
  -> server acknowledgement
```

Current telemetry proves the last two timestamps only for samples that reached
the iPhone. It does not identify the watch binary, preserve watch timeout
counters, or retain the iPhone process and BLE lifecycle surrounding a gap. The
iPhone header also remains green forever after the first receipt, even when the
last receipt is hours old.

This plan adds enough bounded evidence to distinguish:

- a watch sender waiting for a missing Garmin callback;
- repeated watch timeout/error recovery attempts;
- a watch build that predates the recovery implementation;
- an iPhone BLE disconnect while the process remains alive;
- an iPhone process launch or foreground transition near recovery;
- healthy iPhone archival followed by delayed server upload;
- an otherwise healthy transport whose UI is merely displaying stale state.

## 3. Incident Evidence

The latest observed long activity delivered watch sequences `2` through `127`
normally, stopped delivering normal telemetry for 3 hours 42 minutes, and then
delivered terminal sequence `13468`.

The sequence advanced by 13,341 during approximately 13,340 seconds. The watch
therefore continued calling the data-field compute path while message delivery
was absent. Every sample that did reach the iPhone reached the server within
318 milliseconds.

Earlier activities showed the same boundary:

- sequence `389` followed by `549` after about 155 seconds, then a final running
  sample at `599`;
- another activity ending at running sequence `408`;
- sub-second phone-to-server delay for received samples;
- no later upload backlog containing the missing watch sequences.

The existing data cannot prove whether the exact watch transport-recovery build
was installed. The telemetry envelope contains the iOS `appVersion`, but no
watch build identifier. The watch timeout and failure counters exist only in
memory, and the iPhone's Garmin status events exist only in a 20-row UI list.

## 4. Goals

- Identify the exact watch build that generated every newly archived envelope.
- Preserve the watch sender's timeout, explicit-error, synchronous-exception,
  consecutive-failure, and last-outcome state on received samples.
- Keep protocol-v1 core telemetry compatible with old watch, iOS, and server
  builds during a staged rollout.
- Ensure optional diagnostics can never make otherwise valid activity telemetry
  unavailable because a diagnostic field is malformed.
- Make iPhone watch-receipt freshness change from current to delayed to
  unavailable as wall-clock age increases without new messages.
- Keep freshness labels, colors, and thresholds consistent through one pure,
  testable model.
- Persist iPhone process, scene, Garmin-device, and receipt-gap events across
  ordinary relaunches.
- Preserve callback time and event ordering without blocking the Garmin SDK
  callback or the ordered receipt pipeline on filesystem I/O.
- Bound diagnostic memory, disk use, UI history, and write frequency.
- Exclude coordinates, heart rate, credentials, request bodies, and tokens from
  diagnostics.
- Keep internal diagnostics out of public snapshot, SSE, and overlay responses.
- Provide a physical test matrix that separates watch, BLE, archive, and upload
  failures.

## 5. Non-Goals

- Do not claim that Garmin `onComplete()` proves iPhone archival or server
  acknowledgement.
- Do not add a phone-to-watch acknowledgement protocol in this change.
- Do not buffer or reconstruct every telemetry sample generated during an
  outage.
- Do not guarantee iOS relaunch after force-quit, reboot, crash, or process
  eviction.
- Do not blindly reinitialize the Garmin SDK or register duplicate delegates on
  every foreground transition.
- Do not upload the iPhone lifecycle log to the server automatically.
- Do not expose watch build IDs, device identifiers, or internal transport
  counters through viewer-token APIs.
- Do not add user notifications or background keepalive traffic.
- Do not tune the existing 15-second watch watchdog or retry delays without new
  physical evidence.
- Do not turn the diagnostic log into an unbounded per-second copy of telemetry.

## 6. Fixed Design Decisions

### 6.1 Protocol v1 gains optional diagnostic extensions

Version, sequence, and state remain the protocol-v1 core. New watch fields are
optional extensions. Old messages without them remain valid, and unknown future
extensions remain ignorable by iOS.

No protocol-version bump is required because the meaning or validation of any
existing field does not change.

### 6.2 Build identity is generated at build time

The watch build identifier must identify the source used to build the `.prg`.
Do not maintain it as an easy-to-forget hand-edited constant.

Add a small watch build wrapper that generates an ignored source file before
invoking `monkeyc`:

```text
watch/generated/WatchBuild.mc
RUNSYNC_WATCH_BUILD_ID = "<12-character-git-revision>"
```

Rules:

- a clean Git build uses the 12-character commit revision;
- a dirty development build appends `-dirty`;
- a source archive without Git must supply an explicit build ID;
- release builds fail when the working tree is dirty;
- the identifier is ASCII, 1 through 32 characters, and restricted to
  letters, digits, `.`, `_`, `+`, and `-`;
- `watch/generated/` is ignored, while the generator and build wrapper are
  committed;
- the documented physical, simulator, and test build commands use the wrapper
  so direct and CI builds cannot silently omit the identifier.

This identifier is diagnostic metadata, not an authorization or compatibility
token.

### 6.3 Watch diagnostics describe the prior sender state

Diagnostics are attached when a payload is constructed, before that payload's
own transmission completes. They describe the sender state observed immediately
before submitting the current sample.

Consequences:

- a timeout detected while pumping the current enqueue may first appear on the
  following generated sample;
- the newest pending sample normally replaces the prior payload during the
  retry cooldown, so the first recovered delivery should contain current
  counters;
- a successful callback resets failure state and appears on a later payload;
- no field may be described as proof that the packet carrying it was archived.

### 6.4 Diagnostics are cumulative only for one sender lifetime

Watch counters reset when the data-field process or `TelemetrySender` is
recreated. A build ID plus sequence behavior and iPhone process events provide
the surrounding context. Do not persist counters on the watch solely to make
them globally monotonic.

### 6.5 Diagnostic failure never blocks telemetry

Core telemetry has higher priority than observability.

- The watch omits a diagnostic field it cannot safely encode.
- iOS accepts a valid core sample even when an optional diagnostic extension is
  malformed.
- iOS records a sanitized `invalid_watch_diagnostic` event and omits the invalid
  value from the archived envelope.
- The server strictly validates diagnostic values that iOS elects to upload.
- Diagnostic-store write failure never pauses capture or upload.

### 6.6 Receipt health is separate from BLE status and upload status

The iPhone UI continues to show separate states:

```text
Garmin device status     Connected / Disconnected / Bluetooth unavailable
Watch receipt freshness Current / Delayed / Unavailable / Never
Local archive            Healthy / Write error / Reconciliation required
Server upload            Current / Backing off / Blocked / Not configured
```

A connected BLE label cannot make an old receipt green. A recent receipt cannot
make a blocked server upload look current.

### 6.7 Lifecycle diagnostics are local, bounded, and best effort

Use a dedicated serial diagnostic writer and rotating NDJSON files under
Application Support. Call sites enqueue small immutable events and never wait
for a filesystem append.

Diagnostic persistence is valuable evidence, but telemetry archival remains
the durability-critical write.

## 7. Watch Wire Extension

### 7.1 Compact fields

Add these optional keys to normal and terminal watch payloads:

| Wire key | iOS/server name | Type | Meaning |
| --- | --- | --- | --- |
| `wb` | `watchBuildID` | string | Generated watch source/build identifier |
| `wt` | `transportTimeoutCount` | integer | Watchdog timeouts since sender initialization |
| `we` | `transportErrorCount` | integer | Explicit Garmin `onError` callbacks |
| `wx` | `transportExceptionCount` | integer | Synchronous `transmit()` exceptions |
| `wf` | `transportConsecutiveFailures` | integer | Consecutive error, exception, or timeout outcomes |
| `wo` | `transportLastOutcome` | integer | `0` none, `1` success, `2` error, `3` timeout, `4` exception |

All counters are non-negative signed 32-bit integers. Saturate a counter at
`2147483647` instead of allowing wrap to create invalid telemetry.

Do not include active attempt IDs, payload contents, listener references, timer
values, coordinates, or precise wall time.

### 7.2 Encoding ownership

Add one helper that decorates both payload shapes from sender diagnostics:

```text
normal TelemetryEncoder payload
  -> append build and sender diagnostics
  -> enqueue normal

terminal minimal payload
  -> append build and sender diagnostics
  -> enqueue terminal
```

Do not duplicate key mapping between `compute()` and `onTimerReset()`.

The helper reads from `TelemetrySender.diagnostics(now)`. Extend the existing
dictionary only as necessary; keep state transitions in
`TelemetrySenderState`, not in UI or encoding code.

### 7.3 Watch display

Keep the primary labels `LIVE`, `DELAYED`, `RETRY`, and `NO PHONE`. Add a compact
diagnostic detail reachable on the existing field without requiring a new menu:

```text
Q 1234  T2 F5
```

where `T` is timeout count and `F` is consecutive failures. Preserve readable
sequence display on the Forerunner 965 and do not show the full build ID on the
small field.

## 8. iOS Watch Diagnostic Model

### 8.1 Decode result

Replace the assumption that decoding returns only a sample with a value that can
carry non-fatal diagnostic warnings:

```swift
struct GarminDecodedMessage {
    let sample: TelemetrySample
    let warnings: [GarminDecodeWarning]
}
```

`GarminMessageDecoder` continues throwing for an invalid core root, protocol,
sequence, state, or activity metric. Invalid diagnostic extensions produce a
warning and a `nil` field instead.

Unknown keys remain ignored.

### 8.2 Telemetry model

Add optional properties to `TelemetrySample`:

```text
watchBuildID
transportTimeoutCount
transportErrorCount
transportExceptionCount
transportConsecutiveFailures
transportLastOutcome
```

Keep the fields optional through watch decode, local archive, batch encoding,
server request decoding, and database storage.

Compatibility requirements:

- existing NDJSON without the fields decodes with `nil` values;
- new NDJSON remains readable by an older iOS build because Swift decoders
  ignore unknown keys;
- test factories use defaults so unrelated tests need not repeat six `nil`
  arguments;
- archived envelope values are immutable across retries;
- a replay of one envelope cannot acquire newer diagnostic counter values.

### 8.3 UI summary values

`AppModel` exposes the latest received values for the selected capture watch:

```text
watchBuildID
watchTransportTimeoutCount
watchTransportErrorCount
watchTransportExceptionCount
watchTransportConsecutiveFailures
watchTransportLastOutcome
```

Non-selected watches may create local lifecycle events but must not replace the
selected watch's primary status cells.

## 9. Persistent iPhone Garmin Diagnostic Store

### 9.1 Location and retention

Store events at:

```text
Application Support/RunSync/Diagnostics/garmin-events.ndjson
Application Support/RunSync/Diagnostics/garmin-events.1.ndjson
```

Use `completeUntilFirstUserAuthentication` file protection.

Retention policy:

- rotate the active file at 256 KiB;
- retain one previous file;
- cap the pending in-memory writer queue at 256 events;
- on queue overflow, drop the oldest non-critical pending diagnostic and write
  one aggregate `diagnostic_queue_overflow` event when capacity returns;
- load at most the newest 100 records for the diagnostics UI;
- display at most 50 records in memory;
- malformed or truncated tail records are skipped and counted, not treated as a
  capture failure.

This bounds local diagnostic storage near 512 KiB plus small metadata.

### 9.2 Event envelope

Every record contains:

```text
schemaVersion: 1
ordinal
occurredAt
systemUptimeSeconds
processSessionID
iOSAppVersion
event
details
```

`processSessionID` is a random UUID created at process launch. `ordinal` is
strictly increasing within that process. Wall time supports correlation with
phone/server timestamps; system uptime makes wall-clock changes visible.

### 9.3 Required event types

Persist these events:

#### Process and scene

- `process_started`;
- `garmin_sdk_initialized`;
- `scene_active`;
- `scene_inactive`;
- `scene_background`;
- `memory_warning` when delivered;
- `protected_data_unavailable` when a diagnostic write cannot occur before
  first unlock.

Do not infer or label a process as evicted; a later `process_started` proves a
new process, but the prior termination reason may remain unknown.

#### Garmin registration and device state

- authorized-device cache restored count;
- device/app delegate registration;
- authorization accepted or rejected category;
- `device_status_changed` with the SDK status enum;
- `device_characteristics_discovered`;
- app-status request success, missing, or timeout;
- selected-device mismatch;
- explicit status refresh requested.

Use an abbreviated device UUID or stable local device tag. Never include the
friendly device name in a file intended for diagnostic export.

#### Receipt path

- first valid message in a process;
- first valid message after a receipt gap greater than 10 seconds;
- a checkpoint at most once per 60 seconds while messages remain healthy;
- activity state transitions;
- sequence regression or a sequence jump greater than one;
- invalid watch diagnostic warnings;
- decoder rejection category and shape, without values;
- receipt-pipeline pause or overflow;
- capture enabled/disabled transitions;
- local archive failure category.

A receipt event may include:

```text
callback ordinal
watch sequence
activity state
watch build ID
previous receipt age in whole milliseconds
sequence delta
transport counters and outcome
selected-device match boolean
```

It must not include coordinates, distance, speed, altitude, heart rate,
cadence, tokens, URLs containing credentials, or the raw Garmin message.

### 9.4 Writer ordering and failure behavior

Create one process-wide recorder before Garmin SDK initialization. It allocates
event ordinals synchronously and enqueues immutable events onto one serial
writer.

Requirements:

- Garmin callbacks do not perform file I/O;
- event allocation is safe from non-main callback threads;
- callback time is captured before dispatching to an actor or the main thread;
- records are written in ordinal order;
- rotation happens only on the serial writer;
- write failure records one in-memory status and backs off further diagnostic
  writes briefly;
- diagnostic failure never calls `stopCaptureAfterQueueFailure()`;
- process shutdown does not claim that every queued diagnostic was flushed.

### 9.5 Integrating existing diagnostics

Keep `Logger` output for development, but route durable Garmin and lifecycle
events through the new store. Replace the separate ad hoc
`decoder-diagnostics.log` writer with the common bounded event format after
migration tests prove equivalent rejection evidence.

`AppModel.record()` may continue to add human-readable UI rows, but it must not
be the source of truth for durable diagnostics.

### 9.6 Delete behavior

`Delete All Local Telemetry` also removes the Garmin diagnostic files and clears
their in-memory UI history after telemetry deletion has acquired the existing
deletion fence.

Do not allow a queued pre-delete diagnostic append to recreate the directory
after deletion. Give diagnostic storage its own generation/delete epoch or
drain/cancel its serial writer as part of the delete operation.

## 10. Receipt Freshness UI

### 10.1 Pure freshness model

Add a value type independent of SwiftUI:

```text
WatchReceiptFreshness
  captureDisabled
  never
  current(age)
  delayed(age)
  unavailable(age)
```

Initial thresholds:

| State | Receipt age |
| --- | ---: |
| Current | 0 through 10 seconds |
| Delayed | over 10 through 30 seconds |
| Unavailable | over 30 seconds |

Clamp a future receipt timestamp to age zero for display and record a clock
anomaly diagnostically if it is materially in the future.

Centralize thresholds in one named policy. Do not scatter literal values across
views, models, and tests.

### 10.2 Header behavior

The header derives all freshness-dependent content inside one periodic timeline
update. Updating only the age text is insufficient because the color and title
must also change when no new `@Published` value arrives.

Suggested presentation:

| State | Color | Title |
| --- | --- | --- |
| Capture disabled | gray | `Capture disabled` |
| Never | orange | `Waiting for watch telemetry` |
| Current | green | `Watch telemetry current` |
| Delayed | yellow | `Watch telemetry delayed` |
| Unavailable | red | `Watch telemetry unavailable` |

Show the exact age beneath the title and keep the independent Garmin-device
status in the existing grid.

### 10.3 Status-grid additions

Add or refine these cells:

```text
Watch receipt       Current / Delayed / Unavailable / Never, age
Watch build         <build ID> / Unknown
Watch transport     Success / Error / Timeout / Exception / Unknown
Transport failures  consecutive count and cumulative timeout count
```

Do not imply that `Success` means server delivery. Label the section as watch
transport and retain separate local archive and server acknowledgement cells.

### 10.4 Relaunch restoration

On launch, initialize the latest watch-receipt timestamp and diagnostic summary
from the newest valid archived envelope or current-session metadata before the
next Garmin callback. A relaunch must not present an old activity as freshly
received merely because it was restored.

The freshness calculation always uses the original `phoneReceivedAt`.

## 11. Server Contract and Persistence

### 11.1 Rollout requirement

The server decoder currently rejects unknown JSON fields. Deploy server support
before an iOS build begins uploading the new optional sample properties.

Safe order:

```text
1. server accepts and stores optional diagnostic fields
2. iOS decodes, archives, uploads, persists, and displays them
3. watch begins transmitting compact diagnostic keys
```

A new watch paired with old iOS is safe because the current watch-message
decoder ignores unknown keys. Old iOS paired with the new server is unchanged.
Old watch telemetry remains valid everywhere.

### 11.2 API model

Extend the server's private ingest `Sample` with nullable diagnostic fields.
Validation:

- build ID follows the 1 through 32 character safe format;
- counters are `0...2147483647`;
- last outcome is `0...4`;
- fields may be independently absent for backward compatibility;
- a malformed uploaded value rejects that envelope with the existing identified
  invalid-envelope response;
- request and error logs never include the field values automatically.

### 11.3 Database migration

Add `server/migrations/002_watch_transport_diagnostics.sql` with nullable
columns on `telemetry_samples`:

```text
watch_build_id text
transport_timeout_count integer
transport_error_count integer
transport_exception_count integer
transport_consecutive_failures integer
transport_last_outcome smallint
```

Add database checks matching API validation. Do not backfill historical rows or
invent a build identifier from dates.

No new index is required initially. Incident queries already narrow by activity
and order by receipt time.

### 11.4 Ingest idempotency

Update insert and envelope-conflict comparison logic so diagnostics are part of
the immutable envelope content. Replaying an identical archived envelope is
acknowledged. Reusing an envelope UUID with different diagnostic values remains
an envelope conflict.

### 11.5 Public API isolation

Do not add these properties to public live samples, route points, snapshots,
SSE events, viewer-token responses, or frontend contracts.

Add an integration test proving that an ingested diagnostic-rich envelope still
produces the existing public JSON shape without watch build or transport keys.

### 11.6 Operator query

Add a safe query to `docs/server-operations.md` that reports, for a selected
activity:

```text
phone receipt time
watch sequence
watch build ID
transport counters and last outcome
phone-to-server delay
sequence delta and receipt gap
```

The query must omit location and physiological values.

## 12. Concurrency and Lifecycle Integration

### 12.1 Process startup

Startup order becomes:

```text
create diagnostic recorder and process session ID
record process_started
initialize Garmin SDK
record garmin_sdk_initialized
restore authorized devices
register device and app delegates
load latest durable diagnostic UI summary
recover telemetry session and upload state
```

Do not delay Garmin registration on reading or rendering the entire diagnostic
history.

### 12.2 Scene transitions

Forward all `scenePhase` values, not only `.active`, to
`GarminConnectionService` or a lifecycle coordinator. Record the transition
before starting foreground upload recovery.

On `.active`:

- recompute receipt freshness;
- query current Garmin device status through the supported SDK API;
- refresh app-installed status when the device is connected;
- do not unregister or duplicate registrations unless a separately tested repair
  path explicitly requires it;
- continue existing session and upload recovery.

### 12.3 Garmin callbacks

`deviceStatusChanged` and `receivedMessage` are nonisolated SDK callbacks.
Capture timestamp, system uptime, process session ID, and safe event details at
the callback boundary. Then enqueue diagnostics and existing receipt work.

The diagnostic recorder must not reorder telemetry receipts or become a new
backpressure source for `GarminReceiptPipeline`.

### 12.4 Receipt-gap detection

Maintain a small per-device in-memory observation:

```text
last callback time
last sequence
last state
last watch build ID
last transport counter tuple
last checkpoint time
```

This state is diagnostic only. It cannot open, split, close, discard, or upload
an activity.

## 13. Privacy and Security

- Diagnostics stay local unless the user deliberately copies or exports them in
  a future feature.
- Never log raw Garmin dictionaries.
- Never log coordinates, speed, distance, altitude, heart rate, cadence,
  configuration tokens, authorization headers, or server request bodies.
- Store only an abbreviated device identifier or local opaque device tag in the
  diagnostic log.
- Treat build IDs and sequences as internal metadata and keep them out of public
  APIs.
- Protect files until first user authentication so locked-screen BLE wake can
  append after the first unlock.
- A diagnostic write attempted while protected data is unavailable is best
  effort and must not cache sensitive telemetry for later logging.
- Delete-all clears both telemetry and lifecycle diagnostics without permitting
  an older queued append to recreate deleted state.

## 14. Automated Tests

### 14.1 Watch state and encoding tests

- Healthy payload contains the generated build ID and zeroed diagnostic state.
- A watchdog timeout increments the encoded timeout count and sets timeout
  outcome on a subsequent newest payload.
- Explicit error and synchronous exception counters remain distinct.
- Success resets consecutive failures without resetting cumulative counters.
- Counter saturation cannot wrap negative.
- Normal and terminal payloads use the same diagnostic key mapping.
- A missing generated build constant fails the build rather than emitting an
  empty identifier.
- Existing latest-value, timeout, stale-callback, terminal, timer-wrap, and
  long-outage tests continue passing.

### 14.2 iOS decoder and archive tests

- Legacy protocol-v1 message produces a valid sample with nil diagnostics.
- A fully populated diagnostic extension decodes exact values.
- Unknown keys remain harmless.
- An invalid diagnostic counter produces a warning while preserving valid core
  telemetry.
- An invalid core field still rejects the message.
- Old archived NDJSON decodes after model extension.
- New archived NDJSON round-trips diagnostics exactly.
- Batch retries preserve the original diagnostic values.
- Test factories can omit all diagnostic properties.

### 14.3 Diagnostic-store tests

- Concurrent callers receive strictly ordered per-process ordinals.
- Callback timestamp is preserved independently of eventual write time.
- Rotation retains at most the active and one previous file.
- A truncated final NDJSON record does not hide earlier records.
- Invalid records are skipped and counted.
- Queue overflow remains bounded and yields one aggregate event.
- File write failure does not pause Garmin capture.
- Relaunch loads only the newest configured UI records.
- Delete-all prevents pre-delete queued writes from recreating diagnostics.
- No allowed event detail schema contains forbidden telemetry keys.

### 14.4 Freshness-model and UI tests

- Capture disabled is neutral regardless of the old receipt time.
- No receipt is `never`.
- Ages at exactly 10 and 30 seconds use the documented boundary.
- Ages immediately over each threshold transition correctly.
- Future timestamps clamp to current and produce a diagnostic anomaly.
- Periodic timeline advancement changes color and title without a new sample.
- A new receipt returns delayed/unavailable state to current.
- Relaunch with an old archived receipt begins unavailable, not green.
- Garmin device status, archive state, and upload state remain independently
  visible.

### 14.5 Server tests

- Legacy requests without diagnostics are accepted unchanged.
- Valid optional diagnostics are accepted and persisted.
- Invalid build format, counters, and outcome return an identified invalid
  envelope.
- Nullable migration columns accept historical behavior.
- Duplicate identical envelopes acknowledge idempotently.
- A duplicate envelope with changed diagnostics conflicts.
- Load/replay code returns stored private diagnostics where required internally.
- Public snapshots, streams, and route responses omit every diagnostic field.
- Migration applies cleanly to a database containing historical samples.

## 15. Physical Validation

Use the exact watch build ID shown by the iPhone in every test report. Record all
times in UTC and note iPhone model, iOS version, Forerunner firmware, Garmin SDK
version, and whether the phone was foreground, locked, or manually reopened.

### 15.1 Healthy foreground baseline

1. Open RunSync and confirm the selected watch is ready.
2. Keep the RunSync field visible.
3. Run for 15 minutes with the phone foregrounded.
4. Confirm the receipt UI stays current.
5. Confirm watch build and counters reach the server.
6. Confirm no diagnostic field appears in public live JSON.

### 15.2 Forced Bluetooth outage

1. Start from a healthy current state.
2. Disable iPhone Bluetooth for 60 seconds.
3. Confirm the phone UI becomes delayed and then unavailable when viewed.
4. Confirm the watch changes to `RETRY` or `NO PHONE`.
5. Re-enable Bluetooth without ending the Garmin activity.
6. Confirm current telemetry resumes and the UI returns to current.
7. Correlate watch timeout counters, iPhone device events, receipt-gap event,
   archived sample, and server receipt.

### 15.3 Range outage

Repeat the outage by moving the phone outside BLE range without changing app
state. This separates explicit Bluetooth power state from ordinary radio loss.

### 15.4 Locked-screen endurance

Run the existing progression:

```text
30 minutes locked
2 hours locked
4 hours locked
```

For every gap greater than 10 seconds, require a correlatable local lifecycle or
receipt-gap record. Do not interpret absence of a recorded termination reason as
proof that iOS remained alive.

### 15.5 Foreground recovery attribution

If telemetry stops while locked:

1. note the watch label and sequence without ending the activity;
2. foreground RunSync;
3. observe whether telemetry resumes immediately;
4. confirm whether a new `processSessionID` appeared;
5. compare device status, build ID, counters, and first recovered receipt.

Interpretation:

- new process session immediately before recovery supports process absence or
  relaunch as the boundary, without claiming the termination reason;
- same process plus disconnected/connected events supports BLE lifecycle loss;
- same process with no device event and rising watch timeout counters supports a
  Garmin transmission/callback failure;
- contiguous phone receipt time with late server acknowledgement belongs to the
  upload path instead.

### 15.6 Unsupported but informative cases

Record, but do not make MVP guarantees for:

- user force-quit;
- iPhone reboot;
- watch reboot;
- app upgrade during an activity;
- OS process eviction.

## 16. Rollout

### Phase 1: server compatibility

- Add nullable API fields and validation.
- Add migration and ingest persistence.
- Add idempotency and public-isolation tests.
- Deploy and verify legacy iOS telemetry remains unchanged.

### Phase 2: iOS observability

- Add optional diagnostic model and tolerant watch decoding.
- Add bounded diagnostic store and lifecycle integration.
- Add pure freshness model and periodically updating UI.
- Upload diagnostic fields only to a server known to accept them through normal
  deployment coordination; no runtime capability negotiation is required for
  this private deployment.
- Validate old-watch behavior with unknown build and nil counters.

### Phase 3: watch diagnostics

- Add generated build identity and wrapper scripts.
- Add compact diagnostic encoding to normal and terminal payloads.
- Sideload the exact build and confirm the iPhone displays its identifier.
- Run forced-outage tests before changing watchdog timing.

### Phase 4: endurance and cleanup

- Complete locked-screen tests.
- Review file size, battery use, callback latency, and watch memory.
- Reduce overly chatty event types while preserving attribution evidence.
- Document a safe operator incident query.

## 17. Acceptance Criteria

- Every sample from the new watch build can be attributed to a non-empty build
  ID on iOS and in private server storage.
- Historical and old-watch samples remain accepted with nil diagnostics.
- A watch timeout recovered on hardware produces a later received sample whose
  counters demonstrate the timeout.
- Optional diagnostic corruption cannot discard otherwise valid core telemetry.
- The iPhone header becomes delayed after 10 seconds and unavailable after 30
  seconds without requiring a new `@Published` update.
- Foregrounding after a long gap cannot leave an hours-old receipt green.
- Process, scene, device status, and receipt-gap evidence survives ordinary app
  relaunch.
- Diagnostic writes do not block or pause the Garmin receipt pipeline.
- Local diagnostic storage remains bounded near the documented limit.
- Delete-all removes diagnostics without stale queued recreation.
- Public API and overlay payloads contain no watch build or transport diagnostic
  fields.
- A forced Bluetooth outage can be attributed across watch, iPhone, archive,
  and server timestamps.
- No watchdog or retry-policy change ships solely from historical pre-build
  evidence.

## 18. Risks and Mitigations

### Diagnostic payload overhead

Adding a build string and counters to every watch payload increases BLE traffic.

Mitigation: use compact wire keys, bounded scalar values, and measure serialized
size and battery use during endurance tests. If overhead is material, keep build
ID on every payload but emit unchanged counter tuples at a measured lower
frequency only after proving recovery attribution remains reliable.

### Diagnostics change the failure they measure

Extra allocation or logging could worsen memory or timing pressure.

Mitigation: keep watch fields scalar, perform no watch persistence, enqueue
iPhone lifecycle events without callback-thread I/O, and measure callback
latency and memory before broad rollout.

### Dirty build identifiers are ambiguous

A Git revision plus `-dirty` does not identify the uncommitted diff.

Mitigation: reject dirty release builds. Dirty identifiers are for local tests
only and must be accompanied by the retained source diff in the test report.

### Optional fields break strict server decoding

The current server rejects unknown JSON fields.

Mitigation: deploy nullable server support first and cover mixed-version rollout
with integration tests.

### Lifecycle log suggests an unsupported conclusion

A new process session proves relaunch, not why the prior process ended. Missing
events do not prove the process remained alive.

Mitigation: use precise event wording and document inference limits in the UI
and test report.

### Diagnostic deletion races with queued writes

An asynchronous writer could recreate files after delete-all.

Mitigation: fence diagnostic writes with a delete generation and test queued
pre-delete events explicitly.

### Stale thresholds produce false alarms

Legitimate Garmin delivery may occasionally exceed 10 seconds.

Mitigation: distinguish delayed from unavailable, keep thresholds centralized,
and tune only from physical distributions. A warning changes display state only;
it never changes capture or activity lifecycle.

## 19. Implementation Checklist

### Server

- [ ] Add optional private ingest fields and validation.
- [ ] Add migration `002_watch_transport_diagnostics.sql`.
- [ ] Persist fields in insert, load, and conflict paths.
- [ ] Prove public response isolation.
- [ ] Add the safe incident query to server operations documentation.

### iOS model and persistence

- [ ] Add optional watch diagnostic model fields with compatibility defaults.
- [ ] Add tolerant diagnostic decoding and warnings.
- [ ] Round-trip fields through archive and batch codec.
- [ ] Implement bounded, protected, rotating Garmin diagnostic storage.
- [ ] Fence diagnostic delete behavior.
- [ ] Replace the ad hoc decoder log after migration coverage.

### iOS lifecycle and UI

- [ ] Record process and every scene-phase transition.
- [ ] Record Garmin registration, device status, characteristics, and app status.
- [ ] Add sparse receipt checkpoints and explicit gap events.
- [ ] Add the pure watch-receipt freshness policy.
- [ ] Put all freshness-dependent header rendering inside periodic evaluation.
- [ ] Restore the last receipt timestamp without treating it as new.
- [ ] Display watch build and transport summary separately from upload status.

### Watch

- [ ] Generate a build ID for every physical, simulator, and test build.
- [ ] Add compact diagnostic fields to normal and terminal payloads.
- [ ] Saturate counters safely.
- [ ] Keep status text readable on the Forerunner 965.
- [ ] Run deterministic sender tests.

### Physical verification

- [ ] Healthy foreground baseline.
- [ ] Forced Bluetooth outage and recovery.
- [ ] Out-of-range outage and recovery.
- [ ] Thirty-minute locked-screen run.
- [ ] Two-hour locked-screen run.
- [ ] Four-hour locked-screen run.
- [ ] Correlate at least one real recovery across all three boundaries.

## 20. Deferred Follow-Ups

Only consider these after the observability rollout identifies the remaining
failure boundary:

- a tested iOS BLE repair action on foreground;
- a clearer rename or expansion of `Recover & Retry` for BLE state;
- phone-to-watch acknowledgement;
- a bounded compressed watch backlog;
- user-exported sanitized diagnostics;
- automatic internal incident summaries;
- watchdog/backoff tuning;
- a Garmin SDK bug report containing exact build, firmware, lifecycle, timeout,
  and reproduction evidence.
