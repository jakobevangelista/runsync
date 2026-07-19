import Foundation

enum TelemetryBatchCodec {
    private struct BatchRequest: Encodable {
        let installationId: UUID
        let envelopes: [EnvelopeRequest]
    }

    private struct EnvelopeRequest: Encodable {
        let envelopeId: UUID
        let activityId: UUID
        let phoneReceivedAt: String
        let garminDeviceIdentifier: UUID
        let appVersion: String
        let sample: TelemetrySample
    }

    private struct BatchResponse: Decodable {
        let acknowledgedEnvelopeIds: [String]
        let serverTime: String
    }

    static func encode(_ envelopes: [TelemetryEnvelope]) throws -> Data {
        guard !envelopes.isEmpty, envelopes.count <= 100,
              let installationID = envelopes.first?.installationID,
              envelopes.allSatisfy({ $0.installationID == installationID }) else {
            throw TelemetrySinkError.permanent(reason: "Invalid upload batch")
        }
        return try JSONEncoder().encode(BatchRequest(
            installationId: installationID,
            envelopes: envelopes.map {
                EnvelopeRequest(
                    envelopeId: $0.id,
                    activityId: $0.localRunID,
                    phoneReceivedAt: timestamp($0.phoneReceivedAt),
                    garminDeviceIdentifier: $0.garminDeviceIdentifier,
                    appVersion: $0.appVersion,
                    sample: $0.sample
                )
            }
        ))
    }

    static func decodeAcknowledgements(_ data: Data, requested: Set<UUID>) throws -> [UUID] {
        let response = try JSONDecoder().decode(BatchResponse.self, from: data)
        guard parseTimestamp(response.serverTime) != nil else {
            throw TelemetrySinkError.transient(retryAfter: nil)
        }
        let identifiers = try response.acknowledgedEnvelopeIds.map { value -> UUID in
            guard let identifier = UUID(uuidString: value), requested.contains(identifier) else {
                throw TelemetrySinkError.transient(retryAfter: nil)
            }
            return identifier
        }
        guard Set(identifiers).count == identifiers.count else {
            throw TelemetrySinkError.transient(retryAfter: nil)
        }
        return identifiers
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter.telemetryWithFractionalSeconds.string(from: date)
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        ISO8601DateFormatter.telemetryWithFractionalSeconds.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
    }
}

extension ISO8601DateFormatter {
    fileprivate static var telemetryWithFractionalSeconds: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
