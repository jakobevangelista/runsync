import Toybox.Lang;

const TELEMETRY_WATCHDOG_MS = 15000;
const TELEMETRY_OUTCOME_NONE = 0;
const TELEMETRY_OUTCOME_SUCCESS = 1;
const TELEMETRY_OUTCOME_ERROR = 2;
const TELEMETRY_OUTCOME_TIMEOUT = 3;
const TELEMETRY_OUTCOME_EXCEPTION = 4;
const TELEMETRY_STATUS_LIVE = "LIVE";
const TELEMETRY_STATUS_CONNECT = "CONNECT";
const TELEMETRY_STATUS_RETRY = "RETRY";
const TELEMETRY_STATUS_NO_PHONE = "NO PHONE";
const TELEMETRY_STATUS_DELAYED = "DELAYED";
const TELEMETRY_STATUS_READY = "READY";

function telemetryUnsignedTimer(value as Lang.Number) as Lang.Long {
    var converted = value.toLong();
    if (converted < 0) {
        converted += 4294967296l;
    }
    return converted;
}

function telemetryElapsedMilliseconds(now as Lang.Number, start as Lang.Number) as Lang.Long {
    var current = telemetryUnsignedTimer(now);
    var beginning = telemetryUnsignedTimer(start);
    if (current >= beginning) {
        return current - beginning;
    }
    return (4294967296l - beginning) + current;
}

class TelemetrySendAction {
    var attemptId as Lang.Long;
    var payload as Lang.Dictionary;
    var terminalGeneration as Lang.Long?;

    function initialize(
        id as Lang.Long,
        body as Lang.Dictionary,
        generation as Lang.Long?
    ) {
        attemptId = id;
        payload = body;
        terminalGeneration = generation;
    }
}

class TelemetrySenderState {
    private var _nextAttemptId as Lang.Long = 0l;
    private var _activeAttemptId as Lang.Long?;
    private var _activePayload as Lang.Dictionary?;
    private var _activeTerminalGeneration as Lang.Long?;
    private var _activeStartedAt as Lang.Number?;
    private var _pendingNormal as Lang.Dictionary?;
    private var _terminal as Lang.Dictionary?;
    private var _terminalGeneration as Lang.Long = 0l;
    private var _terminalAttempts as Lang.Number = 0;
    private var _retryStartedAt as Lang.Number?;
    private var _retryDelayMilliseconds as Lang.Number = 0;

    var completedCount as Lang.Number = 0;
    var errorCount as Lang.Number = 0;
    var droppedPendingCount as Lang.Number = 0;
    var terminalCompletedCount as Lang.Number = 0;
    var terminalRetryCount as Lang.Number = 0;
    var terminalExhaustedCount as Lang.Number = 0;
    var terminalDuplicateCount as Lang.Number = 0;
    var terminalCollisionCount as Lang.Number = 0;
    var terminalSupersededCount as Lang.Number = 0;
    var timeoutCount as Lang.Number = 0;
    var synchronousExceptionCount as Lang.Number = 0;
    var staleCompletionCount as Lang.Number = 0;
    var staleErrorCount as Lang.Number = 0;
    var preemptedCount as Lang.Number = 0;
    var consecutiveFailureCount as Lang.Number = 0;
    var lastOutcome as Lang.Number = TELEMETRY_OUTCOME_NONE;
    var lastAttemptTimer as Lang.Number?;
    var lastCompleteTimer as Lang.Number?;

    function initialize() {
        _activeAttemptId = null;
        _activePayload = null;
        _activeTerminalGeneration = null;
        _activeStartedAt = null;
        _pendingNormal = null;
        _terminal = null;
        _retryStartedAt = null;
        lastAttemptTimer = null;
        lastCompleteTimer = null;
    }

    function enqueueNormal(payload as Lang.Dictionary, now as Lang.Number) as TelemetrySendAction? {
        if (_pendingNormal != null) {
            droppedPendingCount += 1;
        }
        _pendingNormal = payload;
        return pump(now);
    }

    function enqueueTerminal(payload as Lang.Dictionary, now as Lang.Number) as TelemetrySendAction? {
        if (_terminal != null) {
            terminalCollisionCount += 1;
            terminalSupersededCount += 1;
        }

        _terminalGeneration += 1l;
        _terminal = payload;
        _terminalAttempts = 0;

        if (_activeAttemptId != null) {
            preemptedCount += 1;
            clearActive();
        }

        // A new terminal event gets one immediate submission opportunity.
        _retryStartedAt = null;
        _retryDelayMilliseconds = 0;
        return pump(now);
    }

    function tick(now as Lang.Number) as TelemetrySendAction? {
        return pump(now);
    }

