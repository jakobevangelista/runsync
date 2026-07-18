# RunSync Automatic Activity Segmentation Plan

## 1. Purpose

Make every Garmin native activity map to one durable RunSync activity without requiring a second Start or Stop action in the iOS app.

The Garmin Start button remains the normal user control. The watch reports native activity state, iOS owns the durable session boundary and canonical activity UUID, and the server stores the UUID selected by iOS. A manual iOS action may remain as a recovery tool, but it is not part of the ordinary run workflow.

This plan supersedes the current run-boundary implementation in `TelemetryIngestor.selectRun`. It refines the intended behavior in `docs/plans/runsync.md` section 8.3.

## 2. Incident Summary

Production telemetry exposed two distinct problems.

1. The watch did not deliver a terminal `ended` state. Across more than 12,000 stored samples, the server received waiting, running, and stopped states, but zero ended samples.
2. iOS created an activity UUID for the first valid sample even when Garmin reported only `waiting`. The in-memory run state was lost when the iOS process restarted, and a Garmin start timestamp that appeared later was never copied into the open-run state.

The observed effects were:

- waiting samples from one day and running samples from the next day shared an activity UUID;
- restarting iOS while the watch remained on a Garmin activity screen created another UUID from waiting telemetry;
- the website correctly retained the prior running activity because the newer UUID never received a running sample;
- the server and network path were healthy, but the grouping made the behavior look like an upload failure.

The latest waiting stream was real-time data, not replay. Its phone-to-server delay averaged about 55 milliseconds. Its shape was internally consistent with Garmin's native pre-start state: state waiting, elapsed time zero, no activity start time, no distance, and valid heart rate.

## 3. Current Ownership Model

The components have different responsibilities and must not be conflated.

- Garmin's native Run application creates and records the authoritative fitness activity.
- The RunSync watch component is a passive Connect IQ Data Field. It cannot start, save, discard, or identify a Garmin activity independently.
- The watch emits telemetry and native timer callbacks.
- iOS assigns `localRunID`, which becomes the server's canonical `activity_id`.
- The server never merges activity IDs. It stores the ID supplied by iOS and switches the live channel on a newer running sample.
- The frontend displays the activity selected by the server's live channel.

Activity segmentation therefore belongs primarily in iOS. The watch must provide reliable lifecycle evidence, and the server must continue treating the iOS activity ID as authoritative.

## 4. Goals

- Create no server activity from idle waiting heartbeats alone.
- Create a new activity on the first running sample of a Garmin native activity.
- Keep one activity ID through running, paused, stopped, and resumed states when Garmin is still in the same native activity.
- Close the activity after a reliable ended/reset signal.
- Close locally on a strong implicit reset when Garmin fails to deliver ended.
- Preserve the same activity ID across iOS suspension, termination, crash, and ordinary relaunch.
- Preserve the user's explicit capture consent across relaunch so restored sessions can actually resume ingestion.
- Split activities when the Garmin start time changes or elapsed time clearly resets.
- Serialize Garmin receipts so recovery and boundary decisions use callback order rather than independent task scheduling.
- Treat watch sequence as diagnostic data, not activity identity.
- Keep local persistence before network submission and preserve exact-envelope idempotency.
- Switch the website to a new run within a few seconds of its first accepted running sample.
- Keep memory and watch sender queues bounded.
- Add enough safe diagnostics to explain every boundary without logging coordinates.

## 5. Non-Goals

- Do not replace Garmin's native activity recorder.
- Do not add a required manual iOS Start/Stop workflow.
- Do not infer missing route points or repair Garmin FIT files.
- Do not use watch sequence as a unique session identifier.
- Do not merge or rewrite historical server activities created by older app versions.
- Do not change the public overlay identifier or authorization model.
- Do not add a database migration unless implementation uncovers a server invariant that cannot be preserved otherwise.
- Do not guarantee automatic iOS relaunch after force-quit or device reboot; preserve identity when the app does relaunch and telemetry resumes.

## 6. Fixed Design Decisions

### 6.1 One normal control

The user starts and stops the activity on Garmin. RunSync observes that lifecycle automatically.

The iOS app may expose a diagnostic `End current RunSync session` or `Start new RunSync session` recovery action later. Such an action must record a boundary reason and must not be presented as a required step before every run.

### 6.2 Running starts a server activity

An idle `waiting` sample is an operational heartbeat, not activity telemetry. It updates connection status and diagnostics but does not receive a server-bound activity UUID and is not uploaded.

The first `running` sample creates the activity UUID. A `paused` or `stopped` sample received while no session is open does not create a server activity; iOS waits for a later running sample. This avoids creating history entries for a Garmin screen that was opened but never started.

