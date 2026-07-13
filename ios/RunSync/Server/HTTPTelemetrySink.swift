import Foundation

final class HTTPTelemetrySink: TelemetrySink, @unchecked Sendable {
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

    private let configuration: ServerConfigurationStore
    private let session: URLSession
    private let requestTimeout: TimeInterval

    init(
        configuration: ServerConfigurationStore,
        session: URLSession = .shared,
        requestTimeout: TimeInterval = 15
    ) {
        self.configuration = configuration
        self.session = session
        self.requestTimeout = requestTimeout
    }

    func submit(_ envelopes: [TelemetryEnvelope]) async throws -> [UUID] {
        guard !envelopes.isEmpty else { return [] }
        guard envelopes.count <= 100 else { throw TelemetrySinkError.permanent(reason: "Invalid upload batch") }
        guard let configuration = try await configuration.current() else { throw TelemetrySinkError.notConfigured }
        guard let installationID = envelopes.first?.installationID,
              envelopes.allSatisfy({ $0.installationID == installationID }) else {
            throw TelemetrySinkError.permanent(reason: "Invalid installation batch")
        }

        let body = BatchRequest(
            installationId: installationID,
            envelopes: envelopes.map {
                EnvelopeRequest(
                    envelopeId: $0.id,
                    activityId: $0.localRunID,
                    phoneReceivedAt: Self.timestamp($0.phoneReceivedAt),
                    garminDeviceIdentifier: $0.garminDeviceIdentifier,
                    appVersion: $0.appVersion,
                    sample: $0.sample
                )
            }
        )
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("v1/telemetry/batches"))
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        do {
            request.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw TelemetrySinkError.transient(retryAfter: nil) }
            guard (200...299).contains(http.statusCode) else { throw classify(http) }
            guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("application/json") == true else {
                throw TelemetrySinkError.transient(retryAfter: nil)
            }
            return try parseResponse(data, requested: Set(envelopes.map(\.id)))
        } catch let error as TelemetrySinkError {
            throw error
        } catch is DecodingError {
            throw TelemetrySinkError.transient(retryAfter: nil)
        } catch {
            throw TelemetrySinkError.transient(retryAfter: nil)
        }
    }

    private func parseResponse(_ data: Data, requested: Set<UUID>) throws -> [UUID] {
        let response = try JSONDecoder().decode(BatchResponse.self, from: data)
        guard Self.parseTimestamp(response.serverTime) != nil else {
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

    private func classify(_ response: HTTPURLResponse) -> TelemetrySinkError {
        switch response.statusCode {
        case 408, 425, 429, 500...599:
            return .transient(retryAfter: Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        case 401, 403:
            return .permanent(reason: "Authentication rejected")
        case 400, 404, 405, 409, 413, 415, 422:
            return .permanent(reason: "Upload rejected")
        default:
            return .permanent(reason: "Server error (HTTP \(response.statusCode))")
        }
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter.withFractionalSeconds.string(from: date)
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        ISO8601DateFormatter.withFractionalSeconds.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func retryAfter(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        guard let date = HTTPDateFormatter.formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}

private extension ISO8601DateFormatter {
    static var withFractionalSeconds: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

private enum HTTPDateFormatter {
    static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        return formatter
    }
}
