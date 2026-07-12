import Toybox.Activity;
import Toybox.Lang;
import Toybox.Math;

class TelemetryEncoder {
    function encode(info as Activity.Info, sequence as Lang.Number, fallbackState as Lang.Number) as Lang.Dictionary {
        var payload = {
            "v" => 1,
            "q" => sequence,
            "st" => timerState(info, fallbackState)
        };

        if (info has :startTime && info.startTime != null) {
            payload["rt"] = info.startTime.value();
        }
        if (info has :elapsedTime && info.elapsedTime != null) {
            payload["tm"] = info.elapsedTime;
        }
        if (info has :elapsedDistance && info.elapsedDistance != null) {
            payload["d"] = scaled(info.elapsedDistance, 10.0f);
        }
        if (info has :currentSpeed && info.currentSpeed != null) {
            payload["sp"] = scaled(info.currentSpeed, 1000.0f);
        }
        if (info has :currentHeartRate && info.currentHeartRate != null) {
            payload["hr"] = info.currentHeartRate;
        }
        if (info has :currentCadence && info.currentCadence != null) {
            payload["cad"] = info.currentCadence;
        }
        if (info has :currentLocation && info.currentLocation != null) {
            var coordinates = info.currentLocation.toDegrees();
            var latitude = coordinates[0];
            var longitude = coordinates[1];

            if (latitude >= -90.0f && latitude <= 90.0f &&
                longitude >= -180.0f && longitude <= 180.0f) {
                payload["lat"] = scaled(latitude, 1000000.0f);
                payload["lon"] = scaled(longitude, 1000000.0f);
            }
        }
        if (info has :currentLocationAccuracy && info.currentLocationAccuracy != null) {
            payload["gps"] = info.currentLocationAccuracy;
        }
        if (info has :altitude && info.altitude != null) {
            payload["alt"] = scaled(info.altitude, 10.0f);
        }
        if (info has :totalAscent && info.totalAscent != null) {
            payload["asc"] = info.totalAscent;
        }

        return payload;
    }

    private function timerState(info as Activity.Info, fallbackState as Lang.Number) as Lang.Number {
        if (!(info has :timerState) || info.timerState == null) {
            return fallbackState;
        }

        if (info.timerState == Activity.TIMER_STATE_ON) {
            return 1;
        }
        if (info.timerState == Activity.TIMER_STATE_PAUSED) {
            return 2;
        }
        if (info.timerState == Activity.TIMER_STATE_STOPPED) {
            return 3;
        }
        if (info.timerState == Activity.TIMER_STATE_OFF) {
            return 0;
        }

        return fallbackState;
    }

    private function scaled(value as Lang.Numeric, multiplier as Lang.Numeric) as Lang.Number {
        var scaledValue = value * multiplier;
        if (scaledValue >= 0.0f) {
            return Math.floor(scaledValue + 0.5f).toNumber();
        }

        return Math.ceil(scaledValue - 0.5f).toNumber();
    }
}
