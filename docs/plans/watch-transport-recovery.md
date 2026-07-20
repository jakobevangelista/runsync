# Watch Transport Recovery Plan

## Status

Implemented; physical outage and endurance validation remain pending. This document defines the watch-side recovery work only. It does not
change iOS archival or upload recovery, the server ingest contract, or the
protocol-v1 telemetry payload.

## Problem Statement

The watch sender currently allows one Garmin Communications transmission at a
time. It clears that in-flight state only when Garmin invokes `onComplete` or
`onError`. If Garmin accepts a call to `Communications.transmit()` but invokes
neither callback, `_inFlight` remains true for the lifetime of the sender. New
normal samples continue to replace `_pendingNormal`, but `drain()` cannot send
them.

This matches the observed failure shape:

- The server received sequence 389 and then sequence 549 about 155 seconds
  later during activity `4cb79eee`.
- The same activity later stopped at sequence 599 while the watch remained in
  the running state.
- The phone and server did not later receive the missing sequence range as an
  upload backlog.
- Samples that did arrive had sub-second upload delays, which rules out the iOS
  archive uploader and server ingest path as the source of those gaps.
- A previous activity stopped at sequence 408 near the same physical location.

The watch must therefore be able to declare a transmit attempt stale without a
Garmin callback, release its local send lock, and try the newest useful payload.

## Goals

- Recover automatically when a Garmin transmit attempt receives no callback.
- Keep at most one attempt that RunSync considers active.
- Ignore late callbacks from attempts that have already timed out.
- Preserve latest-value behavior for normal telemetry.
- Preserve terminal-state priority and the existing bounded terminal retry
  policy.
- Bound retry frequency during a prolonged phone, Bluetooth, or Garmin Connect
  outage.
- Expose enough local diagnostics to distinguish healthy, retrying, and
  unavailable transport states.
- Test timeout and stale-callback behavior deterministically without depending
  on real callback timing.
- Require no protocol, iOS, API, database, or web changes.

## Non-Goals

- Buffering every telemetry sample on the watch.
- Reconstructing sequence gaps after the fact.
- Treating watch transport completion as proof of iOS archival or server
  delivery.
- Changing activity identity or terminal-state semantics.
- Adding a phone-to-watch acknowledgement protocol in this change.
- Solving iOS background upload recovery. That remains the responsibility of
  `docs/plans/telemetry-upload-recovery.md`.
- Guaranteeing delivery while the phone, Bluetooth, or Garmin Connect is
  unavailable.

## Current Behavior

`watch/source/TelemetrySender.mc` owns three pieces of queue state:

- `_inFlight`: whether one Garmin transmission is outstanding.
- `_pendingNormal`: the latest normal payload waiting to be sent.
- `_pendingTerminal`: the terminal payload waiting for its next attempt.

`enqueue()` and `enqueueTerminal()` replace their respective pending values and
call `drain()`. `drain()` returns immediately while `_inFlight` is true. A
single reusable listener calls back into `transmissionCompleted()` or
`transmissionFailed()`, which clears `_inFlight` and drains again.

This design is bounded and intentionally drops superseded normal samples, but
it has no concept of attempt identity or elapsed time. A missing callback is
indistinguishable from an operation that is still validly in progress.

`watch/source/RunSyncField.mc` computes a payload approximately once per second
while an activity is active. That recurring compute path provides a natural
place to advance a watchdog. Recovery must not depend on the user navigating
away from and back to the data-field page because Garmin may retain the same
field and sender instance.

## Design Overview

Split transmission bookkeeping into a small deterministic state machine and a
thin Garmin Communications adapter:

1. Enqueue stores only the latest normal payload and the pending terminal
   payload.
2. A `tick(now)` operation expires an active attempt after the watchdog
   deadline and advances any retry cooldown.
3. When eligible, the state machine yields exactly one payload and a new,
   monotonically increasing attempt ID.
4. The Garmin adapter creates a listener bound to that immutable attempt ID and
   invokes `Communications.transmit()`.
5. Completion or error changes state only if the callback attempt ID still
   matches the active attempt.
6. A timeout invalidates the active attempt before another attempt can begin.
   A callback from the invalidated listener is diagnostic-only.