This intentionally narrows the earlier requirement to archive every valid waiting sample. Idle waiting samples contain no route, elapsed activity, or authoritative run identity. iOS retains lifecycle transitions and counters for diagnostics rather than one durable record per second while idle.

### 6.3 iOS owns durable identity

The watch protocol does not currently contain a durable session UUID. iOS creates a random UUID when a running sample starts a new session and persists enough metadata to restore it after relaunch.

Garmin's activity start epoch is strong external evidence, but not the primary database key. It can be missing before start and may be unavailable on some firmware paths.

### 6.4 Ended is preferred, fallbacks are required

The preferred terminal event is watch state `ended` (`4`). iOS must also close the local session when it sees a strong reset shape after an active session, because Connect IQ teardown may still prevent terminal delivery in some device states.

The minimum implicit-end signal is:

```text
open running/paused/stopped session
  -> waiting sample with elapsed time absent or zero
     and activity start time absent
```

If the last state was stopped, this is the normal save/reset fallback. If stopped was dropped in transport, the same reset shape still prevents the next run from reusing the old UUID.

### 6.5 Protocol v1 remains valid

The existing protocol already requires only version, sequence, and state. A minimal ended payload is therefore valid. No protocol-version bump is required for this work.

An optional watch-generated session identifier may be considered later if physical testing proves Garmin start time and timer callbacks insufficient. It is not required for the first fix.

### 6.6 Capture consent is durable

Precise telemetry capture remains an explicit user opt-in. Once the user enables capture, persist that preference locally and restore it on later launches until the user disables it. This preserves privacy consent without requiring a new toggle after every process restart.

Existing installations default to disabled when first upgrading to this behavior. The status screen must show capture state prominently. Disabling capture stops new assignment/upload immediately but does not silently delete existing archives or corrupt the current session. Re-enabling capture may restore the persisted session when incoming Garmin evidence still matches it; otherwise the normal boundary rules close it and start a new session on running.

### 6.7 One selected capture device

iOS may retain authorization for multiple Garmin devices, but exactly one persisted device is selected as the telemetry capture source. Messages from other authorized devices update connection diagnostics only and never open, split, or close the selected device's session.

Changing the selected capture device is an explicit user action. Block the change while a session is running/paused, or require confirmation that closes the current RunSync session with reason `capture_device_changed`. Do not infer a device switch from an idle heartbeat sent by another authorized watch.

## 7. Target Lifecycle

```text
Garmin waiting
  -> iOS observes only; no activity and no upload

Garmin running
  -> iOS creates or restores one durable session UUID
  -> archive envelope under that UUID
  -> upload envelope
  -> server creates activity and selects it for the live channel

Garmin paused
  -> same UUID

Garmin stopped
  -> same UUID; session remains resumable

Garmin running after stopped
  -> same UUID when start time is unchanged and elapsed time did not reset
  -> new UUID when start time changed or elapsed time materially reset

Garmin ended
  -> ended envelope uses current UUID
  -> archive and enqueue it
  -> close durable iOS session after persistence

Garmin waiting after an active session, with ended missing
  -> close the durable iOS session as an implicit reset
  -> do not upload the idle waiting sample

Next Garmin running
  -> create a new UUID
  -> server atomically switches the live channel
```

## 8. iOS Session State Machine

### 8.1 Isolate boundary logic

Extract the boundary decision from upload orchestration into a small actor-isolated or value-type component, tentatively `ActivitySessionAssembler`. It must be testable without the Garmin SDK, filesystem, or network.

Inputs:

```text
device ID
phone receive time
activity state
Garmin activity start epoch, if present
elapsed time, if present
distance, if present
watch sequence
restored open-session metadata, if any
```

Outputs:

```text
observe only
assign to existing activity UUID
start new activity UUID with boundary reason
assign terminal sample and close activity
close activity without assigning the current non-running sample
```

The assembler must not upload, write files, generate HTTP requests, or update SwiftUI directly.
It returns an immutable proposed transition and proposed next state. It must not mutate committed in-memory state until the caller completes the required durable writes.

### 8.2 Durable session metadata

Persist a versioned metadata record in Application Support. Use the existing protected RunSync storage root.

```text
Application Support/RunSync/session-state.json
Application Support/RunSync/Runs/<localRunID>/metadata.json
```

Suggested current-session shape:

```text
schemaVersion
localRunID
garminDeviceIdentifier
phase: opening | active | paused | stopped
activityStartEpochSeconds, nullable
lastElapsedTimeMilliseconds, nullable
lastDistanceDecimeters, nullable
lastActivityState
lastWatchSequence
openedAt
lastPhoneReceivedAt
lastBoundaryReason
openingSampleEnvelopeID, nullable
pendingPriorClosure, nullable:
  localRunID
  closingReason
  closedAt
```

Per-run metadata records:

