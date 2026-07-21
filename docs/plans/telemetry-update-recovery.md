# RunSync Telemetry Upload Recovery Plan

## 1. Purpose

Make RunSync recover automatically from poor or changing iPhone connectivity while preserving a clear manual recovery path when iOS suspends work or the local pipeline pauses.

The watch-to-phone archive remains authoritative for delivery. A network outage may delay the website, but it must not lose samples that reached iOS, change their activity UUID, or require restarting the Garmin activity. When connectivity returns, recovered samples should upload with their original timestamps and repair the current route and metrics automatically.

This plan adds:

- a coordinated Swift retry state machine;
- immediate retry on connectivity restoration while the process can run;
- a dedicated `URLSession` configured to wait for connectivity;
- an explicit `Recover & Retry` control;
- background transfer support for eventual backlog delivery;
- isolation of permanently rejected envelopes;
- diagnostics that distinguish watch, archive, upload, and website freshness;
- end-to-end verification that late samples repair the live map.

## 2. Observed Failure

During the incident that motivated this plan, the server received 370 samples for one activity and then stopped abruptly while the activity remained `running`.

```text
last phone receipt: 2026-07-18 23:55:26.604 UTC
last sequence: 408
last state: running
last distance: 757.6 m
last heart rate: 147 BPM
```

Before the cutoff, phone-to-server delivery was healthy:

```text
median delay: 60 ms
p95 delay: 80 ms
maximum delay: 293 ms
API responses: all 200
```

No server rejection occurred. The API, PostgreSQL, Caddy, Cloudflare Tunnel, frontend, and SSE reconnection path remained healthy. The public website correctly retained the final stored sample and marked it stale.

The server cannot determine which of these occurred after the cutoff:

- the watch stopped reaching iOS;
- iOS continued archiving but had no usable internet path;
- iOS was suspended before its retry task could execute;
- capture was disabled after a local reconciliation/queue failure;
- a permanent client-side upload state blocked later retries.

The implementation must expose enough state to distinguish those cases without needing server-side inference.

## 3. Current Behavior

### 3.1 What already works

The existing iOS implementation provides a strong base:

- `TelemetryIngestor` appends each assigned envelope to protected NDJSON before upload.
- Every envelope and activity UUID remains stable across retries.
- Server acknowledgements are journaled by exact envelope UUID.
- Relaunch scans the archive for unacknowledged envelopes.
- Transient failures use exponential backoff with jitter.
- Backoff is capped at five minutes.
- New Garmin receipts continue archiving while an HTTP request is awaiting a response.
- Foregrounding RunSync calls `retryUploads()`.
- The existing `Retry now` action can clear upload backoff and retry manually.
- The server accepts idempotent retransmission.
- The frontend deduplicates route points and sorts them by original phone receipt time.

### 3.2 Current gaps

- `HTTPTelemetrySink` uses `URLSession.shared` and does not enable `waitsForConnectivity`.
- Swift retry tasks are not guaranteed to execute while iOS is suspended.
- Foreground retry does not explicitly distinguish transient backoff from permanent authentication/rejection state.
- `Retry now` retries HTTP only; it does not reconcile or resume a paused Garmin receipt pipeline.
- Capture pause prevents pending uploads, even when the user presses upload retry.
- There is no connectivity-restored trigger while the app process remains runnable.
- There is no system-managed background transfer for a durable backlog.
- A permanently rejected head batch can block all later envelopes.
- The UI does not clearly separate last watch receipt, last archive append, last upload attempt, and last server acknowledgement.
- Watch transport completion can be mistaken for successful server delivery.

## 4. Goals

- Never delete or rewrite an archived envelope to make retry succeed.
- Preserve original `phoneReceivedAt`, activity UUID, envelope UUID, and sample values.
- Retry transient failures indefinitely while pending data exists.
- Retry promptly when connectivity returns and the process can run.
- Recover pending data on launch and foreground activation.
- Provide one explicit manual action that reconciles capture and forces delivery recovery.
- Keep live ingestion responsive while a backlog uploads.
- Use system-managed background transfer for eventual delivery when appropriate.
- Isolate malformed/permanently rejected envelopes so later valid telemetry can proceed.
- Make duplicate foreground/background attempts harmless through existing server idempotency.
- Allow the website route and metrics to self-heal as late data arrives.
- Explain current pipeline state without logging coordinates, credentials, or request bodies.

## 5. Non-Goals

- Do not promise real-time delivery without phone connectivity.
- Do not promise execution after the user force-quits RunSync.
- Do not treat Garmin's native FIT recording as a source for RunSync replay.
- Do not ask the watch to retain a full telemetry backlog.
- Do not create a new activity UUID because upload connectivity changed.
- Do not keep one HTTP request per one-second sample while offline.
- Do not retry authentication failures aggressively without user/configuration action.
- Do not hide that iOS background scheduling is system-controlled.
- Do not change the server ingestion schema for the first implementation.