The Garmin API does not expose cancellation. Timeout therefore means that
RunSync stops waiting for the callback; it does not claim that the Garmin
operation was cancelled. The retry cooldown prevents RunSync from rapidly
submitting replacement calls if Garmin still considers an older operation
active.

## State Model

### Queue State

Retain the existing bounded queue:

- One active payload.
- One latest pending normal payload.
- One pending terminal payload.

Normal enqueue replaces `_pendingNormal`. Terminal enqueue replaces
`_pendingTerminal` only when it represents the current terminal event. No FIFO
or activity-sized buffer is added.

### Attempt State

Track these values for the active attempt:

- Attempt ID.
- Payload reference.
- Whether it is terminal.
- Terminal attempt number, if applicable.
- Terminal generation, if applicable.
- Start time from the monotonic Connect IQ timer.

An attempt ID is local sender metadata. It is not added to the protocol payload
and is not sent to iOS.

### Recovery State

Track these values across attempts:

- Consecutive failure or timeout count.
- Timer value at the last failure and the current retry-delay duration.
- Last successful completion time.
- Last transport outcome: success, explicit error, timeout, or synchronous
  transmit exception.
- Aggregate timeout and synchronous-exception counters for diagnostics.

A successful completion resets the consecutive failure count and retry delay.
An explicit error, synchronous exception, or watchdog timeout increments the
failure count and schedules a bounded retry delay.

## Core Invariants

The implementation and tests must enforce all of these invariants:

1. RunSync has zero or one active attempt, never more.
2. Every started attempt has a unique ID for the lifetime of the sender.
3. Only a callback whose attempt ID equals the active attempt ID may clear or
   complete the active attempt.
4. Timeout invalidates the old attempt ID before any replacement attempt is
   started.
5. A stale completion or error callback cannot change queue state, retry state,
   terminal attempt counts, or the active attempt, and returns without pumping.
6. Normal telemetry is latest-value-only. A failed or timed-out old normal
   payload is not reinserted ahead of a newer normal payload.
7. A pending terminal payload is selected before a pending normal payload.
8. A terminal payload remains pending until it succeeds, reaches four total
   submissions, or is superseded by a newer terminal generation. Four
   submissions means one initial attempt and at most three retries.
9. A terminal attempt is counted when it is submitted to Garmin, including an
   attempt that later times out.
10. Every new terminal generation may preempt an older active attempt and clears
    any inherited cooldown so its first submission occurs synchronously in
    `onTimerReset()`. Retries of that same terminal generation obey normal retry
    cooldowns.
11. Explicit errors, synchronous exceptions, and timeouts all obey retry
    cooldowns except for the terminal first-submission rule above.
12. RunSync-owned queue state and live references remain constant with activity
    duration and outage duration. Garmin may retain detached listener objects
    for unresolved operations; that runtime behavior is an acceptance risk, not
    something RunSync can prove bounded without cancellation support.
13. UI transport status is advisory and never changes recording or activity
    lifecycle behavior.

## Watchdog Policy

### Timeout

Start with a 15-second transmit watchdog.

This is long relative to normal watch-to-phone delivery but short enough to
recover from a missing callback while the activity is still useful. It also
limits replacement attempts if the Garmin layer remains busy. The constant
must live in one named location so simulator and physical testing can tune it
without changing state-machine logic.

The watchdog is evaluated from the recurring sender pump, not from a Connect IQ
timer callback. This avoids introducing another asynchronous lifecycle and
keeps state transitions serialized through normal data-field execution and
Garmin listener callbacks.

### Retry Delay

Use bounded exponential delays after non-success outcomes:

| Consecutive failures | Delay before next attempt |
| --- | ---: |
| 1 | 1 second |
| 2 | 2 seconds |
| 3 | 4 seconds |
| 4 | 8 seconds |
| 5 or more | 15 seconds |

The delay applies after explicit errors, synchronous `transmit()` exceptions,
and watchdog timeouts. It resets after a valid successful callback. Every newly
enqueued terminal generation clears any inherited cooldown for its first
submission; retries of that same terminal generation do not bypass cooldown.

The watchdog plus capped delay limits a persistent callback-blackhole case to
roughly two attempts per minute. Physical endurance testing must verify that
this rate does not create unacceptable memory or battery growth in the Garmin
runtime. Increase the cap if that test shows pressure.

### Monotonic Time and Wrap

