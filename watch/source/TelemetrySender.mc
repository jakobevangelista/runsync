import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;

(:ble) class TelemetrySender {
    private var _inFlight as Lang.Boolean = false;
    private var _pending as Lang.Dictionary?;
    private var _listener as TelemetryTransmitListener;

    var completedCount as Lang.Number = 0;
    var errorCount as Lang.Number = 0;
    var droppedPendingCount as Lang.Number = 0;
    var lastAttemptTimer as Lang.Number?;
    var lastCompleteTimer as Lang.Number?;

    function initialize() {
        _pending = null;
        lastAttemptTimer = null;
        lastCompleteTimer = null;
        _listener = new TelemetryTransmitListener(self);
    }

    function enqueue(payload as Lang.Dictionary) as Void {
        if (_inFlight) {
            if (_pending != null) {
                droppedPendingCount += 1;
            }
            _pending = payload;
            return;
        }

        transmit(payload);
    }

    function transmissionCompleted() as Void {
        completedCount += 1;
        lastCompleteTimer = System.getTimer();
        finishTransmission();
    }

    function transmissionFailed() as Void {
        errorCount += 1;
        finishTransmission();
    }

    function isInFlight() as Lang.Boolean {
        return _inFlight;
    }

    private function transmit(payload as Lang.Dictionary) as Void {
        _inFlight = true;
        lastAttemptTimer = System.getTimer();

        try {
            Communications.transmit(payload, {}, _listener);
        } catch (error) {
            transmissionFailed();
        }
    }

    private function finishTransmission() as Void {
        _inFlight = false;
        if (_pending == null) {
            return;
        }

        var newest = _pending;
        _pending = null;
        transmit(newest as Lang.Dictionary);
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