## 6. Fixed Product Decisions

### 6.1 Durable archive is the outbox

Protected NDJSON plus exact acknowledgement journals remain the durable upload outbox. In-memory arrays are accelerators only. A process restart must be able to reconstruct all pending work from disk.

### 6.2 Network failure never disables capture

Transient HTTP, DNS, TLS, cellular, Wi-Fi, or reachability failures must not disable Garmin capture. Continue archiving while connectivity is unavailable.

Capture may still pause for local durability failures, receipt queue overflow, or unreconciled session state. Those failures require the stronger manual recovery workflow.

### 6.3 One upload coordinator

Only one component decides when and how to submit pending envelopes. Foreground requests, connectivity changes, lifecycle events, background transfers, and manual recovery all send triggers to the same actor.

### 6.4 Retry is indefinite but bounded per attempt

There is no total retry-count limit for transient failures. Each request has a timeout, batches are bounded, backoff is capped, and only a bounded amount of work may be in flight.

### 6.5 Manual recovery is explicit and non-destructive

The user-facing recovery action may re-enable capture because pressing it is explicit consent. It must not delete telemetry, rotate installation identity, alter activity UUIDs, or create a new activity.

### 6.6 Capture and delivery are separate controls

Capture controls whether new Garmin receipts become archived envelopes. It does not prevent already archived envelopes from uploading. Once telemetry has been explicitly captured, RunSync continues attempting delivery until acknowledgement, quarantine, or explicit delete-all.

A local activity-session reconciliation failure may pause assignment of new receipts, but it must not block scanning or uploading intact envelopes from any run archive. If a future product needs an upload pause, expose it as a separate explicit control.

### 6.7 Every upload is fenced to one destination generation

Persist a monotonically increasing upload configuration generation. Increment it when the base URL, token, installation binding, or delete-all epoch changes.

Every foreground lease, background task, and staged request records:

```text
configurationGeneration
normalized HTTPS origin and API base-path fingerprint
deleteEpoch
batch ID
envelope IDs
```

The fingerprint is non-secret and must not contain the token. Completion effects apply only when generation, destination fingerprint, and delete epoch still match current state. A stale completion may clean up only its own generation-scoped staging files; it cannot append acknowledgements, recreate deleted archive directories, or remove files belonging to a newer attempt.

## 7. User Experience

### 7.1 Status separation

Display separate timestamps and states:

```text
Watch receipt       4s ago / Never
Local archive       Current / Write error / Reconciliation required
Capture             Enabled / Paused
Pending upload      47 samples, oldest 6m 12s
Connectivity        Online / Unsatisfied / Expensive / Constrained
Upload              Current / Waiting for connection / Backing off / Blocked
Last attempt        12s ago
Last acknowledgement 18s ago
Website age         derived from last acknowledgement
```

Do not label watch transport as server delivery.

### 7.2 `Recover & Retry`

Add a primary diagnostics action labeled `Recover & Retry`.

Expected result examples:

```text
Capture resumed
47 pending samples recovered
Upload current
```

```text
Recovery completed
Waiting for internet
47 samples remain protected on this iPhone
```

```text
Recovery blocked
Server authentication must be updated
47 samples remain protected on this iPhone
```

Disable repeated taps while recovery setup is running, but do not block the UI for the duration of an HTTP request.

### 7.3 Keep a smaller upload-only action only if useful

The existing `Retry now` can remain as an upload-only diagnostic action. The stronger action must be visually distinct because it also reconciles and resumes capture.

## 8. Retry Coordinator

### 8.1 Ownership

Introduce an actor, tentatively `TelemetryUploadCoordinator`, or refactor the existing upload portion of `TelemetryIngestor` into an equivalent isolated state machine.

It owns:

- the in-memory pending index;
- one foreground request lease;
- one background transfer lease;
- retry attempt and backoff deadline;
- latest failure classification;
- connectivity state;
- upload status snapshots;
- trigger coalescing;
- quarantine decisions.

It does not own Garmin session segmentation. Activity assignment and archive persistence remain separate from network scheduling.

Pending-envelope scanning must not call or await activity-session reconciliation. Split the current coupled `recoverPending()` behavior into independent archive-outbox recovery and session recovery operations. The upload coordinator may deliver valid archived envelopes while capture remains paused or current-session metadata remains unreconciled.

### 8.2 States

```text
idle
current
submittingForeground
waitingForConnectivity
backingOff
stagingBackgroundTransfer
backgroundTransferActive
recovering
blockedAuthentication
blockedConfiguration
isolatingRejectedEnvelope
```

