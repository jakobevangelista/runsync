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

    function initialize() {
        DataField.initialize();
        _encoder = new TelemetryEncoder();
        _sender = new TelemetrySender();
    }

    function compute(info as Activity.Info) as Void {
        _hasGPS = info has :currentLocation && info.currentLocation != null;
        var payload = _encoder.encode(info, _sequence, _state);
        _state = payload["st"] as Lang.Number;
        _sequence += 1;
        _sender.enqueue(payload);
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
        if (_sender.errorCount > 0 && _sender.lastCompleteTimer == null) {
            return "NO PHONE";
        }
        if (_sender.lastCompleteTimer != null && completeAgeSeconds() > 10) {
            return "DELAYED";
        }
        if (_state == 1) {
            return "LIVE";
        }

        return "READY";
    }

    private function detailText() as Lang.String {
        if (_sender.lastCompleteTimer == null) {
            return "Q " + _sequence.format("%d");
        }

        return completeAgeSeconds().format("%d") + "s  Q " + _sequence.format("%d");
    }

    private function completeAgeSeconds() as Lang.Number {
        if (_sender.lastCompleteTimer == null) {
            return 0;
        }

        return ((System.getTimer() - (_sender.lastCompleteTimer as Lang.Number)) / 1000).toNumber();
    }
}