```text
schemaVersion
localRunID
garminDeviceIdentifier
openedAt
closedAt, nullable
activityStartEpochSeconds, nullable
openingReason
closingReason, nullable
restoredAfterRelaunch
implicitEndUsed
```

Use atomic replacement and `.completeUntilFirstUserAuthentication`. Metadata must contain no coordinates.

### 8.3 Persistence ordering and recovery

Boundary decisions use a prepare/durably-apply/commit model. The pure assembler proposes a transition without mutating committed state.

For an ordinary sample assigned to an existing session:

```text
prepare proposed next state
-> append and synchronize the envelope
-> atomically update session metadata
-> commit the proposed in-memory state
-> update UI status
-> offer the archived envelope to the uploader
```

For the first sample of a new session or a split from activity A to activity B:

```text
prepare UUID B and boundary decision
-> atomically persist session-state.json with B in opening phase,
   B's expected first envelope ID, and A's closing reason when applicable
-> append and synchronize B's first envelope
-> atomically mark B active and reconcile A's per-run closed metadata
-> commit the proposed in-memory state
-> update UI status
-> offer B's archived envelope to the uploader
```

The opening intent prevents a crash from orphaning B's first envelope or causing the next sample to create UUID C. Its `pendingPriorClosure` identifies activity A and preserves A's exact boundary reason until per-run metadata is reconciled. Recovery handles both opening windows:

- opening metadata with no first envelope: reuse B only if the next sample still satisfies the recorded running boundary; otherwise close the empty opening safely;
- opening metadata whose first envelope exists: finalize B as the current session before processing new Garmin input.

For ended, append and synchronize the terminal envelope before atomically marking the session closed. If the close write fails, the still-open pointer and terminal archive tail let recovery finish the close. For an implicit reset with no assigned envelope, atomically close and clear the current pointer before committing the observe-only decision.

The NDJSON sample archive plus the opening intent are the source of truth. Session metadata is a durable index and recovery aid. Recovery scans the referenced run and any recorded opening envelope, not arbitrary legacy directories.

Startup recovery must happen before newly delivered Garmin messages are assigned. It must recover both:

- pending unacknowledged envelopes for upload;
- the current session identity, even when every prior envelope was already acknowledged.

If multiple legacy metadata files claim to be open, keep the newest valid one and mark older ones closed with `recovery_superseded`. Never silently merge their archives.

Every persistence error leaves the assembler's committed in-memory state unchanged. Recovery-visible opening intent is the only permitted partially applied transition. Closing A and opening B must be represented in one atomic current-session record, including A's ID and closing reason, before separate per-run metadata is reconciled.

After any persistence failure, mark ingestion as `needsReconciliation`, stop the FIFO consumer before receipt N+1, and re-enter the shared recovery barrier. New Garmin receipts may queue in bounded order but cannot reach the assembler until disk and memory agree. If reconciliation cannot complete, stop capture ingestion visibly rather than continuing with stale state.

This rule applies when:

- opening intent succeeds but first-envelope append fails;
- envelope append succeeds but metadata finalization fails;
- an ended envelope is appended but closure metadata fails;
- implicit close or pointer deletion fails;
- closing A/opening B writes only part of the transition.

Recovery must also reconstruct pending upload from any successfully appended envelope, including a terminal envelope whose original ingest call returned an error before enqueue.

### 8.4 Start rules

When no session is open:

- `waiting`: observe only;
- `running`: create a UUID and open a session;
- `paused`: observe only until running resumes;
- `stopped`: observe only;
- `ended`: observe the lifecycle event but do not create an activity.

When an open session has a nil Garmin start and a later sample supplies one, backfill the value into the same session. Do not split merely because the start value changed from nil to known.

### 8.5 Continuation rules

Keep the existing UUID when:

- the sample comes from the selected capture device;
- Garmin start time is equal or remains absent;
- elapsed time is non-regressing within tolerance;
- state changes among running, paused, and stopped;
- stopped returns to running with the same start and continuing elapsed time;
- watch sequence resets while start and elapsed evidence still identify the same activity;
- the phone has a long receive gap but Garmin start and elapsed values continue the same activity.

Do not use a wall-clock receive gap alone to split a run. iOS suspension and BLE gaps are expected.

### 8.6 Discontinuity and new-run rules

Evaluate device, start-time, and elapsed discontinuities before deciding whether a sample may attach to the open session.

For an incoming running sample, start a new UUID before assignment when any of these applies:

- both stored and incoming Garmin start times exist and differ;
- Garmin start time is unavailable and elapsed time materially reset;
- the prior session was closed by ended or implicit reset;
- the user explicitly requested a diagnostic new-session boundary.

A material elapsed reset should tolerate ordinary reordering and one-second jitter. Initial thresholds:

```text
incoming elapsed <= 5 seconds and prior elapsed >= 30 seconds
or
prior elapsed - incoming elapsed >= 10 seconds
```