State transitions must be observable in tests without real networking.

### 8.3 Triggers

The coordinator evaluates work when:

- an envelope is durably appended;
- a foreground request completes;
- connectivity becomes satisfied;
- backoff expires;
- the app becomes active;
- capture is explicitly resumed;
- session reconciliation completes;
- a background transfer completes;
- server configuration changes;
- the user presses `Retry now`;
- the user presses `Recover & Retry`.

Coalesce duplicate triggers. Never launch parallel foreground batches for the same pending prefix.

### 8.4 Retry policy

Initial transient backoff:

```text
1s, 2s, 4s, 8s, 16s, 32s, 60s, 120s, 300s maximum
```

Apply jitter in the existing range. A successful acknowledgement resets the attempt counter. A connectivity-restored, foreground, or explicit manual trigger may bypass the current transient delay once.

Do not bypass a persistent authentication block automatically. A manual recovery may attempt authentication once, then return to blocked state if the same response repeats.

### 8.5 Batch behavior

- Keep the server maximum of 100 envelopes per request.
- Preserve ascending phone receipt order with stable envelope-ID tie-breaking.
- Immediately continue with the next batch after a complete acknowledgement while execution time remains.
- Stop and classify partial acknowledgement rather than dropping unacknowledged IDs.
- Reconstruct pending from disk after uncertainty or process restart.
- Do not delay a live sample solely to fill a batch when online.

## 9. Connectivity Integration

### 9.1 Dedicated foreground session

Replace `URLSession.shared` with an injected dedicated session using a deliberate configuration:

```swift
let configuration = URLSessionConfiguration.default
configuration.waitsForConnectivity = true
configuration.timeoutIntervalForRequest = 30
configuration.timeoutIntervalForResource = 300
configuration.allowsCellularAccess = true
configuration.allowsExpensiveNetworkAccess = true
configuration.allowsConstrainedNetworkAccess = true
```

The exact timeouts should be validated on hardware. `waitsForConnectivity` avoids immediately failing a request merely because the network path is temporarily unavailable.

Use a session delegate for telemetry redirects. Reject unexpected redirects rather than allowing the default behavior to resend a precise-location request body. The initial implementation should reject all ingest redirects and report a sanitized configuration error. If redirects are later required, allow only an explicitly tested same-scheme, same-host, same-port, same-endpoint redirect; never forward telemetry or authorization across origins.

### 9.2 `NWPathMonitor`

Add a small injected connectivity monitor that reports:

- satisfied/unsatisfied/requires connection;
- cellular/Wi-Fi/other interface;
- expensive path;
- constrained path.

When the path changes to satisfied, trigger one immediate transient retry. Do not assume `NWPathMonitor` can relaunch or execute a suspended application. Its purpose is prompt recovery while RunSync is runnable.

### 9.3 Foreground behavior

On transition to active:

1. reload capture settings;
2. recover pending envelopes from disk independently;
3. trigger upload recovery immediately for intact pending envelopes;
4. reconcile current session separately if required;
5. clear transient backoff for one immediate attempt;
6. retain authentication/configuration blocks unless configuration changed;
7. update visible upload and capture recovery status independently.

Foregrounding should normally be sufficient to flush a transient backlog. The manual button remains available when capture or reconciliation also needs intervention.

## 10. Manual Recovery Workflow

`GarminConnectionService.recoverAndRetry()` should coordinate recovery without performing network I/O on the ordered receipt pipeline itself.

### 10.1 Non-droppable recovery barrier

Add a control lane to `GarminReceiptPipeline` that is independent of the bounded receipt queue. `requestRecovery` sets a non-droppable barrier flag. The consumer finishes its current receipt, stops before dequeuing the next receipt, and executes recovery. Incoming callbacks remain in the bounded FIFO queue.

If the receipt queue fills while recovery runs, count and report callbacks that could not be buffered. Do not claim that manual recovery reconstructed those watch samples. A full receipt queue must never prevent the recovery control itself from running.

At the barrier:

1. pauses assignment at a safe FIFO boundary;
2. reloads the selected capture device;
3. reconciles durable activity session state;
4. explicitly re-enables capture when reconciliation succeeds;
5. resumes the receipt pipeline;
6. refreshes Garmin device and data-field status;
7. returns a structured local recovery result.

Archive-outbox scanning and upload recovery run independently before or alongside this barrier. If reconciliation fails, keep new capture paused, retain all data, show the sanitized reason, and continue uploading every intact envelope already in the outbox.

### 10.2 Asynchronous upload kick

Send a force-transient trigger to the upload coordinator without waiting for local session recovery to succeed. Do not await a potentially 30-second network request inside the receipt pipeline barrier.

The trigger:

