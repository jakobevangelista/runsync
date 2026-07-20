import Toybox.Activity;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

class RunSyncField extends WatchUi.DataField {
    private var _encoder as TelemetryEncoder;
    private var _sender as TelemetrySender;
    private var _sequence as Lang.Number = 0;
    private var _state as Lang.Number = 0;
    private var _hasGPS as Lang.Boolean = false;
    private var _cachedRunStart as Lang.Number?;
    private var _terminalEnqueued as Lang.Boolean = false;

    function initialize() {
        DataField.initialize();
        _encoder = new TelemetryEncoder();
        _sender = new TelemetrySender();
        _cachedRunStart = null;
    }

    function compute(info as Activity.Info) as Void {
        var now = System.getTimer();
        _hasGPS = info has :currentLocation && info.currentLocation != null;
        var payload = _encoder.encode(info, _sequence, _state);
        _state = payload["st"] as Lang.Number;
        if (info has :startTime && info.startTime != null) {
            _cachedRunStart = info.startTime.value();
        }
        _sequence += 1;
        _sender.enqueue(payload, now);
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        View.onUpdate(dc);

        var background = getBackgroundColor();
        var foreground = background == Graphics.COLOR_BLACK
            ? Graphics.COLOR_WHITE
            : Graphics.COLOR_BLACK;

        dc.setColor(background, background);
        dc.clear();
        dc.setColor(foreground, Graphics.COLOR_TRANSPARENT);

        var titleFont = Graphics.FONT_MEDIUM;
        var detailFont = Graphics.FONT_SMALL;
        dc.drawText(dc.getWidth() / 2, dc.getHeight() * 0.28,
            titleFont, statusText(), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(dc.getWidth() / 2, dc.getHeight() * 0.62,
            detailFont, detailText(), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    function onTimerStart() as Void {
        _state = 1;
        _terminalEnqueued = false;
    }

    function onTimerPause() as Void {
        _state = 2;
    }

    function onTimerResume() as Void {
        _state = 1;
    }

    function onTimerStop() as Void {
        _state = 3;
    }

    function onTimerReset() as Void {
        _state = 4;
        if (_terminalEnqueued) {
            _sender.recordTerminalDuplicate();
            return;
        }

        var payload = {
            "v" => 1,
            "q" => _sequence,
            "st" => 4
        };
        if (_cachedRunStart != null) {
            payload["rt"] = _cachedRunStart;
        }

        _sender.enqueueTerminal(payload, System.getTimer());
        _sequence += 1;
        _terminalEnqueued = true;
        _cachedRunStart = null;
    }

    private function statusText() as Lang.String {
        if (_state == 4) {
            return "ENDED";
        }
        if (_state == 3) {
            return "STOPPED";
        }
        if (_state == 2) {
            return "PAUSED";
        }
        if (!_hasGPS) {
            return "WAIT GPS";
        }
        var failureCount = _sender.consecutiveFailureCount();
        if (failureCount >= 3) {
            return "NO PHONE";
        }
        if (failureCount > 0) {
            return "RETRY";
        }
        if (!_sender.hasCompleted()) {
            return "CONNECT";
        }
        if (completeAgeSeconds() <= 10) {
            return "LIVE";
        }
        return "DELAYED";
    }

    private function detailText() as Lang.String {
        if (!_sender.hasCompleted()) {
            return "Q " + _sequence.format("%d");
        }

        return completeAgeSeconds().format("%d") + "s  Q " + _sequence.format("%d");
    }

    private function completeAgeSeconds() as Lang.Number {
        return _sender.completionAgeSeconds(System.getTimer());
    }
}
