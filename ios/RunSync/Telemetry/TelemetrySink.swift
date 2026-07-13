import Foundation

protocol TelemetrySink: Sendable {
    func submit(_ envelopes: [TelemetryEnvelope]) async throws -> [UUID]
}

enum TelemetrySinkError: Error, Equatable, Sendable {
    case notConfigured
    case transient(retryAfter: TimeInterval?)
    case permanent(reason: String)
}
