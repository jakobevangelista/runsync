import XCTest
@testable import RunSync

final class ActivitySessionAssemblerTests: XCTestCase {
    private let device = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let otherDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let runA = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let runB = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    private let baseDate = Date(timeIntervalSince1970: 1_783_884_160)

    func testWaitingNeverCreatesActivity() {
        let transition = assembler(runA).propose(
            input: input(state: .waiting, start: nil, elapsed: 0),
            current: nil
        )
        XCTAssertEqual(transition.action, .observe(.idleWaiting))
        XCTAssertNil(transition.assignedRunID)
    }

    func testFirstRunningCreatesActivity() {
        let transition = assembler(runA).propose(input: input(state: .running), current: nil)
        XCTAssertEqual(transition.action, .startNew)
        XCTAssertEqual(transition.assignedRunID, runA)
        XCTAssertEqual(transition.proposedState?.phase, .active)
    }

    func testRunningPausedResumedRetainsActivity() {
        let running = startSession()
        let paused = assembler(runB).propose(
            input: input(state: .paused, elapsed: 2_000, offset: 1),
            current: running
        )
        XCTAssertEqual(paused.assignedRunID, runA)
        XCTAssertEqual(paused.proposedState?.phase, .paused)

        let resumed = assembler(runB).propose(
            input: input(state: .running, elapsed: 3_000, offset: 2),
            current: paused.proposedState
        )
        XCTAssertEqual(resumed.assignedRunID, runA)
        XCTAssertEqual(resumed.action, .assignExisting)
    }

    func testStoppedResumeWithContinuingElapsedRetainsActivity() {
        let stopped = assembler(runB).propose(
            input: input(state: .stopped, elapsed: 35_000, offset: 1),
            current: startSession(elapsed: 30_000)
        )
        let resumed = assembler(runB).propose(
            input: input(state: .running, elapsed: 36_000, offset: 2),
            current: stopped.proposedState
        )
        XCTAssertEqual(resumed.assignedRunID, runA)
    }

    func testWaitingResetClosesWithoutAssignment() {
        let transition = assembler(runB).propose(
            input: input(state: .waiting, start: nil, elapsed: 0, offset: 1),
            current: startSession()
        )
        XCTAssertEqual(transition.action, .closeWithoutAssignment(.implicitTimerReset))
        XCTAssertNil(transition.assignedRunID)
        XCTAssertEqual(transition.priorClosure?.localRunID, runA)
    }

    func testCompatibleWaitingIsObservedWithoutClosing() {
        let current = startSession(elapsed: 30_000)
        let transition = assembler(runB).propose(
            input: input(state: .waiting, elapsed: 31_000, offset: 1),
            current: current
        )
        XCTAssertEqual(transition.action, .observe(.anomalousWaiting))
        XCTAssertEqual(transition.proposedState, current)
    }

    func testEndedAssignsCurrentActivityThenCloses() {
        let transition = assembler(runB).propose(
            input: input(state: .ended, elapsed: 40_000, offset: 1),
            current: startSession(elapsed: 30_000)
        )
        XCTAssertEqual(transition.action, .assignAndClose(.watchEnded))
        XCTAssertEqual(transition.assignedRunID, runA)
        XCTAssertNil(transition.proposedState)
    }

    func testEndedWhileIdleIsObserved() {
        let transition = assembler(runA).propose(input: input(state: .ended), current: nil)
        XCTAssertEqual(transition.action, .observe(.idleNonRunning))
    }

    func testNilStartBackfillsWithoutSplit() {
        let current = startSession(start: nil)
        let transition = assembler(runB).propose(
            input: input(state: .running, start: 123, elapsed: 2_000, offset: 1),
            current: current
        )
        XCTAssertEqual(transition.action, .assignExisting)
        XCTAssertEqual(transition.assignedRunID, runA)
        XCTAssertEqual(transition.proposedState?.activityStartEpochSeconds, 123)
    }

    func testChangedKnownStartSplitsRunning() {
        let transition = assembler(runB).propose(
            input: input(state: .running, start: 456, elapsed: 1_000, offset: 1),
            current: startSession(start: 123, elapsed: 30_000)
        )
        XCTAssertEqual(transition.action, .split(.changedGarminStart))
        XCTAssertEqual(transition.assignedRunID, runB)
        XCTAssertEqual(transition.priorClosure?.localRunID, runA)
    }

