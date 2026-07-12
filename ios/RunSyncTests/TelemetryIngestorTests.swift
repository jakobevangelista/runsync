import XCTest
@testable import RunSync

final class TelemetryIngestorTests: XCTestCase {
    func testArchivesBeforeMockFailure() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let sink = MockTelemetrySink(latencyNanoseconds: 0)
        await sink.setFailureInjection(true)
        let ingestor = TelemetryIngestor(archive: archive, sink: sink, installationID: UUID())

        do {
            _ = try await ingestor.ingest(TelemetryTestSupport.sample(), from: UUID())
            XCTFail("Expected injected failure")
        } catch is MockSinkFailure {
            let runDirectories = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            )
            XCTAssertEqual(runDirectories.count, 1)
            let runID = try XCTUnwrap(UUID(uuidString: runDirectories[0].lastPathComponent))
            let envelopes = try await archive.envelopes(runID: runID)
            let acknowledgedIDs = try await archive.acknowledgedIDs(runID: runID)
            XCTAssertEqual(envelopes.count, 1)
            XCTAssertTrue(acknowledgedIDs.isEmpty)
        }
    }

    func testRecoversArchivedPendingEnvelope() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let sink = MockTelemetrySink(latencyNanoseconds: 0)
        await sink.setFailureInjection(true)
        let firstIngestor = TelemetryIngestor(archive: archive, sink: sink, installationID: UUID())

        do {
            _ = try await firstIngestor.ingest(TelemetryTestSupport.sample(), from: UUID())
        } catch is MockSinkFailure {
            // Expected: the sample is durable but not acknowledged.
        }

        await sink.setFailureInjection(false)
        let recoveredIngestor = TelemetryIngestor(archive: archive, sink: sink, installationID: UUID())
        try await recoveredIngestor.recoverPending()

        let runDirectory = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first
        )
        let runID = try XCTUnwrap(UUID(uuidString: runDirectory.lastPathComponent))
        let envelopes = try await archive.envelopes(runID: runID)
        let acknowledgements = try await archive.acknowledgedIDs(runID: runID)
        XCTAssertEqual(acknowledgements, Set(envelopes.map(\.id)))
    }
}