If a stable, equal Garmin start time is present, it wins over elapsed jitter; record the regression diagnostically but keep the same UUID. Tune thresholds only from captured hardware traces.

Distance regression is corroborating evidence, not a boundary by itself. GPS and distance fields can be absent or corrected.

After filtering to the selected capture device, for incoming paused or stopped samples:

- attach to the open session only when start/elapsed evidence is compatible;
- when start or material elapsed evidence indicates another activity, close the old session and observe the current non-running sample without creating a new activity;
- a later running sample starts the new activity.

For incoming waiting samples:

- never attach or upload the waiting sample;
- close the open session when it has the strong reset shape defined in section 6.4;
- if waiting retains a compatible start and nonzero elapsed value, keep the session open but record an anomalous waiting transition;
- if the waiting sample comes from a non-selected device, update diagnostics only and leave the selected device's session unchanged.

For an incoming ended sample:

- attach and close only when device and known start evidence match the open session;
- when a non-null start conflicts, treat it as stale or foreign, observe it, and leave the current session unchanged;
- when no start is available, rely on the serialized receive order from the same device and record that weaker match.

All states from a non-selected device are observe-only for activity segmentation. An explicit selected-device change is handled as a configuration boundary before telemetry from the new selected device is admitted to the assembler.

### 8.7 Close rules

For `ended`:

1. assign the ended sample to the current UUID;
2. append and synchronize it;
3. persist closed metadata with reason `watch_ended`;
4. clear the current-session pointer;
5. enqueue the ended envelope for upload.

For an implicit reset to waiting:

1. persist closed metadata with reason `implicit_timer_reset`;
2. clear the current-session pointer;
3. update diagnostics;
4. treat the waiting sample as observe-only.

Stopped is not terminal by itself because Garmin permits resuming before save/discard.

### 8.8 Out-of-order and stale lifecycle events

The watch sender must order a terminal event before later waiting telemetry. iOS should still reject an ended event as a boundary for the current run when it demonstrably belongs to a different known Garmin start time.

If an ended payload has no start time, apply it to the current open session only when it arrives in normal receive order from the same device. Record sequence regression and delayed terminal decisions in diagnostics.

Capture receive time at the Connect IQ delegate callback, not later inside `TelemetryIngestor`. Replace independent per-message tasks with one FIFO receipt pipeline. Assign a callback-order ordinal for diagnostics and ensure `phoneReceivedAt` is strictly ordered for receipts in one process, even if the wall clock has insufficient resolution. The single consumer must not process receipt N+1 before N.

Startup recovery is an initialization barrier in `TelemetryIngestor`. Every ingest call awaits one shared recovery task before asking the assembler for a decision. Actor isolation alone is insufficient because archive I/O suspends and permits reentrancy. Device/message registration may happen earlier, but receipts must queue behind the barrier.

Pending-envelope recovery uses deterministic ordering by phone receive time and a stable local tie-breaker. New live receipts are merged after recovered records without replacing them. Delayed waiting/reset receipts are subject to the same compatibility rules and cannot close a newer session solely because their processing task ran late.

Duplicate envelopes remain harmless because envelope UUID is the server idempotency key. Watch sequence remains non-unique.

## 9. iOS Integration Changes

### 9.1 `TelemetryIngestor`

Replace `OpenRun` and `selectRun` with the session assembler.

Required changes:

- make the known activity start mutable and durable;
- restore current-session metadata before normal ingestion;
- introduce an ingestion outcome that can represent either an assigned envelope or an observe-only sample;
- return observe-only for every waiting sample;
- return observe-only for paused, stopped, or ended when no compatible session is open;
- keep compatible paused, stopped, and ended samples attached when a session is already open;
- create envelopes only when the assembler assigns an activity UUID;
- close only after terminal persistence succeeds;
- keep uploader retry and exact acknowledgement behavior unchanged;
- clear current-session metadata when all local telemetry is deleted.
- gate all assignment behind one recovery task so a live receipt cannot create a UUID before restoration finishes;
- apply proposed assembler state only after the archive/metadata operation required by that transition succeeds.

Do not couple session state to whether the server acknowledged the latest envelope. A run remains the same run during network outages.

### 9.2 `TelemetryArchive`

Add:

- atomic read/write/delete operations for current-session metadata;
- atomic per-run metadata updates;
- efficient reading of the latest complete envelope for recovery;
- recovery for a partial metadata write or a partial final NDJSON line;
- legacy behavior for run directories that have no metadata.

Do not mark observe-only waiting samples as server-acknowledged. They are not envelopes and never enter the upload queue.

### 9.3 `GarminConnectionService` and UI status

The Garmin connection remains responsible for decoding and forwarding every valid sample. Capture callback time immediately and feed decoded receipts to one ordered consumer rather than creating an independent ingestion task for each message. An observe-only result still updates:

