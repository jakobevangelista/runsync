import Foundation

protocol TelemetrySink: Sendable {
    func submit(_ envelopes: [TelemetryEnvelope]) async throws -> [UUID]
}

protocol BoundTelemetrySink: TelemetrySink {
    func submit(_ envelopes: [TelemetryEnvelope], server: ServerConfiguration) async throws -> [UUID]
}

protocol CancellableTelemetrySink: TelemetrySink {
    func cancelAll()
}

enum TelemetryServerErrorCode: String, Codable, Equatable, Sendable {
    case invalidRequest = "invalid_request"
    case invalidEnvelope = "invalid_envelope"
    case unsupportedProtocol = "unsupported_protocol"
    case installationOwnershipConflict = "installation_ownership_conflict"
    case envelopeOwnershipConflict = "envelope_ownership_conflict"
    case envelopeConflict = "envelope_conflict"
}

struct TelemetryServerRejection: Equatable, Sendable {
    let statusCode: Int
    let code: TelemetryServerErrorCode?
    let envelopeID: UUID?
    let retryable: Bool?
}

enum TelemetrySinkError: Error, Equatable, Sendable {
    case notConfigured
    case transient(retryAfter: TimeInterval?)
    case authentication
    case rejected(TelemetryServerRejection)
    case permanent(reason: String)
}