    func testMaterialElapsedResetWithoutKnownStartSplits() {
        let transition = assembler(runB).propose(
            input: input(state: .running, start: nil, elapsed: 2_000, offset: 1),
            current: startSession(start: nil, elapsed: 35_000)
        )
        XCTAssertEqual(transition.action, .split(.elapsedReset))
    }

    func testSmallElapsedRegressionDoesNotSplit() {
        let transition = assembler(runB).propose(
            input: input(state: .running, start: nil, elapsed: 29_000, offset: 1),
            current: startSession(start: nil, elapsed: 30_000)
        )
        XCTAssertEqual(transition.action, .assignExisting)
    }

    func testEqualKnownStartWinsOverElapsedReset() {
        let transition = assembler(runB).propose(
            input: input(state: .running, start: 123, elapsed: 1_000, offset: 1),
            current: startSession(start: 123, elapsed: 40_000)
        )
        XCTAssertEqual(transition.action, .assignExisting)
    }

    func testChangedStartOnStoppedClosesAndObserves() {
        let transition = assembler(runB).propose(
            input: input(state: .stopped, start: 456, elapsed: 1_000, offset: 1),
            current: startSession(start: 123, elapsed: 30_000)
        )
        XCTAssertEqual(transition.action, .closeWithoutAssignment(.incompatibleNonRunning))
        XCTAssertNil(transition.assignedRunID)
    }

    func testStaleEndedWithChangedStartDoesNotClose() {
        let current = startSession(start: 123)
        let transition = assembler(runB).propose(
            input: input(state: .ended, start: 456, elapsed: nil, offset: 1),
            current: current
        )
        XCTAssertEqual(transition.action, .observe(.staleTerminal))
        XCTAssertEqual(transition.proposedState, current)
    }

    func testSequenceResetAndLongGapDoNotSplit() {
        let current = startSession(start: 123, elapsed: 30_000)
        var sample = TelemetryTestSupport.sample(sequence: 0, state: .running, start: 123, elapsed: 31_000)
        let transition = assembler(runB).propose(
            input: ActivitySessionInput(
                deviceID: device,
                selectedDeviceID: device,
                phoneReceivedAt: baseDate.addingTimeInterval(86_400),
                sample: sample
            ),
            current: current
        )
        XCTAssertEqual(transition.action, .assignExisting)
        sample = TelemetryTestSupport.sample(sequence: 1, state: .running, start: 123, elapsed: 32_000)
        XCTAssertEqual(sample.sequence, 1)
    }

    func testNonSelectedDeviceCannotMutateSession() {
        let current = startSession()
        let transition = assembler(runB).propose(
            input: input(state: .ended, deviceID: otherDevice, selectedDeviceID: device, offset: 1),
            current: current
        )
        XCTAssertEqual(transition.action, .observe(.nonSelectedDevice))
        XCTAssertEqual(transition.proposedState, current)
    }

    func testDelayedResetCannotCloseNewerSession() {
        let current = startSession()
        let transition = assembler(runB).propose(
            input: input(state: .waiting, start: nil, elapsed: 0, offset: -1),
            current: current
        )
        XCTAssertEqual(transition.action, .observe(.staleReceipt))
        XCTAssertEqual(transition.proposedState, current)
    }

    private func assembler(_ runID: UUID) -> ActivitySessionAssembler {
        ActivitySessionAssembler(makeRunID: { runID })
    }

    private func startSession(
        start: Int? = 123,
        elapsed: Int? = 1_000
    ) -> ActivitySessionState {
        assembler(runA).propose(
            input: input(state: .running, start: start, elapsed: elapsed),
            current: nil
        ).proposedState!
    }

    private func input(
        state: ActivityState,
        start: Int? = 123,
        elapsed: Int? = 1_000,
        deviceID: UUID? = nil,
        selectedDeviceID: UUID? = nil,
        offset: TimeInterval = 0
    ) -> ActivitySessionInput {
        ActivitySessionInput(
            deviceID: deviceID ?? device,
            selectedDeviceID: selectedDeviceID ?? device,
            phoneReceivedAt: baseDate.addingTimeInterval(offset),
            sample: TelemetryTestSupport.sample(state: state, start: start, elapsed: elapsed)
        )
    }
}
