import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;

(:ble) class TelemetrySender {
    private var _inFlight as Lang.Boolean = false;
    private var _inFlightTerminalGeneration as Lang.Number?;
    private var _pendingNormal as Lang.Dictionary?;
    private var _terminal as Lang.Dictionary?;
    private var _terminalGeneration as Lang.Number = 0;
    private var _terminalAttempts as Lang.Number = 0;
    private var _listener as TelemetryTransmitListener;

    var completedCount as Lang.Number = 0;
    var errorCount as Lang.Number = 0;
    var droppedPendingCount as Lang.Number = 0;
    var terminalCompletedCount as Lang.Number = 0;
    var terminalRetryCount as Lang.Number = 0;
    var terminalExhaustedCount as Lang.Number = 0;
    var terminalDuplicateCount as Lang.Number = 0;
    var terminalCollisionCount as Lang.Number = 0;
    var lastAttemptTimer as Lang.Number?;
    var lastCompleteTimer as Lang.Number?;

    function initialize() {
        _inFlightTerminalGeneration = null;
        _pendingNormal = null;
        _terminal = null;
        lastAttemptTimer = null;
        lastCompleteTimer = null;
        _listener = new TelemetryTransmitListener(self);
    }

    function enqueue(payload as Lang.Dictionary) as Void {
        if (_pendingNormal != null) {
            droppedPendingCount += 1;
        }
        _pendingNormal = payload;
        drain();
    }

    function enqueueTerminal(payload as Lang.Dictionary) as Void {
        if (_terminal != null) {
            terminalCollisionCount += 1;
            terminalExhaustedCount += 1;
        }

        _terminalGeneration += 1;
        _terminal = payload;
        _terminalAttempts = 0;
        drain();
    }

    function recordTerminalDuplicate() as Void {
        terminalDuplicateCount += 1;
    }

    function transmissionCompleted() as Void {
        if (!_inFlight) {
            return;
        }

        var completedTerminalGeneration = _inFlightTerminalGeneration;
        _inFlight = false;
        _inFlightTerminalGeneration = null;
        completedCount += 1;
        lastCompleteTimer = System.getTimer();

        if (completedTerminalGeneration != null &&
            _terminal != null &&
            completedTerminalGeneration == _terminalGeneration) {
            terminalCompletedCount += 1;
            _terminal = null;
            _terminalAttempts = 0;
        }

        drain();
    }

    function transmissionFailed() as Void {
        if (!_inFlight) {
            return;
        }

        var failedTerminalGeneration = _inFlightTerminalGeneration;
        _inFlight = false;
        _inFlightTerminalGeneration = null;
        errorCount += 1;

        if (failedTerminalGeneration != null) {
            if (_terminal == null || failedTerminalGeneration != _terminalGeneration) {
                drain();
                return;
            }

            if (_terminalAttempts < 4) {
                // A later enqueue is the next retry opportunity; never retry on this stack.
                return;
            }

            terminalExhaustedCount += 1;
            _terminal = null;
            _terminalAttempts = 0;
        }

        drain();
    }

    function isInFlight() as Lang.Boolean {
        return _inFlight;
    }

    private function drain() as Void {
        if (_inFlight) {
            return;
        }

        if (_terminal != null) {
            transmitTerminal();
            return;
        }

        if (_pendingNormal == null) {
            return;
        }

        var newest = _pendingNormal;
        _pendingNormal = null;
        transmit(newest as Lang.Dictionary, null);
    }

    private function transmitTerminal() as Void {
        if (_terminalAttempts > 0) {
            terminalRetryCount += 1;
        }
        _terminalAttempts += 1;
        transmit(_terminal as Lang.Dictionary, _terminalGeneration);
    }

    private function transmit(payload as Lang.Dictionary, terminalGeneration as Lang.Number?) as Void {
        _inFlight = true;
        _inFlightTerminalGeneration = terminalGeneration;
        lastAttemptTimer = System.getTimer();

        try {
            Communications.transmit(payload, {}, _listener);
        } catch (error) {
            transmissionFailed();
        }
    }
}

(:ble) class TelemetryTransmitListener extends Communications.ConnectionListener {
    private var _sender as TelemetrySender;

    function initialize(sender as TelemetrySender) {
        ConnectionListener.initialize();
        _sender = sender;
    }

    function onComplete() as Void {
        _sender.transmissionCompleted();
    }

    function onError() as Void {
        _sender.transmissionFailed();
    }
}