Use `System.getTimer()` rather than wall-clock time. Store a phase start value
and duration, not an absolute `retryAt = now + delay` deadline. Convert each
signed timer sample to a 64-bit unsigned value in the range `0..2^32-1`, then
calculate elapsed time modulo `2^32`. The measured durations are all far below
the half-range, so this is unambiguous across the signed rollover.

Put this calculation in one shared helper and use it for watchdog age, retry
cooldown, last-completion age, and UI detail text. Confirm the target SDK's
actual timer representation and `Lang.Long` conversion behavior before coding;
do not rely on direct signed subtraction or ordinary deadline comparisons.

Tests must cover a timer wrap or backward-value simulation.

## Attempt-Specific Listener

The existing reusable listener cannot identify which call produced a late
callback. Replace it with a listener instance that captures an immutable sender
reference and attempt ID at construction.

Conceptually:

```monkeyc
class TelemetryTransmitListener extends Communications.ConnectionListener {
    private var _sender;
    private var _attemptId;

    function initialize(sender, attemptId) {
        _sender = sender;
        _attemptId = attemptId;
    }

    function onComplete() {
        if (_sender != null) {
            _sender.transmissionCompleted(_attemptId);
        }
    }

    function onError() {
        if (_sender != null) {
            _sender.transmissionFailed(_attemptId);
        }
    }

    function detach() {
        _sender = null;
    }
}
```

Use the actual callback signatures required by the installed Connect IQ SDK;
the snippet describes ownership, not final API syntax.

Do not mutate the attempt ID or reuse a listener for a later attempt. Reuse
would allow a late callback to observe the replacement ID and incorrectly
complete the current attempt. The only permitted mutation is detaching its
sender reference after completion, error, timeout, or preemption.

RunSync retains only the active listener. On timeout or terminal preemption,
call `detach()` before dropping RunSync's reference. A late callback then
returns inside the detached listener without retaining or invoking the sender.
The Garmin runtime may still retain the small detached listener until it
resolves the old operation, which is why retry frequency and physical memory
testing are part of acceptance. It is not possible to both retry forever and
prove the Garmin-owned unresolved-listener count is bounded without a cancel
API. If physical testing demonstrates retention, add a documented circuit
breaker before rollout rather than reusing listener IDs.

## Pump Algorithm

These valid entry points call one sender pump with an explicit current monotonic
time:

- Normal enqueue.
- Terminal enqueue.
- Recurring data-field compute in every activity state.
- A Garmin completion callback matching the active attempt.
- A Garmin error callback matching the active attempt.

A stale callback increments a diagnostic only while it can still reach the
sender, then returns without pumping. Most listeners invalidated by timeout or
preemption are detached and therefore cannot report a late callback to the
sender; correctness must not depend on observing that diagnostic.

The pump performs these actions in order:

1. If an attempt is active and has crossed the watchdog duration, invalidate it
   by detaching its listener, then record a timeout outcome.
2. If an attempt remains active, stop.
3. If the retry cooldown has not expired, stop.
4. Select a pending terminal payload first; otherwise select the latest pending
   normal payload.
5. Reserve a new attempt ID and set all active-attempt state before invoking
   Garmin code.
6. Create an immutable listener for that attempt and call
   `Communications.transmit()`.
7. If the call throws synchronously, route it through the same active-attempt
   failure transition, guarded by the attempt ID.

Set active state before entering `Communications.transmit()` because the API may
fail or callback synchronously in a simulator or future runtime. No state after
that call may blindly overwrite callback-driven changes.

A matching callback may invoke the pump after its guarded transition so a
pending terminal or normal payload can proceed. A non-matching callback must
return without invoking the pump. The cooldown still decides whether a
replacement is immediately eligible.

### Terminal Preemption

`enqueueTerminal()` is the one urgent exception to ordinary watchdog and
cooldown ordering. When a new terminal generation is enqueued:

1. Store the terminal payload and new terminal generation.
2. If any older normal or terminal attempt is active, invalidate it and detach
   its listener immediately. Count this as a preemption, not as a failure or a
   terminal attempt by the new generation.
3. Clear any cooldown inherited from the superseded normal or terminal
   generation for this new terminal's first submission.
4. Pump immediately from the `onTimerReset()` call stack.

