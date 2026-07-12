import XCTest
@testable import RunSync

final class TelemetryArchiveTests: XCTestCase {
    func testAppendsAndReadsEnvelopeAndAcknowledgement() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelope = TelemetryTestSupport.envelope()

        try await archive.append(envelope)
        try await archive.appendAcknowledgements([envelope.id], runID: envelope.localRunID)

        let restored = try await archive.envelopes(runID: envelope.localRunID)
        let acknowledged = try await archive.acknowledgedIDs(runID: envelope.localRunID)
        XCTAssertEqual(restored, [envelope])
        XCTAssertEqual(acknowledged, [envelope.id])
    }

    func testIgnoresPartialFinalLine() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelope = TelemetryTestSupport.envelope()
        try await archive.append(envelope)

        let fileURL = root
            .appendingPathComponent(envelope.localRunID.uuidString)
            .appendingPathComponent("samples.ndjson")
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"partial\":".utf8))
        try handle.close()

        let restored = try await archive.envelopes(runID: envelope.localRunID)
        XCTAssertEqual(restored, [envelope])
    }
}