- cancels transient backoff;
- clears stale waiting-for-connectivity state;
- retries a prior permanent response once if explicitly requested;
- does not loop authentication failures;
- stages background delivery if foreground delivery cannot proceed.

### 10.3 Result contract

Return enough information for UI and diagnostics:

```text
captureResumed
sessionReconciled
currentActivityID, abbreviated for display
pendingEnvelopeCount
oldestPendingAge
uploadState
lastSafeErrorCategory
```

## 11. Background Delivery

### 11.1 Why ordinary tasks are insufficient

Swift `Task.sleep`, default `URLSession` completion handlers, and `NWPathMonitor` do not guarantee execution while iOS suspends the process. They remain the low-latency path, not the eventual-delivery guarantee.

### 11.2 Background `URLSession`

Add one background session with a stable application identifier. Use file-backed upload tasks because iOS background sessions require durable transfer bodies.

```text
Application Support/RunSync/UploadQueue/<batchID>.json
Application Support/RunSync/UploadQueue/<batchID>.metadata.json
```

Requirements:

- use `.completeUntilFirstUserAuthentication` file protection;
- include no bearer token in files;
- store batch envelope IDs, activity IDs, configuration generation, destination fingerprint, delete epoch, and task identifier in protected metadata;
- set authorization headers on the request;
- reject telemetry redirects through the background session delegate;
- accumulate response bytes per task through `URLSessionDataDelegate` callbacks;
- validate the exact-ID acknowledgement only after the complete response and task completion are available;
- append acknowledgements before deleting the staged request files;
- reconstruct task-to-batch ownership after process relaunch;
- fence acknowledgement and cleanup effects against current generation, destination, and delete epoch;
- call the saved completion handler from `handleEventsForBackgroundURLSession` exactly once only after URLSession reports finished events and all asynchronous acknowledgement/archive writes complete;
- allow iOS to relaunch for background session events when the user did not force-quit the app.

The background manager maintains an async-finalization counter. Delegate callbacks may enqueue actor work, but `urlSessionDidFinishEvents(forBackgroundURLSession:)` does not release the AppDelegate completion handler until that counter reaches zero. Late callbacks for canceled, deleted, or superseded generations become no-ops except for generation-scoped cleanup.

### 11.3 Cold-launch ordering

Construct and reconnect the stable background session before starting Garmin registration, current-session recovery, or ordinary foreground outbox submission.

Cold launch order:

```text
AppDelegate/AppContainer initialization
-> create background upload manager and URLSession delegate
-> enumerate system background tasks
-> reconcile protected task metadata and envelope leases
-> detect and finish any in-progress delete-all transaction
-> install any saved background event completion handler
-> recover unleased archive outbox
-> start GarminConnectionService
-> permit foreground upload
```

This prevents foreground recovery from submitting envelopes already owned by a surviving background task.

### 11.4 Foreground/background coordination

The upload coordinator leases envelope IDs to one transfer mode at a time. If a race still causes duplicate submission, server idempotency must make it harmless.

Do not stage one background task per sample. Stage bounded batches, initially up to 100 envelopes. Maintain at most one active background batch and one prepared successor unless hardware tests justify more.

When the app becomes active, do not cancel a healthy background task merely to move it foreground. Foreground upload may process unleased later envelopes.

Credential/base-URL change increments the generation and cancels old tasks. Old acknowledgements are ignored; their envelopes remain pending for the new destination.

Delete-all is a resumable transaction:

1. increment the delete epoch and atomically write an `inProgress` tombstone;
2. stop new capture and upload leasing;
3. cancel old-epoch foreground/background work;
4. remove all pre-epoch run archives, acknowledgements, quarantine, and staging;
5. verify no old-epoch protected files remain;
6. atomically mark the tombstone `completed`;
7. ignore all late old-epoch callbacks without recreating directories.

If the process exits at any step, cold launch completes the in-progress deletion before outbox scanning, Garmin startup, or new upload leasing. New capture cannot begin until deletion completion is durable.

### 11.5 Background processing task

Optionally register a `BGProcessingTask` to rediscover pending archive work and stage another background transfer. Treat it as opportunistic because iOS controls scheduling.

The background `URLSession` is the transfer mechanism; `BGProcessingTask` is only a chance to prepare work that was not already staged.

If this optional task is implemented, register it during application launch and add `processing` to `UIBackgroundModes` plus every identifier to `BGTaskSchedulerPermittedIdentifiers`. Background `URLSession` itself does not require the processing mode.

## 12. Failure Classification

### 12.1 Transient

Retry indefinitely:

- `URLError` connectivity and timeout failures;
- missing/non-HTTP response;
- response decode failure;
- HTTP 408, 425, 429;
- HTTP 500 through 599;
- incomplete or empty acknowledgement;
- temporary protected-data unavailability after reboot.

