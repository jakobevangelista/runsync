import Foundation

struct GarminReceipt: Sendable {
    let sample: TelemetrySample
    let deviceID: UUID
    let phoneReceivedAt: Date
    let callbackOrdinal: UInt64
}

enum GarminReceiptHandling: Sendable {
    case processed
    case pause(retryCurrent: Bool)
}

final class GarminReceiptPipeline: @unchecked Sendable {
    private enum WorkItem {
        case receipt(GarminReceipt)
        case operation(@Sendable () async -> Bool)
        case recovery(@Sendable () async -> Bool)
    }

    private let lock = NSLock()
    private let maximumQueuedReceipts: Int
    private let consume: @Sendable (GarminReceipt) async -> GarminReceiptHandling
    private let onPause: @Sendable () -> Void
    private var workItems: [WorkItem] = []
    private var recoveryOperation: (@Sendable () async -> Bool)?
    private var recoveryInProgress = false
    private var draining = false
    private var nextOrdinal: UInt64 = 0
    private var lastReceivedAt: Date?
    private var droppedReceipts = 0

    init(
        maximumQueuedReceipts: Int = 256,
        consume: @escaping @Sendable (GarminReceipt) async -> GarminReceiptHandling,
        onPause: @escaping @Sendable () -> Void = {}
    ) {
        self.maximumQueuedReceipts = maximumQueuedReceipts
        self.consume = consume
        self.onPause = onPause
    }

    @discardableResult
    func enqueue(_ sample: TelemetrySample, from deviceID: UUID, at callbackTime: Date = Date()) -> Bool {
        let shouldStart: Bool
        lock.lock()
        guard queuedReceiptCount < maximumQueuedReceipts else {
            droppedReceipts += 1
            lock.unlock()
            return false
        }

        nextOrdinal &+= 1
        let receivedAt: Date
        if let lastReceivedAt, callbackTime <= lastReceivedAt {
            receivedAt = lastReceivedAt.addingTimeInterval(0.000_001)
        } else {
            receivedAt = callbackTime
        }
        lastReceivedAt = receivedAt
        workItems.append(.receipt(GarminReceipt(
            sample: sample,
            deviceID: deviceID,
            phoneReceivedAt: receivedAt,
            callbackOrdinal: nextOrdinal
        )))
        shouldStart = !draining
        if shouldStart { draining = true }
        lock.unlock()

        if shouldStart {
            Task { [weak self] in await self?.drain() }
        }
        return true
    }

    @discardableResult
    func enqueueOperation(_ operation: @escaping @Sendable () async -> Bool) -> Bool {
        let shouldStart: Bool
        lock.lock()
        guard workItems.count < maximumQueuedReceipts else {
            lock.unlock()
            return false
        }
        if !draining, !workItems.isEmpty {
            workItems.insert(.operation(operation), at: 0)
        } else {
            workItems.append(.operation(operation))
        }
        shouldStart = !draining
        if shouldStart { draining = true }
        lock.unlock()
        if shouldStart {
            Task { [weak self] in await self?.drain() }
        }
        return true
    }

    @discardableResult
    func requestRecovery(_ operation: @escaping @Sendable () async -> Bool) -> Bool {
        let shouldStart: Bool
        lock.lock()
        guard recoveryOperation == nil, !recoveryInProgress else {
            lock.unlock()
            return false
        }
        recoveryOperation = operation
        shouldStart = !draining
        if shouldStart { draining = true }
        lock.unlock()
        if shouldStart {
            Task { [weak self] in await self?.drain() }
        }
        return true
    }

    var droppedReceiptCount: Int {
        lock.withLock { droppedReceipts }
    }

    func resume() {
        let shouldStart = lock.withLock {
            guard !draining, !workItems.isEmpty else { return false }
            draining = true
            return true
        }
        if shouldStart {
            Task { [weak self] in await self?.drain() }
        }
    }

    private func drain() async {
        while let item = nextWorkItem() {
            switch item {
            case .receipt(let receipt):
                switch await consume(receipt) {
                case .processed:
                    break
                case .pause(let retryCurrent):
                    pause(with: retryCurrent ? item : nil)
                    onPause()
                    return
                }
            case .operation(let operation):
                guard await operation() else {
                    pause(with: item)
                    onPause()
                    return
                }
            case .recovery(let operation):
                let succeeded = await operation()
                lock.withLock { recoveryInProgress = false }
                guard succeeded else {
                    pause(with: nil)
                    onPause()
                    return
                }
            }
        }
    }

    private func nextWorkItem() -> WorkItem? {
        lock.withLock {
            if let recoveryOperation {
                self.recoveryOperation = nil
                recoveryInProgress = true
                return .recovery(recoveryOperation)
            }
            guard !workItems.isEmpty else {
                draining = false
                return nil
            }
            return workItems.removeFirst()
        }
    }

    private func pause(with failedItem: WorkItem?) {
        lock.withLock {
            if let failedItem { workItems.insert(failedItem, at: 0) }
            draining = false
        }
    }


    private var queuedReceiptCount: Int {
        workItems.reduce(into: 0) { count, item in
            if case .receipt = item { count += 1 }
        }
    }
}
