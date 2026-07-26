# Connect IQ End-to-End Transport Recovery Plan

## Status

Implemented and physically verified in
[PR #3](https://github.com/jakobevangelista/runsync/pull/3), merged
2026-07-26.

The recovery coordinator, registration-generation fencing, manual repair
workflow, and primary Bluetooth outage/reboot scenarios landed. Extended
30-minute and two-hour locked-screen endurance runs, deterministic confirmation
of the authorization-required UI, and server/backlog verification remain
follow-up work. See `docs/macbook-connect-iq-recovery-handoff.md` for the
execution record and remaining uncertainties.

This plan addresses the failure where the Garmin watch remains connected and
continues producing telemetry, but RunSync stops receiving Connect IQ app
messages. It also separates that failure from the currently outdated server
deployment, which rejects the new diagnostic payload.

The recommendation is a narrow rebuild of the iOS Connect IQ connection layer,
not a rewrite of RunSync, the watch sender, or the durable upload pipeline.

## 1. Executive Decision

The current incident is not best explained by a dead watch, a stopped data
field, a generic Bluetooth radio outage, or an HTTP outage:

- The watch was running build `a7457b656cb4`.
- Its telemetry sequence/queue indicator continued increasing.
- Watch transport timeouts and failures remained at zero while Bluetooth was
  enabled.
- Turning iPhone Bluetooth fully off caused watch transport failures to rise.
  Turning Bluetooth back on stopped those failures, so the watch again saw
  Garmin's transport as available.
- Garmin Connect showed the watch as connected.
- RunSync's `receivedMessage` count and receipt timestamp did not advance.
- Foregrounding or relaunching RunSync, reauthorizing the watch, and rebooting
  the phone did not restore app-message delivery during the activity.

That evidence places the primary failure between Garmin accepting the watch
transmission and the iOS SDK invoking RunSync's app-message delegate. Garmin's
watch-side completion callback is not an end-to-end acknowledgement.

There are also two concrete gaps in the iOS code:

1. `replaceDevices` registers replacement device and app-message delegates
   without first unregistering the old registrations.
2. `Recover & Retry` repairs capture/session/upload state and probes app status,
   but it does not replace or repair the Connect IQ registration.

Garmin documents explicit unregister methods for both device events and app
messages. Garmin also warns that ambiguous app-message registrations have
undefined delivery behavior. The exact internal SDK failure cannot be proven
without Garmin's private logs, but RunSync's lifecycle is currently too
happy-path-oriented to recover from it.

A separate deployment issue must be fixed first: the running API predates the
transport diagnostic schema and rejects the new client payload with HTTP 400.
That blocks upload after receipt; it does not explain why iOS receives no
messages from the watch.

## 2. Confidence and Open Questions

### High-confidence conclusions

- The current watch watchdog is operating and is not stuck waiting for a
  callback.
- The physical Bluetooth link can fail and recover independently of RunSync's
  app-message stream.
- The latest observability implementation diagnosed the boundary but did not
  implement iOS transport recovery.
- `getAppStatus` is a status request, not a documented reset operation.
- The current `Recover & Retry` label promises more than the implementation
  performs.
- The server deployment and Connect IQ delivery are two separate faults.

### Questions the implementation and physical tests must answer

- Does an app-message-only unregister/register restore delivery?
- If not, does replacing both device-event and app-message registrations
  restore delivery?
- Does a freshly returned `IQDevice` from Garmin authorization matter, or is
  registration ownership the deciding factor?
- Does the cutoff correlate with elapsed time, a route location, iPhone
  suspension, or a Garmin SDK state transition? The repeated course currently
  confounds time and location.
- Can a lightweight phone-to-watch acknowledgement be received reliably by the
  RunSync data field on the target Forerunner?
- If explicit re-registration cannot recover the SDK, can the behavior be
  reproduced in a minimal Garmin sample app for escalation?

## 3. Definition of Done

RunSync is considered recovered only when all of these are true:

- After a temporary Bluetooth outage, new watch messages resume without
  restarting the Garmin activity.
- A stale app-message stream is detected while RunSync is runnable.
- Automatic repair performs bounded, explicit registration replacement.
- `Recover & Retry` performs the same transport repair immediately, in addition
  to its local archive/session/upload work.
- The UI distinguishes physical/device status, Connect IQ app-message freshness,
  local archival, and server upload.
- A status request, delegate-registration call, or watch transmit completion is
  never displayed as proof of end-to-end recovery.
- Recovery success requires a new valid `receivedMessage` callback.
- Repeated repair does not create duplicate registrations or duplicate receipt
  processing.
- An archived backlog survives transport and network failure and uploads after
  the server deployment is corrected.
- The physical acceptance matrix passes on the actual watch and iPhone.

RunSync cannot promise background recovery after the user force-quits the app.
Apple explicitly excludes force-quit from normal Bluetooth restoration
relaunch, with additional relaunch restrictions beginning in iOS 26. When the
user opens RunSync again, foreground recovery must run immediately.

## 4. Fixed Design Decisions

### 4.1 Rebuild only the iOS transport boundary

Keep:

- the watch sender state machine and watchdog;
- latest-value-only watch queuing;
- Garmin's activity and data-field lifecycle;
- `GarminReceiptPipeline`;
- the durable iOS archive and idempotent upload design;
- the server activity/session model.

Replace or refactor:

- Connect IQ SDK ownership inside `GarminConnectionService`;
- device and app-message registration lifecycle;
- stale-stream detection;
- transport repair orchestration;
- the transport portion of `Recover & Retry`.

### 4.2 One owner, one registration generation

One `GarminTransportCoordinator` owns every active `IQDevice`, `IQApp`, device
delegate registration, and app-message delegate registration.

It maintains a monotonically increasing registration generation. Replacement
must be ordered:

1. Fence callbacks and asynchronous completions from the old generation.
2. Unregister app-message delegates for the old apps.
3. Unregister device-event delegates for the old devices.
4. Clear old in-memory app/device maps.
5. Install the new devices.
6. Register device events before performing app operations.
7. Create one new `IQApp` per device.
8. Register one app-message delegate per app.
9. Probe device/app status for diagnostics.
10. Wait for a new receipt before declaring the stream healthy.

Repeated calls with the same device set must be idempotent. They may perform a
deliberate repair generation, but must never layer registrations accidentally.

### 4.3 Stable restoration identifier

Keep the production Core Bluetooth restoration identifier stable. Apple
restoration uses that identifier to associate preserved central-manager state
with the app.

Do not rotate the identifier on every repair. If normal registration
replacement cannot escape the wedged state, a one-off diagnostic build with a
new identifier may determine whether restored SDK state is involved. That is
an experiment and possible migration, not the first-line recovery mechanism.

### 4.4 Receipt is the health signal

The selected watch's most recent valid `receivedMessage` callback is the
authoritative transport-health signal.

These are supporting diagnostics only:

- Garmin device status;
- characteristics-discovered callback;
- `getAppStatus`;
- watch `onComplete`;
- watch timeout/failure counters;
- Garmin Connect's connected label.

### 4.5 Recovery is serialized and bounded

There may be only one repair task. Automatic triggers coalesce into it. Manual
recovery may bypass the current cooldown once, but cannot start a second
concurrent repair.

### 4.6 Do not depend on unsupported watch error APIs

The Forerunner 965 is not listed for the newer
`registerForPhoneAppMessageErrors` API. The core design must work without it.
The older phone-message callback may be evaluated for acknowledgements, but
that is an enhancement after iOS recovery works.

## 5. Target Architecture

### 5.1 `GarminSDKClient`

Add an injectable protocol around the SDK surface RunSync uses:

```text
initialize
showDeviceSelection
parseDeviceSelectionResponse
registerDeviceEvents
unregisterDeviceEvents
registerAppMessages
unregisterAppMessages
deviceStatus
getAppStatus
sendMessage
```

The production adapter delegates to the `ConnectIQ` singleton. Tests use a
deterministic fake that records call order and can emit device, status, and
message callbacks.

The protocol is not an attempt to replace Garmin's SDK. It creates a testable
boundary around a binary singleton whose internal BLE state cannot otherwise be
controlled in unit tests.

### 5.2 `GarminTransportCoordinator`

Create a main-actor coordinator responsible only for:

- SDK initialization;
- authorized device installation;
- registration ownership;
- current registration generation;
- device and app status;
- last valid receipt metadata;
- stale detection;
- repair state and backoff;
- forwarding accepted messages to `GarminReceiptPipeline`.

Move archive, activity reconciliation, and HTTP recovery out of this component.
`GarminConnectionService` may remain as the UI-facing facade while delegating
transport work to the coordinator.

### 5.3 Transport snapshot

Expose a value snapshot rather than several unrelated labels:

```text
registrationGeneration
selectedDeviceID
deviceState
appInstallState
streamState
lastReceiptAt
lastReceiptSequence
repairTier
repairAttempt
repairReason
lastRepairAt
lastRepairOutcome
```

Suggested stream states:

```text
unconfigured
initializing
waitingForDevice
waitingForFirstReceipt
healthy
stale
repairing
authorizationRequired
unavailable
```

## 6. Repair State Machine

### 6.1 Stale threshold

While capture is enabled and an activity is producing roughly one sample per
second:

- `0...10s`: current;
- `>10...30s`: delayed;
- `>30s`: stale and eligible for automatic repair.

The initial automatic threshold is 30 seconds to avoid cycling the SDK for a
short iOS scheduling delay. Keep it as one named policy value and tune only
from physical evidence.

The timer can run only while iOS allows the process to execute. On every launch
and foreground transition, calculate age from the persisted last-receipt time
and trigger repair immediately if it is stale.

Do not infer staleness before the first activity receipt merely because the app
is open. The user may not have started an activity or placed the field on the
active data screen.

### 6.2 Repair triggers

Trigger repair for the selected device when:

- the stream crosses the stale threshold while RunSync is runnable;
- RunSync becomes active with capture enabled and the last receipt is stale;
- the SDK reports `.notConnected`, followed later by `.connected` or
  characteristics discovery, but receipts do not resume;
- the user presses `Recover & Retry`;
- authorization returns a new device set.

Authorization replacement always uses the teardown-before-register sequence.
It must not be treated as an additional registration layered onto the old one.

### 6.3 Repair ladder

#### Tier 0: Observe

- Record the trigger and current snapshot.
- Read current device status.
- Request app status with a bounded wait.
- If a receipt arrives during the observation window, stop and report success.

This tier does not claim that a successful app-status response repaired
anything.

#### Tier 1: Replace app-message registration

- Fence the old generation.
- Unregister old app-message registrations.
- Recreate `IQApp` values from the current authorized devices.
- Register app-message delegates once.
- Wait up to 20 seconds for a new valid selected-device receipt.

If a receipt arrives, reset repair backoff and mark healthy.

#### Tier 2: Replace the complete registration set

- Fence the old generation.
- Unregister app-message registrations.
- Unregister device-event registrations.
- Rebuild the device map from the stored authorized devices.
- Register device events first.
- Recreate apps and register app-message delegates.
- Wait for device readiness and then up to 20 seconds for a receipt.

If a receipt arrives, mark healthy.

#### Tier 3: Require fresh authorization

If Tier 2 fails, display a precise action:

```text
Garmin is connected, but RunSync is not receiving app messages.
Open Garmin authorization to refresh the device binding.
```

After Garmin returns devices, perform a complete teardown and replacement. Wait
for a receipt before reporting success. Do not report success merely because
the authorization callback parsed.

#### Tier 4: Escalate the SDK fault

If fresh authorization plus clean registration still fails:

- preserve and export the diagnostic timeline;
- stop automatic registration churn;
- keep the existing activity and local archive intact;
- offer a later manual attempt;
- run the minimal-SDK reproduction described in Phase 6;
- prepare a Garmin issue with privacy-safe evidence.

Do not repeatedly call undocumented initialization sequences or continuously
rotate restoration identifiers in production.

### 6.4 Backoff

After failed automatic repairs, use:

| Consecutive failed repair | Delay |
| --- | ---: |
| 1 | 15 seconds |
| 2 | 30 seconds |
| 3 | 60 seconds |
| 4 or more | 2 minutes |

Reset after a valid receipt. A manual tap may bypass the current delay once.
The app must not open Garmin authorization automatically.

### 6.5 Late callbacks and generation fences

All asynchronous app-status and device-status work captures the generation that
started it. A completion from an older generation may be logged but must not
overwrite current UI state or advance repair.

An app message is accepted only for an authorized device and is still processed
idempotently by the existing receipt pipeline. Any valid selected-device
receipt after a repair began is sufficient evidence that delivery resumed,
regardless of which internal Garmin operation ultimately caused it.

## 7. Make `Recover & Retry` Match Its Name

The button becomes a composed recovery operation with separate results:

1. Start or join the serialized Connect IQ transport repair.
2. Reconcile the local activity session.
3. Resume capture if local durability is healthy.
4. Clear recoverable upload blocking/backoff.
5. Retry archived uploads.
6. Report transport, archive, and upload outcomes independently.

Example:

```text
Watch transport: waiting for a new message
Capture: resumed
Archive: 2,418 samples protected
Upload: blocked by incompatible server
```

Then, after a receipt and server recovery:

```text
Watch transport: recovered at q=8121
Capture: active
Archive: healthy
Upload: current
```

The UI must not collapse partial success into a single green state.

## 8. Diagnostics

Build on the observability implementation with privacy-safe events:

```text
transport_started
registration_replace_started
app_messages_unregistered
device_events_unregistered
device_events_registered
app_messages_registered
device_status_changed
app_status_completed
receipt_stale
repair_started
repair_tier_completed
repair_waiting_for_receipt
repair_succeeded
repair_failed
authorization_refresh_requested
foreground_stale_check
```

Each event may include:

- process session ID;
- registration generation;
- abbreviated device ID;
- repair reason/tier/attempt;
- safe SDK status enum;
- receipt age;
- last watch sequence;
- watch build ID;
- watch timeout/error/exception counters.

Never include:

- coordinates;
- heart rate or other physiology;
- server tokens;
- full device UUIDs;
- raw message payloads;
- Garmin authorization URLs.

Add an `Export diagnostics` action that shares the bounded local diagnostic
file. Preserve it before reinstalling the app because uninstalling may delete
both evidence and archived telemetry.

## 9. Server Compatibility Phase

This phase is operationally first even though it does not repair Connect IQ.

1. Deploy the API code from
   `telemetry-transport-observability-implementation`.
2. Run migration `002_watch_transport_diagnostics.sql` before replacing the API
   container.
3. Confirm the six diagnostic columns exist.
4. Confirm readiness passes on the new API image.
5. Send one authenticated diagnostic telemetry envelope and require HTTP 2xx.
6. Press `Recover & Retry` once to clear the client's `request_malformed`
   upload block and release protected pending envelopes.
7. Verify stored rows contain the watch build and transport counters.
8. Run the incident correlation query in `docs/server-operations.md`.

For future additive telemetry fields, deploy and verify server acceptance
before distributing the client. Keep a compatibility test proving that the new
server accepts both old and new payloads. The old strict server cannot accept
fields it does not know.

## 10. Implementation Phases

### Phase 0: Preserve evidence and correct deployment

- End and preserve the current Garmin activity normally.
- Export iOS diagnostics before any uninstall.
- Record iOS version, Garmin Connect version, watch firmware, watch build,
  activity time, and repair attempts.
- Deploy the compatible server and migration.
- Verify the archived HTTP backlog can drain independently of watch delivery.

Exit condition: new diagnostic envelopes receive HTTP 2xx and the server fault
can no longer obscure Connect IQ results.

### Phase 1: Make the SDK boundary testable

- Add `GarminSDKClient` and the production adapter.
- Inject it into the transport owner.
- Add a fake SDK with ordered call recording and controllable callbacks.
- Preserve current behavior before adding automatic repair.

Exit condition: unit tests can prove registration/unregistration order without
real Bluetooth.

### Phase 2: Fix registration ownership

- Implement teardown-before-replacement.
- Add registration generations and stale-completion fencing.
- Route launch restore and authorization callbacks through the same replacement
  method.
- Do not unregister during ordinary backgrounding; the subscription must remain
  eligible for Bluetooth delivery.

Exit condition: repeated launch/authorization/replace scenarios leave exactly
one logical registration per device/app in the fake SDK.

### Phase 3: Add explicit repair

- Implement the repair ladder, timeouts, serialization, and backoff.
- Wire manual recovery to transport plus existing local/upload recovery.
- Require a receipt for success.
- Persist the repair timeline.

Exit condition: deterministic tests cover every tier, timeout, late completion,
  coalesced trigger, and manual cooldown bypass.

### Phase 4: Add automatic stale recovery

- Add receipt-age state.
- Run a lightweight watchdog only while the app is active.
- Check staleness on launch and foreground.
- Schedule post-reconnect verification after device readiness.
- Update UI copy to distinguish device connectivity from app-message health.

Exit condition: a simulated stale stream repairs once, backs off when it cannot
recover, and returns to healthy only on a receipt.

### Phase 5: Evaluate end-to-end phone acknowledgement

After Phases 1-4 work physically, run a small feasibility spike:

- iOS sends a compact acknowledgement with the latest received sequence.
- Send at most on state change or every 10 seconds, not once per sample.
- The data field registers for phone-app messages and displays acknowledgement
  age separately from watch transport completion.
- Keep payloads small and tolerate lost acknowledgements.

If reliable on the target watch, this makes the watch UI truthful:

```text
Q 8121  T 0  F 0  A 3s
```

`A` would mean the phone actually reported receipt through sequence 8121.
Without it, `T 0 F 0` means only that Garmin accepted watch transmit requests.

Do not block the core iOS repair on this enhancement.

### Phase 6: Minimal reproduction and Garmin escalation

If clean re-registration still wedges:

- Create the smallest iOS companion using Garmin SDK 1.8.0.
- Create a minimal watch app/data field with a separate test app UUID.
- Send only a counter once per second.
- Implement explicit register/unregister and a visible received counter.
- Reproduce the same Bluetooth-off/on, suspension, foreground, and endurance
  cases.

Capture:

- UTC timestamps;
- iPhone model and iOS version;
- Garmin Connect version;
- watch model and firmware;
- Connect IQ API level;
- SDK version;
- device-status and app-status callbacks;
- transmit completion/error counts;
- received counter and cutoff time;
- whether registration replacement recovered.

If the minimal app fails too, file a Garmin SDK issue with that project and
timeline. If it does not fail, diff lifecycle and registration behavior against
RunSync before adding more recovery complexity.

## 11. Unit and Integration Tests

### Registration ownership

- Initial start registers device events before app operations.
- Replacing the same device unregisters old app and device registrations first.
- Replacing device A with B leaves no A registration.
- Multiple authorized watches each have exactly one app registration.
- Empty authorization tears down old registrations.
- A stale app-status completion cannot mutate the new generation.

### Repair behavior

- A fresh receipt prevents repair.
- A 30-second stale receipt starts one repair.
- Concurrent automatic triggers join the same task.
- Repeated button taps join the same task.
- Tier 1 success stops escalation.
- Tier 1 timeout advances to Tier 2.
- Tier 2 timeout requests user authorization instead of looping.
- A receipt during any wait marks success and resets backoff.
- Status success without a receipt does not mark success.
- Manual recovery bypasses cooldown once.
- Foregrounding with a stale receipt repairs immediately.
- Foregrounding with a current receipt does nothing.
- `.connected` without a later receipt remains stale.

### Receipt safety

- A message from an unauthorized device is rejected safely.
- Duplicate sequence data remains harmless.
- Message decoding and archive ordering are unchanged.
- Repair never deletes or rotates an activity ID.
- Repair never disables uploading of already archived data.

### Server rollout

- The new API accepts legacy payloads without diagnostic fields.
- The new API accepts payloads with all diagnostic fields.
- Migration 002 is idempotently tracked by the migration system.
- A retry after the deployment clears the backlog without duplicate samples.

## 12. Physical Acceptance Matrix

Use a clearly different route or controlled stationary test to separate elapsed
time from location.

| Scenario | Procedure | Required result |
| --- | --- | --- |
| Baseline endurance | Run at least 30 minutes past the prior cutoff window with phone locked | Receipts continue; no repair churn |
| Same route | Repeat the course that previously failed | No cutoff at the old point/time |
| Different location | Remain stationary or use a different route past 10 minutes | Establish whether location was incidental |
| Settings Bluetooth outage | Turn Bluetooth off for 60 seconds, then on | Watch failures rise during outage; receipts resume within 60 seconds after RunSync is runnable |
| Garmin reconnect | Disconnect/reconnect through normal Garmin flow | One registration generation repairs; no activity restart |
| RunSync suspension | Lock phone and background normally | Delivery continues or repairs on foreground |
| RunSync force-quit | Force-quit, continue activity, reopen RunSync | No promise while force-quit; foreground repair resumes receipts without restarting activity |
| Phone reboot | Reboot, unlock once, reopen RunSync | Foreground repair resumes receipts |
| Reauthorization | Authorize the same watch repeatedly | No layered registrations; receipt stream remains singular |
| Server outage | Stop API while watch delivery continues | iOS archive grows and later drains |
| Combined outage | Bluetooth and API unavailable, then restore both | New receipts and old uploads recover independently |
| Long soak | Two-hour activity with phone locked/pocketed | No permanent receipt cutoff, unbounded diagnostics, or excessive repair churn |
| Repetition | Run the Bluetooth case 20 times | Every runnable-app recovery succeeds; no duplicate delegate behavior |

For each test, record:

- last watch sequence before outage;
- watch timeout/failure counters;
- iOS last receipt and received count;
- registration generation and repair tier;
- time from reconnect/foreground to next receipt;
- pending upload count and final acknowledgement.

## 13. Rollout Order

1. Deploy the observability-compatible server and migration.
2. Drain and verify the current protected upload backlog.
3. Rebase or layer the iOS transport work on
   `telemetry-transport-observability-implementation`.
4. Ship Phase 1 and Phase 2 internally and verify no registration regression.
5. Ship manual Tier 1/Tier 2 repair.
6. Run the physical outage matrix.
7. Enable automatic stale repair after manual repair is proven.
8. Run endurance and repetition tests.
9. Evaluate the phone acknowledgement.
10. Escalate to Garmin only if clean registration ownership cannot recover.

Automatic repair should be controlled by one configuration flag for the first
physical builds. Diagnostics remain enabled whether automatic repair is on or
off.

## 14. Risks and Mitigations

### Garmin SDK remains internally wedged

Mitigation: stop bounded repair after Tier 2/3, preserve evidence, and use the
minimal reproduction. Do not hide an SDK failure behind endless retries.

### Re-registration increases BLE or battery churn

Mitigation: 30-second stale threshold, one repair task, bounded waits, capped
backoff, and physical battery/soak testing.

### Old callbacks corrupt current status

Mitigation: registration generation fences and idempotent receipt handling.

### Foreground timers create a false background guarantee

Mitigation: UI and documentation say “recovery when RunSync is runnable.”
Perform a stale check on every foreground event.

### A server rollout masks transport results

Mitigation: deploy migration/API first and show transport, archive, and upload
as separate states.

### Reauthorization still layers registrations

Mitigation: route every device-set change through the same teardown-first
coordinator. Never call the current `replaceDevices` behavior directly.

### Acknowledgements cost battery or create another queue

Mitigation: acknowledgements are optional, compact, rate-limited, and
latest-value-only.

## 15. Non-Goals

- Guaranteeing delivery while iOS refuses to run a force-quit app.
- Buffering an entire activity on the watch.
- Replacing Garmin Connect or bypassing the Garmin Mobile SDK.
- Treating a watch transmit callback as phone or server delivery.
- Automatically presenting Garmin authorization UI.
- Deleting local telemetry to make recovery appear successful.
- Rewriting the entire iOS app, server, or watch data field.

## 16. Source Constraints

- [Garmin Mobile SDK for iOS](https://developer.garmin.com/connect-iq/core-topics/mobile-sdk-for-ios/)
  documents direct BLE communication, device-before-app registration,
  unregister methods, asynchronous app status, sending/receiving messages, and
  undefined behavior for ambiguous companion-app registration.
- [Garmin Toybox Communications](https://developer.garmin.com/connect-iq/api-docs/Toybox/Communications.html)
  documents watch transmit errors and phone-app message callbacks. The newer
  phone-message error callback is limited to its published supported-device
  list.
- [Apple TN3115](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules)
  defines when Bluetooth restoration can relaunch an app, including force-quit
  and iOS 26 restrictions.
- [Garmin's official iOS SDK repository](https://github.com/garmin/connectiq-companion-app-sdk-ios)
  lists 1.8.0 as the current release. RunSync already pins 1.8.0, so an SDK
  upgrade is not currently available as the fix.
