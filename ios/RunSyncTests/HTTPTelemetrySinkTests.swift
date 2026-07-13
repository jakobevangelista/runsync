import XCTest
@testable import RunSync

final class HTTPTelemetrySinkTests: XCTestCase {
    private var defaults: UserDefaults!
    private var tokenStore: TestTokenStore!
    private var configuration: ServerConfigurationStore!
    private var session: URLSession!

    override func setUp() async throws {
        let suite = "HTTPTelemetrySinkTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        tokenStore = TestTokenStore()
        configuration = ServerConfigurationStore(defaults: defaults, tokenStore: tokenStore)
        try await configuration.save(baseURL: "http://localhost:8080", token: "secret-token")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        TestURLProtocol.handler = nil
        session.invalidateAndCancel()
    }

    func testRequestMatchesServerContractAndUsesBearerAuth() async throws {
        let installationID = UUID(uuidString: "7d9aa8d8-8e9f-4f25-a9e2-2bd75148f986")!
        let envelopeID = UUID(uuidString: "b608d8d9-a203-4ba4-860b-601c1509bc85")!
        let activityID = UUID(uuidString: "e4a55567-2aef-41d1-b82f-af1c209919c5")!
        let deviceID = UUID(uuidString: "0afb86af-a5ab-4517-82e4-f8a8ba8aef01")!
        let envelope = TelemetryEnvelope(
            id: envelopeID,
            installationID: installationID,
            localRunID: activityID,
            phoneReceivedAt: Date(timeIntervalSince1970: 1_783_884_121.25),
            garminDeviceIdentifier: deviceID,
            appVersion: "1.0",
            sample: TelemetryTestSupport.sample(sequence: 175, elapsed: 523_000)
        )
        TestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:8080/v1/telemetry/batches")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.timeoutInterval, 12)
            let body = try request.bodyData()
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["installationId"] as? String, installationID.uuidString)
            let values = try XCTUnwrap(json["envelopes"] as? [[String: Any]])
            XCTAssertEqual(values.count, 1)
            XCTAssertEqual(values[0]["envelopeId"] as? String, envelopeID.uuidString)
            XCTAssertEqual(values[0]["activityId"] as? String, activityID.uuidString)
            XCTAssertNil(values[0]["id"])
            XCTAssertNil(values[0]["localRunID"])
            let sample = try XCTUnwrap(values[0]["sample"] as? [String: Any])
            XCTAssertEqual(sample["heartRateBPM"] as? Int, 150)
            XCTAssertEqual(sample["latitudeMicrodegrees"] as? Int, 37_774_920)
            return Self.response(request, status: 200, body: """
                {"acknowledgedEnvelopeIds":["\(envelopeID.uuidString)"],"serverTime":"2026-07-12T18:42:01.410Z"}
                """)
        }

        let sink = HTTPTelemetrySink(configuration: configuration, session: session, requestTimeout: 12)
        let acknowledged = try await sink.submit([envelope])
        XCTAssertEqual(acknowledged, [envelopeID])
    }

    func testPartialAcknowledgementReturnsOnlyExactIDs() async throws {
        let first = TelemetryTestSupport.envelope()
        let second = TelemetryEnvelope(
            id: UUID(), installationID: first.installationID, localRunID: first.localRunID,
            phoneReceivedAt: first.phoneReceivedAt, garminDeviceIdentifier: first.garminDeviceIdentifier,
            appVersion: first.appVersion, sample: first.sample
        )
        TestURLProtocol.handler = { request in
            Self.response(request, status: 200, body: """
                {"acknowledgedEnvelopeIds":["\(first.id.uuidString)"],"serverTime":"2026-07-12T18:42:01Z"}
                """)
        }
        let sink = HTTPTelemetrySink(configuration: configuration, session: session)
        let acknowledged = try await sink.submit([first, second])
        XCTAssertEqual(acknowledged, [first.id])
    }

    func testTransientAndPermanentFailuresAreClassified() async throws {
        let envelope = TelemetryTestSupport.envelope()
        let sink = HTTPTelemetrySink(configuration: configuration, session: session)
        TestURLProtocol.handler = { request in Self.response(request, status: 503, retryAfter: "17") }
        do {
            _ = try await sink.submit([envelope])
            XCTFail("Expected transient failure")
        } catch let error as TelemetrySinkError {
            XCTAssertEqual(error, .transient(retryAfter: 17))
        }

        TestURLProtocol.handler = { request in Self.response(request, status: 401) }
        do {
            _ = try await sink.submit([envelope])
            XCTFail("Expected permanent failure")
        } catch let error as TelemetrySinkError {
            XCTAssertEqual(error, .permanent(reason: "Authentication rejected"))
        }
    }

    func testRejectsUnrequestedAcknowledgementButAllowsUnknownResponseFields() async throws {
        let envelope = TelemetryTestSupport.envelope()
        TestURLProtocol.handler = { request in
            Self.response(request, status: 200, body: """
                {"acknowledgedEnvelopeIds":["\(envelope.id.uuidString)"],"serverTime":"2026-07-12T18:42:01Z","extra":true}
                """)
        }
        let sink = HTTPTelemetrySink(configuration: configuration, session: session)
        let acknowledged = try await sink.submit([envelope])
        XCTAssertEqual(acknowledged, [envelope.id])

        TestURLProtocol.handler = { request in
            Self.response(request, status: 200, body: """
                {"acknowledgedEnvelopeIds":["\(UUID().uuidString)"],"serverTime":"2026-07-12T18:42:01Z"}
                """)
        }
        do {
            _ = try await sink.submit([envelope])
            XCTFail("Expected strict response failure")
        } catch let error as TelemetrySinkError {
            XCTAssertEqual(error, .transient(retryAfter: nil))
        }
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        body: String = "{}",
        retryAfter: String? = nil
    ) -> (HTTPURLResponse, Data) {
        var headers = ["Content-Type": "application/json"]
        headers["Retry-After"] = retryAfter
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        return (response, Data(body.utf8))
    }
}

private final class TestURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try XCTUnwrap(Self.handler)(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private extension URLRequest {
    func bodyData() throws -> Data {
        if let httpBody { return httpBody }
        let stream = try XCTUnwrap(httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            if count < 0 { throw try XCTUnwrap(stream.streamError) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class TestTokenStore: IngestTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    func load() -> String? { lock.withLock { token } }
    func save(_ token: String) { lock.withLock { self.token = token } }
    func delete() { lock.withLock { token = nil } }
}
