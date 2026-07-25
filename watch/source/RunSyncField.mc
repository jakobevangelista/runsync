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
        decoratePayload(payload, now);
        _sender.enqueue(payload, now);
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        View.onUpdate(dc);

        var now = System.getTimer();
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
            titleFont, statusText(now), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(dc.getWidth() / 2, dc.getHeight() * 0.62,
            detailFont, detailText(now), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
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

        var now = System.getTimer();
        decoratePayload(payload, now);
        _sender.enqueueTerminal(payload, now);
        _sequence += 1;
        _terminalEnqueued = true;
        _cachedRunStart = null;
    }

    private function statusText(now as Lang.Number) as Lang.String {
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
        return _sender.transportStatusText(now);
    }

    private function detailText(now as Lang.Number) as Lang.String {
        var diagnostics = _sender.diagnostics(now);
        return "R2  Q " + _sequence.format("%d")
            + "  T" + diagnosticCounter(diagnostics["timeouts"]).format("%d")
            + " F" + diagnosticCounter(diagnostics["consecutiveFailures"]).format("%d");
    }

    private function decoratePayload(payload as Lang.Dictionary, now as Lang.Number) as Void {
        if (RUNSYNC_WATCH_BUILD_ID != null && RUNSYNC_WATCH_BUILD_ID.length() > 0) {
            payload["wb"] = RUNSYNC_WATCH_BUILD_ID;
        }

        var diagnostics = _sender.diagnostics(now);
        payload["wt"] = diagnosticCounter(diagnostics["timeouts"]);
        payload["we"] = diagnosticCounter(diagnostics["errors"]);
        payload["wx"] = diagnosticCounter(diagnostics["synchronousExceptions"]);
        payload["wf"] = diagnosticCounter(diagnostics["consecutiveFailures"]);
        payload["wo"] = diagnosticOutcome(diagnostics["lastOutcome"]);
    }

    private function diagnosticOutcome(value as Lang.Object?) as Lang.Number {
        if (value == null) {
            return 0;
        }
        var outcome = value as Lang.Number;
        if (outcome < 0) {
            return 0;
        }
        if (outcome > 4) {
            return 4;
        }
        return outcome;
    }

    private function diagnosticCounter(value as Lang.Object?) as Lang.Number {
        if (value == null) {
            return 0;
        }
        var counter = value as Lang.Number;
        if (counter < 0) {
            return 0;
        }
        if (counter > 2147483647) {
            return 2147483647;
        }
        return counter;
    }
}