    function complete(attemptId as Lang.Long, now as Lang.Number) as TelemetrySendAction? {
        if (_activeAttemptId == null || (_activeAttemptId as Lang.Long) != attemptId) {
            staleCompletionCount += 1;
            return null;
        }

        var completedTerminalGeneration = _activeTerminalGeneration;
        clearActive();
        completedCount += 1;
        lastCompleteTimer = now;
        consecutiveFailureCount = 0;
        lastOutcome = TELEMETRY_OUTCOME_SUCCESS;
        _retryStartedAt = null;
        _retryDelayMilliseconds = 0;

        if (completedTerminalGeneration != null &&
            _terminal != null &&
            completedTerminalGeneration == _terminalGeneration) {
            terminalCompletedCount += 1;
            _terminal = null;
            _terminalAttempts = 0;
        }

        return pump(now);
    }

    function fail(attemptId as Lang.Long, now as Lang.Number) as TelemetrySendAction? {
        if (_activeAttemptId == null || (_activeAttemptId as Lang.Long) != attemptId) {
            staleErrorCount += 1;
            return null;
        }

        errorCount += 1;
        failActive(now, TELEMETRY_OUTCOME_ERROR);
        return pump(now);
    }

    function failSynchronously(attemptId as Lang.Long, now as Lang.Number) as TelemetrySendAction? {
        if (_activeAttemptId == null || (_activeAttemptId as Lang.Long) != attemptId) {
            staleErrorCount += 1;
            return null;
        }

        synchronousExceptionCount += 1;
        failActive(now, TELEMETRY_OUTCOME_EXCEPTION);
        return pump(now);
    }

    function recordTerminalDuplicate() as Void {
        terminalDuplicateCount += 1;
    }

    function activeAttemptId() as Lang.Long? {
        return _activeAttemptId;
    }

    function activeAttemptAgeMilliseconds(now as Lang.Number) as Lang.Long? {
        if (_activeStartedAt == null) {
            return null;
        }
        return telemetryElapsedMilliseconds(now, _activeStartedAt as Lang.Number);
    }

    function completionAgeSeconds(now as Lang.Number) as Lang.Number {
        if (lastCompleteTimer == null) {
            return 0;
        }
        return (telemetryElapsedMilliseconds(now, lastCompleteTimer as Lang.Number) / 1000l).toNumber();
    }

    function isInFlight() as Lang.Boolean {
        return _activeAttemptId != null;
    }

    function hasPendingNormal() as Lang.Boolean {
        return _pendingNormal != null;
    }

    function hasPendingTerminal() as Lang.Boolean {
        return _terminal != null;
    }

    function terminalAttemptCount() as Lang.Number {
        return _terminalAttempts;
    }

    function retryDelayMilliseconds() as Lang.Number {
        return _retryDelayMilliseconds;
    }

    function retryRemainingMilliseconds(now as Lang.Number) as Lang.Number {
        if (_retryStartedAt == null) {
            return 0;
        }

        var elapsed = telemetryElapsedMilliseconds(now, _retryStartedAt as Lang.Number);
        if (elapsed >= _retryDelayMilliseconds) {
            return 0;
        }

        return (_retryDelayMilliseconds - elapsed).toNumber();
    }

    function transportStatusText(now as Lang.Number) as Lang.String {
        if (consecutiveFailureCount >= 3) {
            return TELEMETRY_STATUS_NO_PHONE;
        }
        if (consecutiveFailureCount > 0) {
            return TELEMETRY_STATUS_RETRY;
        }
        if (lastCompleteTimer == null) {
            return TELEMETRY_STATUS_CONNECT;
        }
        if (completionAgeSeconds(now) <= 10) {
            return TELEMETRY_STATUS_LIVE;
        }
        if (lastCompleteTimer != null) {
            return TELEMETRY_STATUS_DELAYED;
        }

        return TELEMETRY_STATUS_READY;
    }

    function transportDetailText(now as Lang.Number) as Lang.String {
        var detail = "";
        var retryRemaining = retryRemainingMilliseconds(now);
        if (retryRemaining > 0) {
            detail = "WAIT " + millisecondsToDisplaySeconds(retryRemaining).format("%d") + "s";
        } else if (_activeAttemptId != null) {
            detail = "TRY " + activeAttemptAgeSeconds(now).format("%d") + "s";
        } else if (lastCompleteTimer != null) {
            detail = "OK " + completionAgeSeconds(now).format("%d") + "s";
        } else {
            detail = "NO TX";
        }

        if (lastOutcome != TELEMETRY_OUTCOME_NONE &&
            lastOutcome != TELEMETRY_OUTCOME_SUCCESS) {
            detail = detail + " " + outcomeToken();
        }
        if (consecutiveFailureCount > 0) {
            detail = detail + " F" + consecutiveFailureCount.format("%d");
        }
        if (timeoutCount > 0) {
            detail = detail + " T" + timeoutCount.format("%d");
        }
        if (synchronousExceptionCount > 0) {
            detail = detail + " X" + synchronousExceptionCount.format("%d");
        }

        return detail;
    }

