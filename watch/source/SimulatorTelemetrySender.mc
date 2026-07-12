import Toybox.Lang;
import Toybox.System;

(:simulator) class TelemetrySender {
    var completedCount as Lang.Number = 0;
    var errorCount as Lang.Number = 0;
    var droppedPendingCount as Lang.Number = 0;
    var lastAttemptTimer as Lang.Number?;
    var lastCompleteTimer as Lang.Number?;

    function initialize() {
        lastAttemptTimer = null;
        lastCompleteTimer = null;
    }

    function enqueue(payload as Lang.Dictionary) as Void {
        lastAttemptTimer = System.getTimer();
        lastCompleteTimer = lastAttemptTimer;
        completedCount += 1;
    }

    function isInFlight() as Lang.Boolean {
        return false;
    }
}