Honor valid `Retry-After` while allowing explicit foreground/manual recovery to reevaluate once.

### 12.2 Authentication/configuration block

Block automatic retries until configuration changes or the user explicitly requests one attempt:

- HTTP 401 authentication failure;
- missing token or base URL;
- invalid local server configuration.

Do not disable Garmin capture. Continue archiving and expose the growing pending count.

### 12.3 Rejected-envelope isolation

Add stable machine-readable server error codes before enabling client quarantine. Responses include a safe code and, only when the server can identify it, the offending envelope UUID. They never echo telemetry values.

```json
{
  "error": {
    "code": "invalid_envelope",
    "envelopeId": "uuid-or-null",
    "retryable": false
  }
}
```

Classify request-wide failures separately:

- HTTP 400 malformed JSON/unknown request shape: block as client compatibility failure;
- HTTP 415 content type: block as client implementation failure;
- HTTP 404/405 endpoint mismatch: block configuration;
- HTTP 422 unsupported protocol version: block app compatibility;
- unknown rejection without a safe envelope identifier: block and retain the entire batch.

Use structured ownership codes for HTTP 403:

- `installation_ownership_conflict`: block installation/configuration and require explicit credential or installation repair;
- `envelope_ownership_conflict` with envelope UUID: retry that envelope as a singleton, then quarantine only the reproducibly conflicting envelope;
- unknown ownership conflict without safe attribution: block the batch rather than mislabeling it as authentication or quarantining all envelopes.

The server store must preserve envelope context when returning ownership errors so the API can emit the safe code and envelope UUID. Never expose another user's resource identifiers or ownership details.

Handle size and envelope-specific failures deliberately:

- HTTP 413 with multiple envelopes: reduce batch size and retry without quarantine;
- HTTP 413 with one envelope: reproducibly quarantine that oversized envelope;
- HTTP 409 with an identified envelope conflict: quarantine that envelope and surface a high-severity diagnostic;
- HTTP 422 `invalid_envelope` with an identified envelope: retry it once as a singleton, then quarantine only if the same envelope-specific code repeats.

Isolation algorithm:

1. use a server-provided envelope ID when available;
2. otherwise bisect only for an error code documented as envelope-specific;
3. stop isolation when both halves reproduce the same request-wide/systemic code;
4. require a reproducible singleton envelope-specific rejection before quarantine;
5. continue uploading later envelopes;
6. retain the original envelope in its run archive;
7. never log its complete telemetry body;
8. provide a diagnostic count and envelope ID, not coordinates.

### 12.4 Quarantine retry

Configuration or app-version change may explicitly retry quarantined envelopes. Do not automatically retry the same unchanged poison envelope forever.

### 12.5 Strict local archive recovery

Complete NDJSON lines must never disappear through `try?` or `compactMap` decoding.

Archive scanning returns:

```text
valid envelopes
acknowledgements
local archive issues with run ID, line number, and safe category
```

For a complete undecodable line:

- preserve the original file and raw protected bytes;
- copy or reference the record in protected local-corruption quarantine;
- continue scanning later complete valid lines;
- show a blocking diagnostic count for the affected record;
- never treat the malformed record as acknowledged;
- provide explicit migration for known older envelope formats rather than silently dropping them.

A partial final line retains the existing truncate-on-next-append recovery behavior. A malformed complete line is a different condition and must remain auditable.

## 13. Website and Map Recovery

Map rendering needs no new geometry format, but reliable late-data recovery requires a consistent bootstrap/replay watermark.

### 13.1 Consistent bootstrap endpoint

Replace the frontend's concurrent snapshot and route reads with one server bootstrap contract, implemented from one repeatable-read transaction or equivalent consistent database snapshot.

```text
GET /v1/channels/{slug}/bootstrap

channel/activity metadata
latest sample by authoritative phone-time ordering
full route through the bootstrap high-water cursor
location policy
replayAfterEnvelopeId
```

Within one database snapshot:

1. resolve the active channel activity;
2. capture its maximum committed ingest cursor as the high-water mark;
3. select the latest metrics sample by phone time/authoritative ordering;
4. select all route points at or below the high-water mark;
5. return the envelope ID at the high-water cursor as `replayAfterEnvelopeId`.

The replay cursor is not necessarily the same envelope as the chronologically latest metrics sample. The browser must use `replayAfterEnvelopeId`, not `snapshot.latest.envelopeId`, as SSE `Last-Event-ID`.

Any recovered samples committed after the transaction are replayed after that cursor. If replay exceeds the server limit and requests reset, a fresh bootstrap includes all points through a newer high-water mark and advances the cursor, preventing an endless reset loop.

The TanStack Start session broker consumes this combined response rather than accepting separately fetched route/snapshot data based only on matching activity IDs.

