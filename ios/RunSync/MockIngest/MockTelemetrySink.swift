import Foundation

enum MockSinkFailure: Error {
    case injected
}

actor MockTelemetrySink {
    private var acceptedIDs: Set<UUID> = []
    private var shouldFail = false
    private let latencyNanoseconds: UInt64

    init(latencyNanoseconds: UInt64 = 100_000_000) {
        self.latencyNanoseconds = latencyNanoseconds
    }

    func setFailureInjection(_ enabled: Bool) {
        shouldFail = enabled
    }

    func submit(_ envelopes: [TelemetryEnvelope]) async throws -> [UUID] {
        if latencyNanoseconds > 0 {
            try await Task.sleep(nanoseconds: latencyNanoseconds)
        }
        guard !shouldFail else { throw MockSinkFailure.injected }

        let identifiers = envelopes.map(\.id)
        acceptedIDs.formUnion(identifiers)
        return identifiers
    }

    func hasAccepted(_ identifier: UUID) -> Bool {
        acceptedIDs.contains(identifier)
    }
}