This does not cancel the Garmin operation, but it ensures an unresolved normal
callback cannot prevent the only terminal submission opportunity. A synchronous
Garmin rejection is handled as the terminal's first failed attempt. Subsequent
terminal retries require future execution and obey normal cooldowns.

## Normal Payload Semantics

When a normal payload is selected, remove it from the pending slot and retain it
only as the active payload. While it is active, later computes continue to
replace `_pendingNormal`.

On success, discard the active payload and send the newest pending payload when
eligible.

On explicit error or timeout, discard the active normal payload. Do not put it
back in the pending slot because:

- A newer sample normally exists.
- Sequence gaps are already legal in the current latest-value protocol.
- Retrying stale normal samples increases latency and competes with current
  position.

If no newer sample exists, the next compute will enqueue current telemetry. No
new persistent buffer is required.

## Terminal Payload Semantics

Terminal state remains more important than normal telemetry:

- Terminal enqueue replaces any older pending terminal for the current
  lifecycle, preempts an older active attempt, and is selected before normal
  telemetry.
- Superseding an older terminal increments `terminalCollisionCount` and a new
  `terminalSupersededCount`; it does not increment `terminalExhaustedCount`.
  Exhaustion is reserved for a generation that used all four submissions.
- Selecting a terminal payload increments its attempt count.
- The active attempt retains enough terminal metadata to restore the same
  terminal payload after explicit error or timeout when attempts remain.
- A valid successful callback clears that terminal event.
- Once four total terminal submissions are exhausted, clear the terminal
  payload, record the exhaustion diagnostically, and allow pending normal work
  to continue.

The active attempt must retain its terminal generation. On success, error,
exception, or timeout, alter the terminal slot only if that active generation is
still current. This protects a newer reset or discard event even when an older
attempt callback has a valid active attempt ID. Restoration after failure and
clearing after success both require the generation guard.

A timeout counts toward the terminal attempt limit because Garmin accepted the
submission and may still deliver it. Server ingest is idempotent, so a late old
delivery plus a retry is safe.

## Lifecycle Integration

### `RunSyncField.compute()`

Current code encodes and enqueues in every compute, including waiting, running,
paused, stopped, and ended states. Pass the current timer into enqueue, replace
the pending normal payload first, and then pump. This ordering ensures a
cooldown expiring on that compute sends the newest sample rather than the prior
pending sample. If a future compute path does not enqueue, call standalone
`tick(now)` there so watchdog and cooldown state still progress.

Do not reset sender state when the field becomes hidden or visible. Visibility
changes are not reliable evidence that Garmin cancelled or completed an
operation.

### Activity Start

Do not recreate the sender merely because a new recording starts. Attempt IDs
must remain unique within the sender lifetime, and a late callback from the
previous recording must remain stale after a timeout.

Current lifecycle code does not reset the queue at activity boundaries. Keep
attempt IDs unique for the sender lifetime and do not add a production queue
reset as part of this change.

### Activity Stop, Save, and Discard

`onTimerReset()` must synchronously enqueue, preempt an older active attempt, and
make the first terminal submission before returning. The data field may receive
only a small number of computes after a terminal transition, so verify actual
Forerunner 965 behavior.

If Garmin stops all compute and update callbacks immediately after save or
discard, this change cannot guarantee terminal retries from a timerless data
field. That limitation should remain explicit rather than adding an unverified
background service. Immediate terminal preemption guarantees only the first
submission opportunity; later retries still need another callback or compute.

### Sender Destruction

No callback may assume the field or UI still exists. Keep callback handling
inside sender-owned state and avoid direct view updates. Normal Connect IQ object
lifetime rules should retain the sender through an active listener; verify this
in the target SDK rather than adding global ownership.

## User-Facing Status

Preserve the current lifecycle precedence: `ENDED`, `STOPPED`, `PAUSED`, and
`WAIT GPS` remain more important than transport labels. For `RUNNING` and
`READY`, use these exact transport rules:

- `LIVE`: at least one valid completion occurred within 10 seconds and the
  consecutive failure count is zero.
- `CONNECT`: no valid completion has occurred and no failure is active.
- `RETRY`: one or two consecutive errors, exceptions, or timeouts are active.
- `NO PHONE`: three or more consecutive failures are active.
- `DELAYED`: no failure is active, but the last valid completion is older than
  10 seconds.
- `READY`: timer state is ready and no stronger transport status applies.

