import Toybox.Lang;
import Toybox.System;

(:simulator) class TelemetrySender {
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
        lastAttemptTimer = null;
        lastCompleteTimer = null;
    }

    function enqueue(payload as Lang.Dictionary) as Void {
        lastAttemptTimer = System.getTimer();
        lastCompleteTimer = lastAttemptTimer;
        completedCount += 1;
    }

    function enqueueTerminal(payload as Lang.Dictionary) as Void {
        enqueue(payload);
        terminalCompletedCount += 1;
    }

    function recordTerminalDuplicate() as Void {
        terminalDuplicateCount += 1;
    }

    function isInFlight() as Lang.Boolean {
        return false;
    }
}
