import XCTest
@testable import RunSync

final class GarminReceiptPipelineTests: XCTestCase {
    func testReceiptsRemainFIFOAndTimestampsBecomeStrictlyOrdered() async throws {
        let recorder = ReceiptRecorder()
        let pipeline = GarminReceiptPipeline { receipt in
            await recorder.append(receipt)
            return .processed
        }
        let timestamp = Date(timeIntervalSince1970: 100)
        let deviceID = UUID()

        for sequence in 1...3 {
            XCTAssertTrue(pipeline.enqueue(
                TelemetryTestSupport.sample(sequence: sequence),
                from: deviceID,
                at: timestamp
            ))
        }
        for _ in 0..<50 {
            if await recorder.receipts.count == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let receipts = await recorder.receipts
        XCTAssertEqual(receipts.map(\.sample.sequence), [1, 2, 3])
        XCTAssertEqual(receipts.map(\.callbackOrdinal), [1, 2, 3])
        XCTAssertLessThan(receipts[0].phoneReceivedAt, receipts[1].phoneReceivedAt)
        XCTAssertLessThan(receipts[1].phoneReceivedAt, receipts[2].phoneReceivedAt)
    }

    func testQueueIsBoundedWithoutDroppingAcceptedReceipts() async throws {
        let gate = ReceiptGate()
        let pipeline = GarminReceiptPipeline(maximumQueuedReceipts: 1) { receipt in
            await gate.consume(receipt)
            return .processed
        }
        let deviceID = UUID()

        XCTAssertTrue(pipeline.enqueue(TelemetryTestSupport.sample(sequence: 1), from: deviceID))
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(pipeline.enqueue(TelemetryTestSupport.sample(sequence: 2), from: deviceID))
        XCTAssertFalse(pipeline.enqueue(TelemetryTestSupport.sample(sequence: 3), from: deviceID))
        await gate.release()
    }

    func testPausedReceiptRetriesOnlyAfterPrioritizedRecoveryOperation() async throws {
        let recorder = PausingReceiptRecorder()
        let pipeline = GarminReceiptPipeline { receipt in
            await recorder.consume(receipt)
        }
        let deviceID = UUID()
        XCTAssertTrue(pipeline.enqueue(TelemetryTestSupport.sample(), from: deviceID))
        for _ in 0..<50 {
            if await recorder.events.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(pipeline.requestRecovery {
            await recorder.recordRecovery()
            return true
        })
        for _ in 0..<50 {
            if await recorder.events.count == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let events = await recorder.events
        XCTAssertEqual(events, ["receipt-1", "recovery", "receipt-2"])
    }

    func testRecoveryBarrierCannotBeRejectedByFullReceiptQueueAndCoalesces() async throws {
        let gate = RecoveryBarrierRecorder()
        let pipeline = GarminReceiptPipeline(maximumQueuedReceipts: 1) { receipt in
            await gate.consume(receipt)
            return .processed
        }
        let deviceID = UUID()
        XCTAssertTrue(pipeline.enqueue(TelemetryTestSupport.sample(sequence: 1), from: deviceID))
        await gate.waitUntilConsuming()
        XCTAssertTrue(pipeline.enqueue(TelemetryTestSupport.sample(sequence: 2), from: deviceID))

        XCTAssertTrue(pipeline.requestRecovery {
            await gate.recover()
            return true
        })
        XCTAssertFalse(pipeline.requestRecovery { true })
        await gate.releaseReceipt()
        for _ in 0..<50 {
            if await gate.events.count == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let events = await gate.events
        XCTAssertEqual(events, ["receipt-1", "recovery", "receipt-2"])
        XCTAssertEqual(pipeline.droppedReceiptCount, 0)
    }
}

private actor ReceiptRecorder {
    private(set) var receipts: [GarminReceipt] = []
    func append(_ receipt: GarminReceipt) { receipts.append(receipt) }
}

private actor ReceiptGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func consume(_ receipt: GarminReceipt) async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() { continuation?.resume() }
}

private actor PausingReceiptRecorder {
    private(set) var events: [String] = []
    private var attempt = 0

    func consume(_ receipt: GarminReceipt) -> GarminReceiptHandling {
        attempt += 1
        events.append("receipt-\(attempt)")
        return attempt == 1 ? .pause(retryCurrent: true) : .processed
    }

    func recordRecovery() { events.append("recovery") }
}

private actor RecoveryBarrierRecorder {
    private(set) var events: [String] = []
    private var receiptContinuation: CheckedContinuation<Void, Never>?
    private var consumingContinuation: CheckedContinuation<Void, Never>?

    func consume(_ receipt: GarminReceipt) async {
        events.append("receipt-\(receipt.sample.sequence)")
        if receipt.sample.sequence == 1 {
            consumingContinuation?.resume()
            consumingContinuation = nil
            await withCheckedContinuation { receiptContinuation = $0 }
        }
    }

    func waitUntilConsuming() async {
        if !events.isEmpty { return }
        await withCheckedContinuation { consumingContinuation = $0 }
    }

    func releaseReceipt() {
        receiptContinuation?.resume()
        receiptContinuation = nil
    }

    func recover() {
        events.append("recovery")
    }
}
