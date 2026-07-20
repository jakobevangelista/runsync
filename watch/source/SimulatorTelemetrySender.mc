import Toybox.Lang;

const SIMULATOR_TRANSPORT_COMPLETE = 0;
const SIMULATOR_TRANSPORT_ERROR = 1;
const SIMULATOR_TRANSPORT_EXCEPTION = 2;
const SIMULATOR_TRANSPORT_NO_CALLBACK = 3;
const SIMULATOR_TRANSPORT_DELAYED = 4;

(:simulator) class TelemetrySender {
    private var _state as TelemetrySenderState;
    private var _outcome as Lang.Number = SIMULATOR_TRANSPORT_COMPLETE;
    private var _delayedAttemptId as Lang.Long?;

    var detachedListenerCount as Lang.Number = 0;

    function initialize() {
        _state = new TelemetrySenderState();
        _delayedAttemptId = null;
    }

    function enqueue(payload as Lang.Dictionary, now as Lang.Number) as Void {
        handleAction(_state.enqueueNormal(payload, now), now);
    }

    function enqueueTerminal(payload as Lang.Dictionary, now as Lang.Number) as Void {
        handleAction(_state.enqueueTerminal(payload, now), now);
    }

    function tick(now as Lang.Number) as Void {
        handleAction(_state.tick(now), now);
    }

    function recordTerminalDuplicate() as Void {
        _state.recordTerminalDuplicate();
    }

    function setOutcome(outcome as Lang.Number) as Void {
        _outcome = outcome;
    }

    function completeDelayed(now as Lang.Number) as Void {
        if (_delayedAttemptId == null) {
            return;
        }
        var attemptId = _delayedAttemptId as Lang.Long;
        _delayedAttemptId = null;
        handleAction(_state.complete(attemptId, now), now);
    }

    function failDelayed(now as Lang.Number) as Void {
        if (_delayedAttemptId == null) {
            return;
        }
        var attemptId = _delayedAttemptId as Lang.Long;
        _delayedAttemptId = null;
        handleAction(_state.fail(attemptId, now), now);
    }

    function completeAttempt(attemptId as Lang.Long, now as Lang.Number) as Void {
        handleAction(_state.complete(attemptId, now), now);
    }

    function failAttempt(attemptId as Lang.Long, now as Lang.Number) as Void {
        handleAction(_state.fail(attemptId, now), now);
    }

    function isInFlight() as Lang.Boolean {
        return _state.isInFlight();
    }

    function hasCompleted() as Lang.Boolean {
        return _state.lastCompleteTimer != null;
    }

    function completionAgeSeconds(now as Lang.Number) as Lang.Number {
        return _state.completionAgeSeconds(now);
    }

    function consecutiveFailureCount() as Lang.Number {
        return _state.consecutiveFailureCount;
    }

    function timeoutCount() as Lang.Number {
        return _state.timeoutCount;
    }

    function activeAttemptId() as Lang.Long? {
        return _state.activeAttemptId();
    }

    function activeAttemptAgeMilliseconds(now as Lang.Number) as Lang.Long? {
        return _state.activeAttemptAgeMilliseconds(now);
    }

    function diagnostics(now as Lang.Number) as Lang.Dictionary {
        var values = _state.diagnostics(now);
        values["detachedListeners"] = detachedListenerCount;
        return values;
    }

    private function handleAction(action as TelemetrySendAction?, now as Lang.Number) as Void {
        if (action == null) {
            return;
        }

        var sendAction = action as TelemetrySendAction;
        if (_outcome == SIMULATOR_TRANSPORT_NO_CALLBACK) {
            return;
        }
        if (_outcome == SIMULATOR_TRANSPORT_DELAYED) {
            _delayedAttemptId = sendAction.attemptId;
            return;
        }
        if (_outcome == SIMULATOR_TRANSPORT_ERROR) {
            handleAction(_state.fail(sendAction.attemptId, now), now);
            return;
        }
        if (_outcome == SIMULATOR_TRANSPORT_EXCEPTION) {
            handleAction(_state.failSynchronously(sendAction.attemptId, now), now);
            return;
        }

        handleAction(_state.complete(sendAction.attemptId, now), now);
    }
}