- last telemetry receipt time;
- watch connection health;
- displayed Garmin activity state;
- sequence-gap and rejection diagnostics.

Display RunSync session state separately from Garmin timer state:

```text
Garmin activity: Waiting / Running / Paused / Stopped / Ended
RunSync session: None / Active / Paused / Stopped / Restored
Current activity: abbreviated UUID or None
```

This prevents a green telemetry indicator from implying that a server activity is active.

### 9.4 Capture preference

Move capture consent out of the process-only `AppModel.captureEnabled` default.

- Persist the explicit user choice in local preferences without storing telemetry or credentials in that preference record.
- Persist one selected capture-device identifier alongside capture settings; authorization for other devices may remain cached.
- Default existing/upgraded installations to disabled until the user opts in once.
- Restore the preference before Garmin receipts are released through the recovery barrier.
- Show enabled/disabled state continuously and provide a clear disable action.
- Disabling capture stops assignment immediately; it does not delete archives or revoke the server credential.
- Ignore non-selected device telemetry for session boundaries and show it only in device diagnostics.
- Add a separate delete action for destructive removal, as today.

Privacy acceptance requires explicit initial opt-in. Lifecycle acceptance requires that a previously granted opt-in survive an ordinary process relaunch.

## 10. Watch Terminal Delivery

### 10.1 Root cause

`RunSyncField.onTimerReset` currently sets fallback state to ended, but it does not transmit. A later `compute` reads Garmin `TIMER_STATE_OFF`, and `TelemetryEncoder` converts that back to waiting before ended is sent. Garmin may also tear down the field before another compute callback.

### 10.2 Immediate terminal payload

On `onTimerReset`, construct and enqueue a minimal terminal payload immediately:

```text
v: protocol version
q: next watch sequence
st: ended
rt: most recently known Garmin activity start, when available
```

All other telemetry fields remain optional. Increment sequence exactly once for the terminal payload. Clear the cached activity start only after the terminal payload has entered the sender.

Cache the most recently encoded Garmin start time in `RunSyncField` so the terminal event can identify the run even when reset-time `Activity.Info` is unavailable.

Maintain a per-native-lifecycle `terminalEnqueued` latch. The first reset callback enqueues one terminal and increments sequence once. Repeated reset callbacks for the same lifecycle are ignored and counted diagnostically. Reset the latch only when a later timer-start callback begins a new native lifecycle; pause/resume does not reset it.

### 10.3 Priority sender slot

The current sender has one in-flight payload and one replaceable latest payload. A terminal payload waiting behind an in-flight sample can currently be replaced by a later normal sample.

Change the bounded queue to:

```text
one in-flight payload
one non-replaceable terminal payload
one replaceable latest normal payload
```

After an in-flight transmission completes or fails:

1. send the terminal payload first;
2. then send the latest normal payload;
3. continue latest-value-wins behavior for ordinary telemetry.

The queue remains bounded. No historical replay is added to the watch.

The terminal slot owns retry state. A synchronous transmit exception or asynchronous failure must not recursively retry on the same call stack. Retain the terminal for the next sender opportunity and retry at most three times, always before normal pending telemetry. On terminal completion or retry exhaustion, clear the slot and continue with the latest normal payload. Count terminal completion, retry, exhaustion, and duplicate enqueue separately.

If a second native lifecycle somehow produces another terminal while the prior lifecycle's terminal still occupies the slot, record a collision, mark the older terminal exhausted, and replace it with the newer lifecycle's terminal. Favoring the current lifecycle prevents stale terminal delivery from closing a newer iOS session. Physical tests must establish whether this can occur; do not add an unbounded terminal queue.

Transport completion still means only that Connect IQ completed transmission. It does not prove iOS persistence or server acknowledgement.

### 10.4 Timer-state behavior after ended

After terminal enqueue, later `TIMER_STATE_OFF` samples may return to waiting. That is expected. Sender priority guarantees that ended is offered before those waiting samples.

The watch display may show `ENDED` briefly and then `READY`. Do not retain a stale ended label indefinitely if Garmin continues computing in the pre-start state.

## 11. Server Behavior

No schema change is expected, but ingestion selection needs one behavioral fix for recovered batches.

The existing server contract remains correct:

- iOS activity UUID is canonical;
- a running sample can attach a newer activity to the live channel;
- ended state sets `activities.ended_at`;
- waiting samples do not attach an activity to the live channel;
- raw sample ordering is authoritative by phone receive time and ingest cursor, not request arrival order.

The current store considers only the latest event for each activity when selecting a channel candidate. A first recovered batch containing `[running ... ended]` therefore creates and ends an activity but never selects it because its latest event is ended.

