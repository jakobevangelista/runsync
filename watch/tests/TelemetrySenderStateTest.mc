import Toybox.Lang;
import Toybox.Test;

function testPayload(sequence as Lang.Number) as Lang.Dictionary {
    return { "q" => sequence };
}

(:test)
function telemetryHealthyAndLatestValueTest(logger as Test.Logger) as Lang.Boolean {
    var state = new TelemetrySenderState();
    var first = state.enqueueNormal(testPayload(1), 0) as TelemetrySendAction;
    Test.assertEqual(1l, first.attemptId);

    state.enqueueNormal(testPayload(2), 100);
    state.enqueueNormal(testPayload(3), 200);
    Test.assertEqual(1, state.droppedPendingCount);

    var next = state.complete(first.attemptId, 300) as TelemetrySendAction;
    Test.assertEqual(3, next.payload["q"]);
    Test.assertEqual(2l, next.attemptId);
    Test.assertEqual(0, state.consecutiveFailureCount);
    return true;
}

(:test)
function telemetryWatchdogAndStaleCallbackTest(logger as Test.Logger) as Lang.Boolean {
    var state = new TelemetrySenderState();
    var first = state.enqueueNormal(testPayload(1), 0) as TelemetrySendAction;
    state.enqueueNormal(testPayload(2), 1000);

    Test.assert(state.tick(14999) == null);
    Test.assert(state.tick(15000) == null);
    Test.assertEqual(1, state.timeoutCount);
    Test.assertEqual(1000, state.retryDelayMilliseconds());

    var second = state.tick(16000) as TelemetrySendAction;
    Test.assertEqual(2l, second.attemptId);
    Test.assertEqual(2, second.payload["q"]);

    Test.assert(state.complete(first.attemptId, 16001) == null);
    Test.assert(state.fail(first.attemptId, 16001) == null);
    Test.assertEqual(second.attemptId, state.activeAttemptId());
    Test.assertEqual(1, state.staleCompletionCount);
    Test.assertEqual(1, state.staleErrorCount);
    return true;
}

(:test)
function telemetryBackoffAndSuccessResetTest(logger as Test.Logger) as Lang.Boolean {
    var state = new TelemetrySenderState();
    var now = 0;
    var expectedDelays = [1000, 2000, 4000, 8000, 15000, 15000];

    for (var index = 0; index < expectedDelays.size(); index += 1) {
        var action = state.enqueueNormal(testPayload(index), now) as TelemetrySendAction;
        state.fail(action.attemptId, now);
        Test.assertEqual(expectedDelays[index], state.retryDelayMilliseconds());
        now += expectedDelays[index] as Lang.Number;
    }

    var recovered = state.enqueueNormal(testPayload(99), now) as TelemetrySendAction;
    state.complete(recovered.attemptId, now + 1);
    Test.assertEqual(0, state.consecutiveFailureCount);
    Test.assertEqual(0, state.retryDelayMilliseconds());
    Test.assertEqual(TELEMETRY_OUTCOME_SUCCESS, state.lastOutcome);
    return true;
}

(:test)
function telemetrySynchronousExceptionTest(logger as Test.Logger) as Lang.Boolean {
    var state = new TelemetrySenderState();
    var first = state.enqueueNormal(testPayload(1), 10) as TelemetrySendAction;
    Test.assert(state.failSynchronously(first.attemptId, 10) == null);
    Test.assertEqual(1, state.synchronousExceptionCount);
    Test.assertEqual(false, state.isInFlight());
    Test.assertEqual(1000, state.retryDelayMilliseconds());
    return true;
}

(:test)
function telemetryTerminalTimeoutAndExceptionRetryTest(logger as Test.Logger) as Lang.Boolean {
    var state = new TelemetrySenderState();
    var first = state.enqueueTerminal(testPayload(1), 0) as TelemetrySendAction;
    state.tick(15000);
    Test.assertEqual(1, state.timeoutCount);
    Test.assertEqual(true, state.hasPendingTerminal());

    var second = state.tick(16000) as TelemetrySendAction;
    state.failSynchronously(second.attemptId, 16000);
    Test.assertEqual(1, state.synchronousExceptionCount);
    Test.assertEqual(true, state.hasPendingTerminal());
    Test.assertEqual(2, state.terminalAttemptCount());

    var third = state.tick(18000) as TelemetrySendAction;
    Test.assertNotEqual(first.attemptId, third.attemptId);
    state.complete(third.attemptId, 18001);
    Test.assertEqual(false, state.hasPendingTerminal());
    return true;
}

(:test)
function telemetryTerminalPreemptionAndExhaustionTest(logger as Test.Logger) as Lang.Boolean {
    var state = new TelemetrySenderState();
    var normal = state.enqueueNormal(testPayload(1), 0) as TelemetrySendAction;
    var terminal = state.enqueueTerminal(testPayload(10), 1) as TelemetrySendAction;
    Test.assertEqual(1, state.preemptedCount);
    Test.assertNotEqual(normal.attemptId, terminal.attemptId);
    Test.assertEqual(1, state.terminalAttemptCount());

    var now = 1;
    for (var attempt = 1; attempt <= 4; attempt += 1) {
        state.fail(terminal.attemptId, now);
        if (attempt < 4) {
            now += state.retryDelayMilliseconds();
            terminal = state.tick(now) as TelemetrySendAction;
        }
    }

    Test.assertEqual(false, state.hasPendingTerminal());
    Test.assertEqual(1, state.terminalExhaustedCount);
    Test.assertEqual(3, state.terminalRetryCount);
    return true;
}