Do not show `LIVE` merely because `Communications.transmit()` returned without
throwing. Preserve the current understanding that completion means Garmin
transport completion, not iOS archival or server receipt.

These thresholds intentionally replace the current one-error/no-completion
`NO PHONE` rule. A timeout cannot leave the display indefinitely reporting a
healthy in-flight state. Completion age must use the shared wrap-safe elapsed
helper.

Expose these counters or values through simulator diagnostics and debug logs,
not the protocol payload:

- Active attempt ID and age.
- Consecutive failures.
- Timeout count.
- Stale completion and error counts when an attached listener can report them.
- Preempted and detached listener count.
- Synchronous transmit exception count.
- Terminal attempt count and exhaustion count.
- Pending normal and terminal flags.

Avoid per-second production logging. Log state transitions only, behind the
project's existing debug behavior where applicable.

## Proposed Code Changes

### `watch/source/TelemetrySender.mc`

- Add monotonic attempt IDs and active-attempt timestamps.
- Add a watchdog duration and bounded retry-delay calculation.
- Change completion and failure entry points to require an attempt ID.
- Replace the reusable listener with immutable per-attempt listeners.
- Treat synchronous transmit exceptions as guarded failures.
- Add a public `tick()` or equivalent pump call for computes without enqueue.
- Preserve bounded normal and terminal queues.
- Add transport-state getters needed by `RunSyncField` without exposing mutable
  internals.

Extract queue, attempt, retry, terminal generation, and timer transitions into
one platform-neutral `TelemetrySenderState` class. Every time-dependent method
accepts an explicit `now`; the state class imports neither `System` nor
`Communications`. Keep `TelemetrySender` as the thin BLE adapter that creates
listeners, invokes Garmin, detaches listeners, and translates state actions.
This is one test seam, not an abstraction hierarchy around every Garmin method.

### `watch/source/RunSyncField.mc`

- Pass `System.getTimer()` into enqueue after replacing the latest payload; use
  standalone `tick(now)` only on a path that does not enqueue.
- Derive status from successful completion recency plus recovery state.
- Preserve sequence generation, activity lifecycle, and payload encoding.
- Do not add transport fields to protocol-v1 telemetry.

### `watch/source/SimulatorTelemetrySender.mc`

- Drive the same unannotated `TelemetrySenderState` used by production.
- Match the production sender's public surface, including `tick()` and status
  diagnostics.
- Support deterministic outcome injection: immediate completion, explicit
  error, synchronous throw, no callback, and delayed callback.
- Accept explicit fake timer values so tests never sleep.

### Tests

Add `watch/tests/TelemetrySenderStateTest.mc` and a test jungle/build target for
the Connect IQ unit-test framework. Include the shared state class and a fake
adapter in that target while excluding the BLE adapter. Do not rely on
wall-clock sleeps or Bluetooth hardware for unit coverage. Add one BLE-adapter
compile check to catch the real `ConnectionListener` signatures that the pure
state tests cannot exercise.

## Detailed Test Matrix

### Healthy Path

- First normal enqueue starts attempt 1.
- Valid completion clears attempt 1 and records success.
- A newer pending normal starts after completion.
- Successful completion resets prior failure count and backoff.

### Latest-Value Queue

- While one normal payload is active, enqueue several more samples.
- Verify only the newest pending normal remains.
- After active completion, verify the newest sequence is submitted.
- After active timeout, verify the stale active normal is not reinserted ahead
  of the newest pending sample.

### Missing Callback Recovery

- Start an attempt and provide no callback.
- Advance to just before 15 seconds and verify no replacement starts.
- Advance across 15 seconds and verify the attempt becomes invalid.
- Advance across the retry delay and verify a new attempt starts with a new ID
  and the newest payload.
- Repeat missing callbacks and verify delays cap at 15 seconds.

### Stale Callbacks

- Time out attempt 1 and start attempt 2.
- Invoke the shared state completion and error transitions with attempt 1's ID
  and verify attempt 2, its queue, and retry counters remain unchanged and no
  send action is produced.
- Verify a detached production listener does not call back into its sender.
- Complete attempt 2 and verify normal success behavior.
- Deliver duplicate completion for attempt 2 after it is no longer active and
  verify it is ignored as stale.

### Explicit and Synchronous Failures