    function diagnostics(now as Lang.Number) as Lang.Dictionary {
        return {
            "activeAttemptId" => _activeAttemptId,
            "activeAttemptAgeMs" => activeAttemptAgeMilliseconds(now),
            "consecutiveFailures" => consecutiveFailureCount,
            "lastOutcome" => lastOutcome,
            "transportStatus" => transportStatusText(now),
            "transportDetail" => transportDetailText(now),
            "retryRemainingMs" => retryRemainingMilliseconds(now),
            "timeouts" => timeoutCount,
            "errors" => errorCount,
            "staleCompletions" => staleCompletionCount,
            "staleErrors" => staleErrorCount,
            "preemptions" => preemptedCount,
            "synchronousExceptions" => synchronousExceptionCount,
            "terminalAttempts" => _terminalAttempts,
            "terminalExhausted" => terminalExhaustedCount,
            "pendingNormal" => _pendingNormal != null,
            "pendingTerminal" => _terminal != null
        };
    }

    private function activeAttemptAgeSeconds(now as Lang.Number) as Lang.Number {
        var age = activeAttemptAgeMilliseconds(now);
        if (age == null) {
            return 0;
        }
        return ((age as Lang.Long) / 1000l).toNumber();
    }

    private function millisecondsToDisplaySeconds(value as Lang.Number) as Lang.Number {
        if (value <= 0) {
            return 0;
        }
        return ((value.toLong() + 999l) / 1000l).toNumber();
    }

    private function outcomeToken() as Lang.String {
        if (lastOutcome == TELEMETRY_OUTCOME_ERROR) {
            return "ERR";
        }
        if (lastOutcome == TELEMETRY_OUTCOME_TIMEOUT) {
            return "TO";
        }
        if (lastOutcome == TELEMETRY_OUTCOME_EXCEPTION) {
            return "EX";
        }
        if (lastOutcome == TELEMETRY_OUTCOME_SUCCESS) {
            return "OK";
        }
        return "NA";
    }

    private function pump(now as Lang.Number) as TelemetrySendAction? {
        if (_activeAttemptId != null) {
            if (telemetryElapsedMilliseconds(now, _activeStartedAt as Lang.Number) >= TELEMETRY_WATCHDOG_MS) {
                timeoutCount += 1;
                failActive(now, TELEMETRY_OUTCOME_TIMEOUT);
            } else {
                return null;
            }
        }

        if (_retryStartedAt != null) {
            if (telemetryElapsedMilliseconds(now, _retryStartedAt as Lang.Number) < _retryDelayMilliseconds) {
                return null;
            }
            _retryStartedAt = null;
            _retryDelayMilliseconds = 0;
        }

        if (_terminal != null) {
            if (_terminalAttempts >= 4) {
                terminalExhaustedCount += 1;
                _terminal = null;
                _terminalAttempts = 0;
            } else {
                if (_terminalAttempts > 0) {
                    terminalRetryCount += 1;
                }
                _terminalAttempts += 1;
                return startAttempt(_terminal as Lang.Dictionary, _terminalGeneration, now);
            }
        }

        if (_pendingNormal == null) {
            return null;
        }

        var newest = _pendingNormal as Lang.Dictionary;
        _pendingNormal = null;
        return startAttempt(newest, null, now);
    }

    private function startAttempt(
        payload as Lang.Dictionary,
        terminalGeneration as Lang.Long?,
        now as Lang.Number
    ) as TelemetrySendAction {
        _nextAttemptId += 1l;
        _activeAttemptId = _nextAttemptId;
        _activePayload = payload;
        _activeTerminalGeneration = terminalGeneration;
        _activeStartedAt = now;
        lastAttemptTimer = now;
        return new TelemetrySendAction(_nextAttemptId, payload, terminalGeneration);
    }

    private function failActive(now as Lang.Number, outcome as Lang.Number) as Void {
        var failedTerminalGeneration = _activeTerminalGeneration;
        clearActive();
        consecutiveFailureCount += 1;
        lastOutcome = outcome;
        _retryStartedAt = now;
        _retryDelayMilliseconds = retryDelay(consecutiveFailureCount);

        if (failedTerminalGeneration != null &&
            _terminal != null &&
            failedTerminalGeneration == _terminalGeneration &&
            _terminalAttempts >= 4) {
            terminalExhaustedCount += 1;
            _terminal = null;
            _terminalAttempts = 0;
        }
    }

    private function clearActive() as Void {
        _activeAttemptId = null;
        _activePayload = null;
        _activeTerminalGeneration = null;
        _activeStartedAt = null;
    }

    private function retryDelay(failureCount as Lang.Number) as Lang.Number {
        if (failureCount <= 1) {
            return 1000;
        }
        if (failureCount == 2) {
            return 2000;
        }
        if (failureCount == 3) {
            return 4000;
        }
        if (failureCount == 4) {
            return 8000;
        }
        return 15000;
    }
}