(:test)
function telemetryNewTerminalSupersedesOldGenerationTest(logger as Test.Logger) as Lang.Boolean {
    var state = new TelemetrySenderState();
    var oldTerminal = state.enqueueTerminal(testPayload(1), 0) as TelemetrySendAction;
    var newTerminal = state.enqueueTerminal(testPayload(2), 1) as TelemetrySendAction;

    Test.assertEqual(1, state.terminalCollisionCount);
    Test.assertEqual(1, state.terminalSupersededCount);
    Test.assertEqual(0, state.terminalExhaustedCount);
    Test.assert(state.complete(oldTerminal.attemptId, 2) == null);
    Test.assertEqual(newTerminal.attemptId, state.activeAttemptId());
    state.complete(newTerminal.attemptId, 3);
    Test.assertEqual(1, state.terminalCompletedCount);
    return true;
}

(:test)
function telemetryTimerWrapTest(logger as Test.Logger) as Lang.Boolean {
    Test.assertEqual(96l, telemetryElapsedMilliseconds(-2147483600, 2147483600));

    var state = new TelemetrySenderState();
    var action = state.enqueueNormal(testPayload(1), 2147470000) as TelemetrySendAction;
    Test.assert(state.tick(-2147483296) == null);
    Test.assertEqual(action.attemptId, state.activeAttemptId());
    state.tick(-2147482296);
    Test.assertEqual(1, state.timeoutCount);
    return true;
}

(:test)
function telemetryTransportStatusTextTest(logger as Test.Logger) as Lang.Boolean {
    var state = new TelemetrySenderState();
    Test.assertEqual(TELEMETRY_STATUS_CONNECT, state.transportStatusText(0));
    Test.assertEqual("NO TX", state.transportDetailText(0));

    var first = state.enqueueNormal(testPayload(1), 0) as TelemetrySendAction;
    Test.assertEqual(TELEMETRY_STATUS_CONNECT, state.transportStatusText(0));
    Test.assertEqual("TRY 0s", state.transportDetailText(0));

    state.complete(first.attemptId, 0);
    Test.assertEqual(TELEMETRY_STATUS_LIVE, state.transportStatusText(5000));
    Test.assertEqual("OK 5s", state.transportDetailText(5000));
    Test.assertEqual(TELEMETRY_STATUS_DELAYED, state.transportStatusText(11000));
    Test.assertEqual("OK 11s", state.transportDetailText(11000));
    return true;
}

(:test)
function telemetryFailureStatusAndDetailTextTest(logger as Test.Logger) as Lang.Boolean {
    var state = new TelemetrySenderState();
    var first = state.enqueueNormal(testPayload(1), 0) as TelemetrySendAction;
    state.fail(first.attemptId, 0);
    Test.assertEqual(TELEMETRY_STATUS_RETRY, state.transportStatusText(0));
    Test.assertEqual("WAIT 1s ERR F1", state.transportDetailText(0));

    var second = state.enqueueNormal(testPayload(2), 1000) as TelemetrySendAction;
    state.fail(second.attemptId, 1000);
    var third = state.enqueueNormal(testPayload(3), 3000) as TelemetrySendAction;
    state.fail(third.attemptId, 3000);
    Test.assertEqual(TELEMETRY_STATUS_NO_PHONE, state.transportStatusText(3000));
    Test.assertEqual("WAIT 4s ERR F3", state.transportDetailText(3000));
    return true;
}

(:test)
function telemetryTimeoutStatusAndDiagnosticsTest(logger as Test.Logger) as Lang.Boolean {
    var state = new TelemetrySenderState();
    state.enqueueNormal(testPayload(1), 0);
    state.enqueueNormal(testPayload(2), 1000);

    Test.assert(state.tick(15000) == null);
    Test.assertEqual(TELEMETRY_STATUS_RETRY, state.transportStatusText(15000));
    Test.assertEqual("WAIT 1s TO F1 T1", state.transportDetailText(15000));
    Test.assertEqual(1000, state.retryRemainingMilliseconds(15000));

    var diagnostics = state.diagnostics(15000);
    Test.assertEqual(TELEMETRY_STATUS_RETRY, diagnostics["transportStatus"]);
    Test.assertEqual("WAIT 1s TO F1 T1", diagnostics["transportDetail"]);
    Test.assertEqual(1000, diagnostics["retryRemainingMs"]);

    var second = state.tick(16000) as TelemetrySendAction;
    Test.assertEqual(2l, second.attemptId);
    Test.assertEqual("TRY 0s TO F1 T1", state.transportDetailText(16000));
    return true;
}

(:test)
function telemetryLongOutageRemainsBoundedTest(logger as Test.Logger) as Lang.Boolean {
    var state = new TelemetrySenderState();
    var now = 0;
    var submissions = 0;

    for (var second = 0; second < 7200; second += 1) {
        var action = state.enqueueNormal(testPayload(second), now);
        if (action != null) {
            submissions += 1;
        }
        now += 1000;
    }

    Test.assert(submissions < 300);
    Test.assertEqual(true, state.hasPendingNormal());
    Test.assertEqual(true, state.isInFlight());
    return true;
}