- Deliver an explicit Garmin error and verify guarded clear plus cooldown.
- Make `Communications.transmit()` throw synchronously and verify there is no
  stuck active attempt.
- Verify repeated synchronous throws obey capped backoff and do not recurse or
  spin inside one pump call.

### Terminal Priority

- Enqueue terminal while normal telemetry is active.
- Verify the normal listener is detached, the old attempt is invalidated, and
  the first terminal submission is produced immediately without waiting for
  timeout or normal cooldown.
- Invoke the preempted normal attempt's completion and error transitions and
  verify neither affects the terminal attempt.
- Time out a terminal attempt and verify it remains pending when attempts
  remain.
- Deliver a stale callback from the timed-out terminal attempt and verify it
  cannot clear the retried terminal.
- Exhaust four total terminal submissions and verify the terminal clears exactly
  once and pending normal can proceed.
- Enqueue a newer terminal generation before an older generation's callback and
  verify the old callback cannot alter the new event.

### Timer Behavior

- Verify exact timeout and retry boundary behavior.
- Simulate signed 32-bit monotonic timer rollover and verify modulo elapsed
  calculations for watchdog, retry, and completion age.
- Verify long idle periods do not overflow retry calculations.

### Lifecycle and Bounds

- Verify attempt IDs are not reused across activity boundaries.
- Run a fake multi-hour outage and assert bounded RunSync queue state, bounded
  retry rate, and no recursive stack growth.
- Verify simulator and production adapters expose matching sender methods.

## Physical Device Validation

Unit tests cannot establish Garmin runtime callback, memory, Bluetooth, or
data-field lifecycle behavior. Validate on the target Forerunner 965 with the
paired iPhone and Garmin Connect environment.

### Baseline

1. Start an activity with the RunSync field visible.
2. Confirm approximately one-second sequence progression at iOS and the server.
3. Run for at least ten minutes and confirm no false watchdog timeouts under a
   healthy connection.

### Bluetooth Outage

1. Start an activity and confirm live delivery.
2. Disable Bluetooth or move the phone out of range long enough to cross several
   watchdog and retry periods.
3. Confirm the watch enters `RETRY` or `NO PHONE` and remains responsive.
4. Restore connectivity without restarting the activity or changing data-field
   pages.
5. Confirm delivery resumes automatically with the newest sequence.

Expected result: sequence gaps are acceptable; permanent sender lock is not.

### Garmin Connect and Phone Lifecycle

Repeat the outage and recovery flow while:

- Locking and unlocking the phone.
- Backgrounding Garmin Connect.
- Force-closing and reopening Garmin Connect, if the Garmin platform permits
  the expected reconnect.
- Hiding the RunSync data-field page for several minutes and returning to it.

Record whether callback loss is reproducible and whether compute continues while
the field is hidden.

### Terminal During Recovery

1. Establish a transport outage or callback-blackhole condition.
2. Stop, save, and separately discard test activities.
3. Verify the first terminal submission is invoked synchronously from reset even
   when a normal attempt had no callback.
4. Restore connectivity within the available data-field lifecycle window.
5. Verify terminal duplicates are harmless and document whether Garmin continues
   invoking the field long enough for timeout retries after save or discard.

### Endurance

Run at least a two-hour activity with intermittent outages and one sustained
30-minute outage. Observe:

- Watch battery consumption compared with the current version.
- Data-field responsiveness.
- Connect IQ memory usage or app crashes.
- Retry frequency.
- Server sequence gaps and time to resume after connectivity returns.

The test fails if unresolved listener retention causes monotonic memory growth
that threatens the device memory limit. If needed, increase the maximum retry
delay or add a longer cooldown after repeated timeouts; do not restore the
permanent `_inFlight` lock.

## Server-Side Validation

No server deployment is required, but server observations validate the outcome:

- A recovered stream should resume at a newer sequence without a large backlog
  of every missing watch sample.
- `received_at` and device timestamp delays should remain low after recovery if
  iOS upload is healthy.
- Duplicate retried terminal payloads should remain idempotent.
- Activity UUID must not change solely because watch transport recovers.

Compare server gaps with watch timeout counters. A watch timeout followed by a
sequence jump confirms the intended latest-value recovery. A contiguous watch
sequence that reaches iOS but arrives late at the server belongs to the separate
iOS upload recovery investigation.