### 13.2 Deterministic route ordering

Use the same route geometry order everywhere:

```text
phone_received_at, envelope_id
```

Change the server full-route SQL from ingest-cursor tie-breaking to envelope UUID tie-breaking. Keep ingest cursor for replay/commit ordering, not equal-timestamp route geometry. The frontend already sorts route points by phone timestamp and envelope ID.

### 13.3 Self-healing behavior

When a backlog for the currently selected activity uploads:

- the server commits samples with original phone timestamps;
- SSE publishes newly committed envelopes;
- the frontend deduplicates by envelope UUID;
- route points are sorted by `phoneReceivedAt`, then envelope ID;
- stale historical samples append route geometry without regressing latest metrics;
- newer recovered samples advance current metrics and marker position;
- the map GeoJSON source updates as route state changes;
- reconnect/bootstrap fetches the complete current route through a consistent replay watermark if the browser missed SSE events.

The map should appear to fill the missing segment, potentially quickly as batches arrive.

Map correction is not possible when:

- the watch never delivered those samples to iOS;
- capture was disabled before archive persistence;
- recovered samples contain no coordinates;
- a newer activity has replaced the old activity on the live channel.

Do not interpolate route points that never reached iOS.

## 14. Server Behavior

No migration is expected.

Retain:

- exact-envelope idempotency;
- original phone timestamps;
- activity UUID supplied by iOS;
- authoritative latest-state ordering by phone time and ingest cursor;
- full-route geometry ordering by phone time and envelope UUID;
- stale old-activity protection for the live channel.

Add tests for:

- a delayed batch with old phone timestamps filling route history;
- duplicate foreground/background submission;
- a large recovered activity arriving in several batches;
- completed catch-up activity selection;
- one rejected envelope not affecting later valid batches after client isolation;
- bootstrap route/snapshot consistency when a batch commits concurrently;
- `replayAfterEnvelopeId` uses ingest high-water rather than the latest phone-time sample;
- a replay reset followed by bootstrap advances beyond more than 200 late events;
- equal phone timestamps use envelope UUID ordering in API and browser.

## 15. Privacy and Security

- Preserve file protection for archives and staged upload bodies.
- Never write ingest tokens into request-body files or diagnostics.
- Never log full request bodies or precise coordinates.
- Treat pending count and oldest age as safe operational metadata.
- Delete staged background request files only after durable acknowledgement or explicit telemetry deletion.
- Delete all staged tasks/files when the user invokes delete-all telemetry.
- Cancel background sessions during credential removal only after preserving pending envelope ownership.
- Fence every completion against configuration generation, destination fingerprint, and delete epoch.
- Reject telemetry redirects in foreground and background sessions.
- Continue honoring explicit capture consent.

## 16. Diagnostics

Track counters and timestamps for:

- watch callbacks received;
- envelopes archived;
- observe-only samples;
- foreground attempts;
- background attempts;
- successful batches;
- transient failures;
- connectivity-restored triggers;
- foreground triggers;
- manual recovery attempts and outcomes;
- authentication blocks;
- quarantined envelopes;
- background relaunch completions;
- oldest pending envelope age;
- last acknowledgement age.

Safe logs may contain abbreviated activity/envelope IDs and error categories. They must not contain coordinates or tokens.

## 17. Testing Plan

### 17.1 Retry coordinator unit tests

1. A newly archived envelope triggers immediate foreground upload.
2. Transient failure follows the expected capped exponential backoff.
3. Connectivity restoration bypasses transient backoff once.
4. Foreground activation bypasses transient backoff once.
5. Repeated triggers do not create parallel foreground submissions.
6. Successful acknowledgement resets backoff.
7. Partial acknowledgement preserves unacknowledged envelopes.
8. Authentication failure blocks automatic retries while capture continues.
9. Configuration change releases the authentication block.
10. Manual retry attempts a permanent block once without looping.
11. Relaunch reconstructs pending work from disk with no in-memory state.
12. Capture pause does not discard or falsely acknowledge pending envelopes.
13. Intact pending envelopes upload while current-session reconciliation remains blocked.
14. Generation change prevents an old-destination completion from journaling acknowledgement.
15. Delete epoch prevents a late callback from recreating archive or acknowledgement directories.
16. Redirect responses do not resend telemetry to another origin.

### 17.2 Connectivity tests

1. `waitsForConnectivity` request succeeds after path restoration.
2. `NWPathMonitor` satisfied transition triggers one retry.
3. Expensive cellular path remains allowed under the chosen product policy.
4. Constrained path behavior matches configuration.
5. Switching Wi-Fi to cellular does not duplicate or lose envelopes.
6. Airplane mode preserves archive growth and pending count.

### 17.3 Manual recovery tests

