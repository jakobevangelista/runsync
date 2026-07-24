import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;

(:ble) class TelemetrySender {
    private var _state as TelemetrySenderState;
    private var _listener as TelemetryTransmitListener?;

    var detachedListenerCount as Lang.Number = 0;

    function initialize() {
        _state = new TelemetrySenderState();
        _listener = null;
    }

    function enqueue(payload as Lang.Dictionary, now as Lang.Number) as Void {
        var priorAttempt = _state.activeAttemptId();
        finishTransition(priorAttempt, _state.enqueueNormal(payload, now), now);
    }

    function enqueueTerminal(payload as Lang.Dictionary, now as Lang.Number) as Void {
        var priorAttempt = _state.activeAttemptId();
        finishTransition(priorAttempt, _state.enqueueTerminal(payload, now), now);
    }

    function tick(now as Lang.Number) as Void {
        var priorAttempt = _state.activeAttemptId();
        finishTransition(priorAttempt, _state.tick(now), now);
    }

    function recordTerminalDuplicate() as Void {
        _state.recordTerminalDuplicate();
    }

    function transmissionCompleted(attemptId as Lang.Long) as Void {
        var now = System.getTimer();
        finishTransition(attemptId, _state.complete(attemptId, now), now);
    }

    function transmissionFailed(attemptId as Lang.Long) as Void {
        var now = System.getTimer();
        finishTransition(attemptId, _state.fail(attemptId, now), now);
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

    function transportStatusText(now as Lang.Number) as Lang.String {
        return _state.transportStatusText(now);
    }

    function transportDetailText(now as Lang.Number) as Lang.String {
        return _state.transportDetailText(now);
    }

    function diagnostics(now as Lang.Number) as Lang.Dictionary {
        var values = _state.diagnostics(now);
        values["detachedListeners"] = detachedListenerCount;
        return values;
    }

    private function finishTransition(
        priorAttempt as Lang.Long?,
        action as TelemetrySendAction?,
        now as Lang.Number
    ) as Void {
        if (priorAttempt != null && priorAttempt != _state.activeAttemptId()) {
            detachListener(priorAttempt as Lang.Long);
        }
        if (action != null) {
            submit(action as TelemetrySendAction, now);
        }
    }

    private function submit(action as TelemetrySendAction, now as Lang.Number) as Void {
        var listener = new TelemetryTransmitListener(self, action.attemptId);
        _listener = listener;

        try {
            Communications.transmit(action.payload, {}, listener);
        } catch (error) {
            finishTransition(
                action.attemptId,
                _state.failSynchronously(action.attemptId, System.getTimer()),
                now
            );
        }
    }

    private function detachListener(attemptId as Lang.Long) as Void {
        if (_listener == null || (_listener as TelemetryTransmitListener).attemptId() != attemptId) {
            return;
        }

        (_listener as TelemetryTransmitListener).detach();
        _listener = null;
        detachedListenerCount += 1;
    }
}

(:ble) class TelemetryTransmitListener extends Communications.ConnectionListener {
    private var _sender as TelemetrySender?;
    private var _attemptId as Lang.Long;

    function initialize(sender as TelemetrySender, attemptId as Lang.Long) {
        ConnectionListener.initialize();
        _sender = sender;
        _attemptId = attemptId;
    }

    function onComplete() as Void {
        var sender = _sender;
        if (sender != null) {
            (sender as TelemetrySender).transmissionCompleted(_attemptId);
        }
    }

    function onError() as Void {
        var sender = _sender;
        if (sender != null) {
            (sender as TelemetrySender).transmissionFailed(_attemptId);
        }
    }

    function attemptId() as Lang.Long {
        return _attemptId;
    }

    function detach() as Void {
        _sender = null;
    }
}