## Acceptance Criteria

- A no-callback attempt cannot block the sender beyond the watchdog plus retry
  cooldown while compute continues.
- Late completion and error callbacks cannot clear or alter a newer attempt.
- Normal pending storage remains latest-value-only and constant-space.
- A new terminal generation preempts an unresolved normal attempt and gets its
  first submission opportunity before `onTimerReset()` returns.
- Terminal payloads retain priority and bounded retries across timeout, error,
  and synchronous exception paths.
- Retry frequency is bounded during a prolonged outage.
- Status no longer remains falsely healthy after a watch transport timeout.
- Deterministic tests cover healthy, timeout, stale callback, error, exception,
  terminal, timer, and lifecycle paths.
- The watch resumes current telemetry after a real Bluetooth or phone outage
  without activity restart or data-field navigation.
- A two-hour physical endurance test shows no crash, unacceptable battery
  regression, or dangerous memory growth.
- Existing protocol-v1, iOS, server, frontend, and activity segmentation tests
  remain unchanged or pass without behavioral updates.

## Rollout

1. Implement sender state and deterministic simulator tests as one watch-only
   change.
2. Build with the target Connect IQ SDK and resolve actual listener signatures
   and memory constraints.
3. Run simulator fault scenarios, including no callback and late callback.
4. Sideload to the Forerunner 965 and run baseline plus forced-outage tests.
5. Run endurance validation before distributing the watch build broadly.
6. Monitor sequence-gap incidents separately from iOS upload backlog incidents.

Ship this watch recovery before attributing future cutoffs to the upload layer.
The two plans may be developed in parallel, but they should remain separate
changes so each failure boundary and rollback remains clear.

## Risks and Mitigations

### Garmin Still Owns Timed-Out Operations

RunSync cannot cancel `Communications.transmit()`. Replacement attempts may be
rejected or retained by Garmin.

Mitigation: guard all outcomes by attempt ID, apply capped backoff, catch
synchronous exceptions, detach invalidated listeners, and perform physical
memory testing. Terminal first submission deliberately preempts an older Garmin
operation because reset may provide no later execution opportunity.

### Listener Retention

Immutable listeners are required for stale-callback safety, but Garmin may
retain unresolved listeners.

Mitigation: RunSync retains only the active listener, retry frequency is
bounded, invalidated listeners detach their sender reference, and endurance
testing gates rollout. Prefer a longer cooldown or explicit circuit breaker over
listener reuse if memory pressure appears.

### False Timeouts

A watchdog shorter than legitimate Garmin delivery latency could create
duplicates and unnecessary retries.

Mitigation: begin at 15 seconds, measure healthy physical latency, and tune one
constant. Attempt guards and server idempotency make duplicates safe.

### Terminal Lifecycle Window

Garmin may stop invoking a data field shortly after activity save or discard,
leaving no execution opportunity for retries.

Mitigation: terminal enqueue preempts an older active attempt and invokes its
first Garmin submission before `onTimerReset()` returns. Measure whether later
callbacks or computes permit retries and document that limit. A background
architecture or phone acknowledgement would be a separate design, not an
implicit extension of this fix.

### Misleading Success Status

Garmin transport completion does not prove phone archival or server delivery.

Mitigation: keep status wording and documentation scoped to local transport.
End-to-end delivery remains observable through the preview and server data.

## Implementation Checklist

- [x] Confirm target SDK listener callback signatures and `System.getTimer()`
      wrap behavior.
- [x] Add the shared, explicit-time `TelemetrySenderState` and test target.
- [x] Add immutable per-attempt listener IDs.
- [x] Detach invalidated listeners from the sender object graph.
- [x] Add active attempt start time and 15-second watchdog.
- [x] Add bounded retry delays for timeout, explicit error, and exception.
- [x] Guard every callback and synchronous-failure transition by attempt ID.
- [x] Preserve latest normal payload behavior.
- [x] Add terminal generation protection, immediate preemption, and timeout
      retry behavior.
- [x] Pump after newest-payload enqueue on every compute.
- [x] Update transport status and transition diagnostics.
- [x] Add deterministic simulator fault injection and tests.
- [x] Run existing watch, iOS, server, and frontend checks as applicable.
- [ ] Complete Forerunner 965 outage and endurance acceptance tests.
