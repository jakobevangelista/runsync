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

        let result = try await ingestor.ingest(TelemetryTestSupport.sample(), from: UUID())
        let envelopes = try await archive.envelopes(runID: result.envelope.localRunID)
        let acknowledgedIDs = try await archive.acknowledgedIDs(runID: result.envelope.localRunID)
        XCTAssertEqual(envelopes.map(\.id), [result.envelope.id])
        XCTAssertEqual(envelopes.map(\.sample), [result.envelope.sample])
        XCTAssertTrue(acknowledgedIDs.isEmpty)
        XCTAssertEqual(result.serverStatus.pendingCount, 1)
        XCTAssertEqual(result.serverStatus.state, "Temporary upload failure")
    }

    func testRecoversArchivedPendingEnvelope() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let sink = MockTelemetrySink(latencyNanoseconds: 0)
        await sink.setFailureInjection(true)
        let firstIngestor = TelemetryIngestor(archive: archive, sink: sink, installationID: UUID())

        _ = try await firstIngestor.ingest(TelemetryTestSupport.sample(), from: UUID())

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

    func testPartialAcknowledgementIsNotResentAfterRelaunch() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let first = TelemetryTestSupport.envelope()
        let second = TelemetryEnvelope(
            id: UUID(), installationID: first.installationID, localRunID: first.localRunID,
            phoneReceivedAt: first.phoneReceivedAt.addingTimeInterval(1),
            garminDeviceIdentifier: first.garminDeviceIdentifier, appVersion: first.appVersion,
            sample: first.sample
        )
        try await archive.append(first)
        try await archive.append(second)

        let partialSink = PartialTelemetrySink(acknowledgedID: first.id)
        let firstIngestor = TelemetryIngestor(
            archive: archive, sink: partialSink, installationID: first.installationID
        )
        _ = try await firstIngestor.recoverPending()

        let recoverySink = RecordingTelemetrySink()
        let recoveredIngestor = TelemetryIngestor(
            archive: archive, sink: recoverySink, installationID: first.installationID
        )
        _ = try await recoveredIngestor.recoverPending()
        let submitted = await recoverySink.submittedIDs
        XCTAssertEqual(submitted, [second.id])
    }

    func testTransientFailureRetriesWithoutAnotherTrigger() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let sink = FailOnceTelemetrySink()
        let ingestor = TelemetryIngestor(
            archive: archive,
            sink: sink,
            installationID: UUID(),
            jitter: { 0 }
        )

        let result = try await ingestor.ingest(TelemetryTestSupport.sample(), from: UUID())
        for _ in 0..<50 {
            if await sink.submissionCount >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let submissionCount = await sink.submissionCount
        XCTAssertEqual(submissionCount, 2)
        let acknowledged = try await archive.acknowledgedIDs(runID: result.envelope.localRunID)
        XCTAssertEqual(acknowledged, [result.envelope.id])
    }
}

private actor PartialTelemetrySink: TelemetrySink {
    let acknowledgedID: UUID
    init(acknowledgedID: UUID) { self.acknowledgedID = acknowledgedID }
    func submit(_ envelopes: [TelemetryEnvelope]) -> [UUID] { [acknowledgedID] }
}

private actor RecordingTelemetrySink: TelemetrySink {
    private(set) var submittedIDs: [UUID] = []
    func submit(_ envelopes: [TelemetryEnvelope]) -> [UUID] {
        submittedIDs.append(contentsOf: envelopes.map(\.id))
        return envelopes.map(\.id)
    }
}

private actor FailOnceTelemetrySink: TelemetrySink {
    private(set) var submissionCount = 0

    func submit(_ envelopes: [TelemetryEnvelope]) throws -> [UUID] {
        submissionCount += 1
        if submissionCount == 1 {
            throw TelemetrySinkError.transient(retryAfter: nil)
        }
        return envelopes.map(\.id)
    }
}