1. Recovery reconciles an ordinary active session without changing its UUID.
2. Recovery re-enables capture after a reconciliation pause.
3. Recovery resumes a paused receipt pipeline before new receipts are assigned.
4. Recovery forces upload outside the receipt pipeline operation.
5. Recovery with no internet returns waiting state without data loss.
6. Recovery with invalid credentials returns blocked state without a retry loop.
7. Repeated taps are coalesced.
8. Recovery never deletes archives or acknowledgements.
9. A full receipt queue cannot reject the recovery control barrier.
10. Reconciliation failure leaves capture paused but still triggers upload of intact archived envelopes.
11. Callback loss during a full queue is counted and not represented as recovered.

### 17.4 Rejected-envelope tests

1. Request-wide 400 and 415 block without bisection or quarantine.
2. Multi-envelope 413 reduces batch size.
3. Unsupported-protocol 422 blocks app compatibility.
4. Identified envelope-specific rejection is retried as a singleton.
5. One reproducibly invalid singleton is quarantined.
6. Repeated systemic rejection of both halves stops isolation.
7. Later valid envelopes upload and acknowledge.
8. Quarantined telemetry remains in the original archive.
9. Configuration/app-version change can retry quarantine explicitly.
10. Complete malformed local NDJSON lines remain protected and surface a local issue instead of disappearing.
11. Installation ownership conflict blocks configuration without quarantining valid envelopes.
12. Identified envelope ownership conflict isolates only the reproducibly conflicting envelope.

### 17.5 Background session tests

1. Request body and metadata survive process termination.
2. Background completion journals acknowledgements before deleting staging files.
3. Relaunch reconnects existing background tasks to batch metadata.
4. Duplicate foreground/background completion is idempotent.
5. Force-quit limitation is documented and not represented as success.
6. Protected-data unavailable state retries later without corruption.
7. Delete-all cancels tasks and removes staged files safely.
8. Stale-generation completion cannot acknowledge against a new server configuration.
9. Late old-epoch completion after delete-all is a no-op and does not recreate directories.
10. Response bytes are accumulated and parsed only after task completion.
11. AppDelegate background completion fires exactly once after all async archive writes finish.
12. Cold launch reconstructs background leases before foreground outbox submission.
13. Background redirect is rejected without forwarding the body.
14. A crash after each delete-all step resumes deletion before outbox scanning.
15. Late old-epoch callbacks during resumed deletion cannot recreate files.

### 17.6 Bootstrap and map recovery tests

1. Concurrent batch commit cannot produce a newer snapshot with an older accepted route watermark.
2. Browser SSE resumes from `replayAfterEnvelopeId`, not latest phone-time envelope.
3. More than 200 late events cause one reset, then bootstrap advances beyond them.
4. Late historical points fill route geometry without regressing metrics.
5. Equal phone timestamps produce the same envelope-ID route order live and after reconnect.
6. Activity change during bootstrap resets safely to the new activity.

### 17.7 End-to-end physical tests

1. Start a run online, disable phone networking for five minutes, restore it, and verify the map fills the missing route.
2. Repeat while RunSync is foregrounded.
3. Repeat while RunSync is suspended with the phone locked.
4. Restore connectivity without opening RunSync and measure eventual background delivery.
5. Restore connectivity, foreground RunSync, and measure time to first acknowledgement.
6. Press `Recover & Retry` with an existing backlog and verify the same activity UUID continues.
7. Stop/end the Garmin activity while offline, then recover and verify final state and route.
8. Relaunch iOS with pending data and verify automatic recovery.
9. Restart the server while the phone continues archiving, then verify catch-up.
10. Confirm the website reconnect path obtains the complete repaired route.

Record p50, p95, and maximum recovery latency separately for foreground, locked-screen, and system-managed background cases.

## 18. Implementation Phases

### Phase 1: Status and foreground recovery

- Separate watch, archive, connectivity, upload, and acknowledgement status.
- Add the upload coordinator state model.
- Decouple archive-outbox recovery/delivery from capture and activity-session reconciliation.
- Make complete-line archive decoding strict and surface protected local corruption.
- Use a dedicated foreground `URLSession` with `waitsForConnectivity`.
- Reject ingest redirects.
- Add `NWPathMonitor` trigger.
- Make foreground activation bypass transient backoff once.
- Preserve all existing archive/idempotency behavior.

Exit criterion: foregrounding after a simulated outage uploads the backlog automatically.

### Phase 2: Manual `Recover & Retry`

- Add serialized reconciliation/resume flow.
- Add the non-droppable receipt-pipeline control barrier.
- Re-enable capture explicitly.
- Resume the receipt pipeline.
- Force transient upload separately.
- Refresh Garmin status.
- Display structured recovery result.