Change candidate selection so an authoritative activity that contains at least one newly inserted running event is eligible even when its authoritative latest event is paused, stopped, or ended. Compare/channel-order the candidate using that activity's authoritative latest phone timestamp and ingest cursor, then publish its final state. This makes a completed offline activity visible as the latest activity without pretending it is still running.

Add or retain regression tests proving:

- an ended sample updates the existing activity rather than creating another;
- a newer running activity replaces the live channel's old activity;
- a first catch-up batch containing running and ended selects the activity and exposes its final state;
- a late batch whose authoritative ordering key predates the selected activity cannot reclaim the channel;
- replayed duplicate envelopes remain idempotent;
- stopped and ended final snapshots remain readable after refresh.

If the watch terminal event remains absent in physical tests, do not synthesize fake watch telemetry in iOS. The old server activity may remain stopped while iOS closes it locally; the next running activity will still receive a new UUID and replace it on the website.

## 12. Diagnostics and Observability

Record boundary decisions without telemetry values that reveal location.

### 12.1 iOS counters

- sessions opened;
- sessions restored after relaunch;
- sessions closed by watch ended;
- sessions closed by implicit reset;
- sessions split by changed Garmin start;
- sessions split by elapsed reset;
- sessions closed by explicit selected-device change;
- idle waiting samples observed but not uploaded;
- stale terminal samples ignored;
- session metadata recovery failures;
- opening intents recovered or abandoned;
- receipts queued behind startup recovery;
- receipt-order anomalies;
- terminal queue retries, exhaustion, duplicates, and collisions.

### 12.2 Safe boundary log

Each boundary log may contain:

```text
timestamp
abbreviated local run ID
reason enum
old and new activity-state labels
whether start time was present/equal/changed
whether elapsed was absent/continued/regressed/reset
whether the session was restored
```

Do not log coordinates, full payloads, access tokens, or precise route values.

### 12.3 Server verification queries

During rollout, verify:

- each Garmin start epoch maps to one activity UUID;
- one activity UUID does not contain multiple distinct non-null Garmin start epochs;
- no new activity consists entirely of waiting samples;
- ended samples begin appearing after the watch update;
- the live channel switches on the first running sample of each new UUID;
- phone-to-server delay remains normal.

These are operational checks, not permanent application behavior.

## 13. Test Plan

### 13.1 Pure iOS assembler tests

Test every transition with deterministic UUID and clock injection.

1. Waiting for ten minutes creates no activity.
2. Waiting followed by running creates one activity at running.
3. Waiting followed by app restart and more waiting creates no activity.
4. Running followed by running retains one UUID.
5. Running, paused, and resumed retains one UUID.
6. Running, stopped, and resumed with equal start and continuing elapsed retains one UUID.
7. Running, stopped, and waiting closes implicitly.
8. Running directly to waiting closes implicitly when stop was dropped.
9. Running followed by ended assigns ended to the current UUID, then closes it.
10. Ended while idle creates no activity.
11. Nil start followed by a known start backfills without splitting.
12. A changed non-null start creates a new UUID.
13. Material elapsed reset without a known start creates a new UUID.
14. One-second elapsed regression does not split.
15. Equal start with elapsed jitter does not split.
16. Explicit selected-device change closes the old session, and later running from the new selected device creates a new UUID.
17. Sequence reset with stable start and elapsed does not split.
18. Long receive gap with stable start and elapsed does not split.
19. Explicit diagnostic boundary closes the old UUID and records its reason.
20. A stale ended event with a mismatched known start does not close the current activity.
21. Paused or stopped with a changed start closes the old session and remains observe-only.
22. Paused or stopped with a material reset and no start closes the old session and remains observe-only.
23. A compatible non-reset waiting sample is observe-only but does not close the session.
24. Waiting, running, paused, stopped, or ended from a non-selected device cannot close or split the selected device's session.
25. A delayed stale waiting/reset receipt cannot close a newer incompatible session.

### 13.2 iOS archive and recovery tests

1. Relaunch during running restores the same UUID.
2. Relaunch during paused restores the same UUID.
3. Relaunch during stopped, then resume, retains the same UUID.
4. Relaunch after ended has no open session.
5. Acknowledging all envelopes does not erase current-session identity.
6. Pending envelopes and current-session state recover independently.
7. Crash after persisting an opening intent but before the first envelope reuses or safely abandons the intended UUID.
8. Crash after the first envelope append but before opening metadata is finalized restores that UUID.
9. Crash while splitting from A to B cannot leave the pointer on A after B's first envelope exists.
10. Partial NDJSON tail and partial metadata replacement do not merge or lose runs.
11. Delete-all removes samples, acknowledgements, run metadata, and current-session metadata.
12. Legacy run directories without metadata remain uploadable and do not become an open session automatically.
13. Observe-only waiting samples never enter pending upload counts.
14. Envelope, opening-intent, metadata-finalization, close, and pointer-deletion failures do not commit incorrect assembler state.
15. A Garmin receipt arriving while recovery is suspended waits and then uses the restored UUID.
16. Equal-resolution callback timestamps retain deterministic FIFO order.
17. Explicit capture opt-in survives relaunch; an installation that never opted in remains disabled.
18. Disabling and re-enabling capture does not silently merge incompatible Garmin activities.
19. A partial persistence failure blocks the next receipt until reconciliation succeeds.
20. A split opening intent restores the prior activity ID and exact closing reason from `pendingPriorClosure`.
21. The selected capture device survives relaunch and non-selected devices remain diagnostics-only.

