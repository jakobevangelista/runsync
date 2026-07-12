import XCTest
@testable import RunSync

final class MockTelemetrySinkTests: XCTestCase {
    func testAcknowledgesExactIDsIdempotently() async throws {
        let sink = MockTelemetrySink(latencyNanoseconds: 0)
        let envelope = TelemetryTestSupport.envelope()

        let firstAcknowledgement = try await sink.submit([envelope])
        let secondAcknowledgement = try await sink.submit([envelope])
        let accepted = await sink.hasAccepted(envelope.id)
        XCTAssertEqual(firstAcknowledgement, [envelope.id])
        XCTAssertEqual(secondAcknowledgement, [envelope.id])
        XCTAssertTrue(accepted)
    }

    func testInjectedFailureDoesNotAccept() async {
        let sink = MockTelemetrySink(latencyNanoseconds: 0)
        let envelope = TelemetryTestSupport.envelope()
        await sink.setFailureInjection(true)

        do {
            _ = try await sink.submit([envelope])
            XCTFail("Expected injected failure")
        } catch is MockSinkFailure {
            let accepted = await sink.hasAccepted(envelope.id)
            XCTAssertFalse(accepted)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
