import Foundation

final class HTTPTelemetrySink: BoundTelemetrySink, CancellableTelemetrySink, @unchecked Sendable {
    private struct ErrorResponse: Decodable {
        struct Details: Decodable {
            let code: String?
            let envelopeId: String?
            let retryable: Bool?
        }

        let error: Details
    }

    private let configuration: ServerConfigurationStore
    private let session: URLSession
    private let requestTimeout: TimeInterval

    init(
        configuration: ServerConfigurationStore,
        session: URLSession? = nil,
        requestTimeout: TimeInterval = 30
    ) {
        self.configuration = configuration
        self.session = session ?? Self.makeForegroundSession()
        self.requestTimeout = requestTimeout
    }

    static func makeForegroundSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        return URLSession(
            configuration: configuration,
            delegate: TelemetryRedirectRejectingDelegate(),
            delegateQueue: nil
        )
    }

    func cancelAll() {
        session.getAllTasks { $0.forEach { $0.cancel() } }
    }

    func submit(_ envelopes: [TelemetryEnvelope]) async throws -> [UUID] {
        guard let configuration = try await configuration.current() else { throw TelemetrySinkError.notConfigured }
        return try await submit(envelopes, server: configuration)
    }

    func submit(_ envelopes: [TelemetryEnvelope], server: ServerConfiguration) async throws -> [UUID] {
        guard !envelopes.isEmpty else { return [] }
        guard envelopes.count <= 100 else { throw TelemetrySinkError.permanent(reason: "Invalid upload batch") }
        guard let installationID = envelopes.first?.installationID,
              envelopes.allSatisfy({ $0.installationID == installationID }) else {
            throw TelemetrySinkError.permanent(reason: "Invalid installation batch")
        }

        var request = URLRequest(url: server.baseURL.appendingPathComponent("v1/telemetry/batches"))
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        do {
            request.httpBody = try TelemetryBatchCodec.encode(envelopes)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw TelemetrySinkError.transient(retryAfter: nil) }
            guard (200...299).contains(http.statusCode) else { throw Self.classify(http, data: data) }
            guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("application/json") == true else {
                throw TelemetrySinkError.transient(retryAfter: nil)
            }
            return try TelemetryBatchCodec.decodeAcknowledgements(data, requested: Set(envelopes.map(\.id)))
        } catch let error as TelemetrySinkError {
            throw error
        } catch is DecodingError {
            throw TelemetrySinkError.transient(retryAfter: nil)
        } catch {
            throw TelemetrySinkError.transient(retryAfter: nil)
        }
    }

    static func classify(_ response: HTTPURLResponse, data: Data) -> TelemetrySinkError {
        switch response.statusCode {
        case 300...399:
            return .permanent(reason: "Unexpected server redirect")
        case 408, 425, 429, 500...599:
            return .transient(retryAfter: Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        case 401:
            return .authentication
        default:
            let details = try? JSONDecoder().decode(ErrorResponse.self, from: data).error
            return .rejected(TelemetryServerRejection(
                statusCode: response.statusCode,
                code: details?.code.flatMap(TelemetryServerErrorCode.init(rawValue:)),
                envelopeID: details?.envelopeId.flatMap(UUID.init(uuidString:)),
                retryable: details?.retryable
            ))
        }
    }

    private static func retryAfter(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        guard let date = HTTPDateFormatter.formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}

final class TelemetryRedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
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