### 13.3 Watch tests

Use simulator/unit support where possible and physical hardware for callback order.

1. `onTimerReset` creates one state-4 payload without waiting for compute.
2. Terminal payload increments sequence once.
3. Terminal payload includes cached start time when available.
4. Normal payload cannot replace a queued terminal payload.
5. Terminal payload is sent before the latest pending normal payload.
6. Repeated ordinary samples remain latest-value-wins.
7. Sender memory remains bounded during prolonged transport failure.
8. Start, pause, resume, stop, reset, and return-to-waiting produce the expected UI labels.
9. Saving and discarding a native activity both exercise reset behavior.
10. Hiding the RunSync data page does not invalidate the measured lifecycle assumptions.
11. Repeated reset callbacks enqueue exactly one terminal for that lifecycle.
12. A synchronous transmit exception retains the terminal without recursive retry.
13. Terminal retry exhaustion releases the latest pending normal payload.
14. A second-lifecycle terminal collision remains bounded and favors the newer terminal.

### 13.4 Server tests

1. First running envelope creates and attaches an activity.
2. Ended updates that activity's final state and timestamp.
3. A second activity's first running sample atomically switches the channel.
4. A first batch containing running through ended selects that completed activity and exposes ended state.
5. An old-activity sample with an earlier authoritative ordering key cannot switch the channel back.
6. Full route and final snapshot remain associated with the correct UUID.

### 13.5 End-to-end physical scenarios

Run each scenario with the Forerunner 965 and iPhone while recording safe diagnostics and server timestamps.

1. Open Garmin Run for five minutes without pressing Start; website remains on the prior activity and no server activity is created.
2. Start, run for several minutes, save, and verify one UUID plus ended state.
3. Start, pause, resume, stop, resume, then save; verify one UUID.
4. Complete two consecutive runs; verify distinct UUIDs and no route/metric crossover.
5. Lock the iPhone throughout a run; verify one UUID.
6. Terminate and relaunch iOS mid-run; verify the restored UUID continues.
7. Lose network connectivity, finish the run, reconnect, and verify archived envelopes retain one UUID and upload in order.
8. Restart the home server during a run; verify retries do not alter the activity UUID.
9. Disable Bluetooth briefly and reconnect; verify sequence gaps do not split the activity.
10. Force a missing terminal event during testing and verify stopped-to-waiting fallback closes locally and the next run gets a new UUID.
11. Relaunch with capture previously enabled and verify ingestion resumes without a second consent action.

## 14. Implementation Phases

### Phase 1: Characterization and fixtures

- Capture safe state/start/elapsed/sequence traces for start, pause, resume, stop, save, and discard.
- Add tests that reproduce the current nil-start and relaunch bugs before changing behavior.
- Confirm callback ordering on the Forerunner 965.

Exit criterion: the failing tests reproduce the production grouping behavior.

### Phase 2: Pure iOS session assembler

- Implement the state machine independently of archive and upload code.
- Add deterministic boundary tests.
- Replace direct `selectRun` decisions with assembler outcomes.
- Introduce the FIFO Garmin receipt path and startup recovery barrier.
- Keep HTTP and server contracts unchanged.

Exit criterion: all transition tests pass and waiting alone cannot create an envelope.

### Phase 3: Durable session recovery

- Add current-session and per-run metadata.
- Add durable opening intent and prepare/commit persistence semantics.
- Restore identity before normal Garmin ingestion.
- Persist explicit capture consent and restore it before releasing queued receipts.
- Add crash-consistency and legacy archive tests.
- Expose restored state and boundary reason in diagnostics.

Exit criterion: an iOS relaunch during running continues the same UUID with all envelopes acknowledged or pending.

### Phase 4: Watch terminal reliability

- Emit an immediate minimal ended payload from reset.
- Add cached Garmin start time.
- Add a protected terminal sender slot.
- Validate save and discard on physical hardware.

Exit criterion: repeated native activities produce a state-4 payload before waiting, or the exact remaining platform limitation is documented from hardware traces.

### Phase 5: Server regression coverage