Exit criterion: one button safely recovers upload-only and locally paused scenarios without changing activity UUID.

### Phase 3: Rejected-envelope isolation

- Add structured server rejection codes and safe offending-envelope identifiers.
- Add status/code-aware reduction and deterministic envelope-specific bisection.
- Add protected quarantine metadata.
- Continue after isolated poison envelopes.
- Add UI diagnostics and explicit quarantine retry.

Exit criterion: one invalid envelope cannot freeze later valid telemetry.

### Phase 4: Consistent website bootstrap

- Add one server bootstrap endpoint with a repeatable-read/high-water contract.
- Return `replayAfterEnvelopeId` separately from latest metrics.
- Update the frontend session broker and SSE resume cursor.
- Align server route ordering with frontend envelope-ID tie-breaking.
- Add reset-loop and concurrent-commit tests.

Exit criterion: late route points cannot be omitted between route bootstrap and SSE replay, including backlogs larger than the replay limit.

### Phase 5: Background transfer

- First ship forward-compatible background-session cancellation, UploadQueue cleanup, and resumable delete-all support with background staging disabled.
- Verify the preflight release can remove all future staging paths and reconnect/cancel the stable background identifier.
- Add background session delegate and AppDelegate integration.
- Add protected staged request files.
- Add persisted configuration generation, destination fingerprint, delete epoch, and deletion tombstone.
- Add transfer leases and relaunch reconstruction.
- Reorder cold launch so background tasks reconnect before foreground recovery.
- Gate the AppDelegate completion handler on durable async finalization.
- Add optional background processing task if justified.

Exit criterion: an offline backlog can complete through a system-managed transfer after connectivity returns without requiring the app to remain foregrounded, subject to documented iOS scheduling limits.

### Phase 6: Physical rollout

- Test Wi-Fi loss, cellular loss, Wi-Fi/cellular handoff, lock, suspension, relaunch, and server outage.
- Verify late data repairs route and final metrics.
- Measure battery, archive growth, and recovery latency.
- Tune timeout/backoff only from physical results.

Exit criterion: all acceptance criteria pass on the supported iPhone and Forerunner 965 workflow.

## 19. Compatibility and Rollout

- No server migration is expected.
- Existing archives and acknowledgement files remain valid.
- Existing activity/envelope UUIDs remain unchanged.
- Deploy iOS foreground recovery before enabling background transfer.
- Deploy the consistent bootstrap API and frontend together before relying on large late-route recovery.
- Ship one preflight iOS release with background-session cleanup and resumable delete-all support before any release stages background telemetry.
- Keep background transfer behind a diagnostic feature flag during physical testing.
- Old iOS builds remain compatible with the API.
- After background staging has been enabled, rollback means disabling it by feature flag in a binary that retains cancellation/delete support.
- Do not downgrade to a binary that predates `UploadQueue` and background-session cleanup while staged tasks or files may exist.
- Before an unavoidable binary downgrade, use the current build to disable capture/background transfer, cancel tasks, and complete protected staging cleanup.
- The existing frontend reducer supports ordered late points, but the session bootstrap/replay contract must be upgraded as described in phase 4.

## 20. Acceptance Criteria

- A transient network outage never disables capture.
- Samples received by iOS while offline remain durably recoverable.
- Foregrounding RunSync after connectivity returns starts a retry without requiring a process restart.
- `Recover & Retry` reconciles session state, resumes capture, and forces upload without changing activity UUID.
- Authentication failures remain blocked and visible without discarding later captures.
- One permanently rejected envelope cannot block later valid envelopes.
- Request-wide client incompatibility cannot quarantine an entire valid backlog.
- Retry state never creates more than one foreground and one leased background batch.
- Relaunch reconstructs pending and background work from protected storage.
- Credential changes and delete-all are safe against late background callbacks.
- Delete-all completes after a crash before any old telemetry can be rediscovered or uploaded.
- Intact archived envelopes can upload while new capture remains paused for reconciliation.
- Late samples for the current activity fill the route in timestamp order.
- Latest metrics do not regress when older backlog samples arrive.
- Browser reconnect obtains the complete repaired route from a consistent high-water bootstrap.
- No token, coordinate payload, or request body appears in logs.
- Physical tests document recovery latency and the remaining force-quit/system-scheduling limitations honestly.

## 21. Known Platform Limits

- iOS may suspend ordinary Swift tasks at any time in the background.
- `NWPathMonitor` does not guarantee process relaunch.
- Background processing task scheduling is discretionary.
- Background `URLSession` improves eventual delivery but does not guarantee live latency.
- User force-quit generally prevents background relaunch until the app is opened again.
- Garmin watch transport does not retain a complete replayable history.
- Samples never received by iOS cannot be reconstructed by RunSync.