- Fix candidate selection for a first catch-up batch whose latest state is no longer running.
- Add lifecycle and live-channel transition tests.
- Confirm no migration is required.
- Add temporary rollout queries or an operations note.

Exit criterion: live and completed catch-up activities select correctly, and samples ordered before the selected activity cannot reclaim the channel.

### Phase 6: Staged rollout

- Build and install iOS/watch changes from the Mac development environment.
- Upgrade outside an active run because the first build with durable metadata cannot restore the old in-memory `OpenRun`.
- Run pre-start, one-run, two-run, pause/resume, and iOS-relaunch acceptance scenarios.
- Monitor server activity IDs, start times, states, and channel selection.
- Remove temporary verbose diagnostics after confidence is established.

Exit criterion: two consecutive real activities remain fully segregated and the website switches automatically on each first running sample.

## 15. Compatibility and Migration

- Existing server activities remain untouched.
- Existing NDJSON envelopes retain their UUIDs and remain eligible for exact-ID retry.
- Existing run directories without metadata are treated as legacy closed runs for session-restoration purposes.
- The first upgraded iOS launch starts a new UUID on the next running sample unless valid new-format session metadata exists.
- Deploy the initial upgrade while no Garmin activity is running to avoid splitting one in-progress run at the upgrade boundary.
- Protocol v1 payloads remain accepted by old and new iOS builds.
- The server can be deployed before or after the client changes because the ingestion contract does not change.
- Reverting the iOS/watch build does not require a database rollback, though old activity-boundary behavior would return.

## 16. Risks and Mitigations

### Garmin omits reset callback

Mitigation: iOS closes on the strong active-to-waiting reset shape and starts the next running sample under a new UUID.

### Garmin permits resume after stopped

Mitigation: stopped remains open. Only ended, reset-to-waiting, changed start, or material reset closes/splits it.

### One incorrect waiting sample appears during a run

Mitigation: require the complete reset shape, record the reason, and validate physical traces. If hardware shows transient OFF states, add a small bounded confirmation window before closing.

### iOS exits between sample and metadata writes

Mitigation: persist a durable opening intent before the first envelope, use append-only NDJSON for assigned samples, and reconcile opening/current metadata from the recorded envelope ID and latest complete record.

### Garmin receipt arrives during startup recovery

Mitigation: queue all receipts behind one shared recovery barrier and process them through a FIFO consumer after restored session and capture-consent state are ready.

### Capture consent resets after relaunch

Mitigation: persist explicit opt-in, default upgrades to disabled until the first choice, and continuously expose the restored setting in the UI.

### Upgrade occurs mid-run

Mitigation: stage the first upgrade outside an activity. Do not guess an old in-memory UUID that was never persisted.

### Terminal event is delayed behind normal telemetry

Mitigation: reserve a non-replaceable terminal sender slot and send terminal before pending normal telemetry.

### Waiting diagnostics are lost

Mitigation: retain counters, latest state, and lifecycle transitions. Do not archive one identical idle sample per second indefinitely.

### Start time changes unexpectedly within one Garmin activity

Mitigation: capture diagnostics and physical traces. Start-time change remains a strong split signal because merging two real runs is more damaging than an occasional split.

## 17. Acceptance Criteria

The work is complete when all of the following are true.

- Opening Garmin Run without pressing Start for at least ten minutes creates no server activity.
- The first running sample creates an activity and switches the website within five seconds under normal connectivity.
- Pause/resume and stop/resume retain one activity UUID.
- Saving an activity produces ended state on the server in normal physical tests.
- If ended is missed, iOS closes locally on reset and the next running sample receives a different UUID.
- Restarting iOS mid-run retains the same activity UUID.
- Previously granted capture consent survives the iOS relaunch, while a user who has not opted in remains disabled.
- Restarting the server or losing network does not change activity identity.
- A completed activity uploaded for the first time as one running-through-ended catch-up batch becomes the selected final activity.
- Two consecutive runs have distinct UUIDs, distinct Garmin start times, and no route points from one run in the other.
- No activity UUID created by the upgraded client contains more than one distinct non-null Garmin start epoch in acceptance testing.
- Watch sequence reset alone never creates a new activity.
- All new lifecycle, archive, watch sender, server transition, and physical acceptance tests pass.
- Diagnostics can state why every activity opened, restored, split, and closed without logging precise telemetry.

## 18. Future Enhancements

Only consider these after the automatic v1 lifecycle is proven on hardware.

- Add an optional watch-generated session identifier if Garmin start time remains unreliable.
- Add a user-visible recovery control for manually ending a stuck RunSync session.
- Add activity history and cleanup UI using existing server activity APIs.
- Add a server-side health warning for an activity that remains running or stopped beyond a configurable duration.
- Add automated database checks for multiple Garmin starts under one activity UUID.
- Revisit bounded local lifecycle trace retention after measuring storage and battery use.
