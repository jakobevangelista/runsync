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

    func testPreservesSubsecondTimestampForExactEnvelopeReplay() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let original = TelemetryTestSupport.envelope()
        let envelope = TelemetryEnvelope(
            id: original.id,
            installationID: original.installationID,
            localRunID: original.localRunID,
            phoneReceivedAt: Date(timeIntervalSince1970: 1_783_884_161.123_456),
            garminDeviceIdentifier: original.garminDeviceIdentifier,
            appVersion: original.appVersion,
            sample: original.sample
        )

        try await archive.append(envelope)

        let envelopes = try await archive.envelopes(runID: envelope.localRunID)
        let restored = try XCTUnwrap(envelopes.first)
        XCTAssertEqual(restored.phoneReceivedAt.timeIntervalSince1970, envelope.phoneReceivedAt.timeIntervalSince1970, accuracy: 0.000_001)
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

    func testTruncatesPartialTailBeforeNextAppend() async throws {
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
        let fileURL = root
            .appendingPathComponent(first.localRunID.uuidString)
            .appendingPathComponent("samples.ndjson")
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"partial\":".utf8))
        try handle.close()

        try await archive.append(second)

        let restored = try await archive.envelopes(runID: first.localRunID)
        XCTAssertEqual(restored, [first, second])
    }

    func testLegacyMockAcknowledgementDoesNotSuppressServerUpload() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelope = TelemetryTestSupport.envelope()
        try await archive.append(envelope)
        let legacyURL = root
            .appendingPathComponent(envelope.localRunID.uuidString)
            .appendingPathComponent("mock-acks.ndjson")
        try Data("{\"id\":\"\(envelope.id.uuidString)\"}\n".utf8).write(to: legacyURL)

        let acknowledged = try await archive.acknowledgedIDs(runID: envelope.localRunID)
        let pending = try await archive.pendingEnvelopes()
        XCTAssertTrue(acknowledged.isEmpty)
        XCTAssertEqual(pending.map(\.id), [envelope.id])
    }

    func testSkipsCorruptCompleteLinesDuringRecovery() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelope = TelemetryTestSupport.envelope()
        try await archive.append(envelope)
        let directory = root.appendingPathComponent(envelope.localRunID.uuidString)
        let sampleURL = directory.appendingPathComponent("samples.ndjson")
        let sampleHandle = try FileHandle(forWritingTo: sampleURL)
        try sampleHandle.seekToEnd()
        try sampleHandle.write(contentsOf: Data("{not-json}\n".utf8))
        try sampleHandle.close()
        try Data("{not-json}\n".utf8).write(to: directory.appendingPathComponent("server-acks.ndjson"))

        let pending = try await archive.pendingEnvelopes()
        XCTAssertEqual(pending.map(\.id), [envelope.id])
    }

    func testPersistsCurrentSessionAndRunMetadataIndependentlyOfAcknowledgements() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let runID = UUID()
        let deviceID = UUID()
        let session = ActivitySessionState(
            localRunID: runID,
            garminDeviceIdentifier: deviceID,
            phase: .active,
            activityStartEpochSeconds: 123,
            lastElapsedTimeMilliseconds: 1_000,
            lastDistanceDecimeters: 100,
            lastActivityState: .running,
            lastWatchSequence: 1,
            openedAt: Date(timeIntervalSince1970: 100),
            lastPhoneReceivedAt: Date(timeIntervalSince1970: 101),
            lastBoundaryReason: .firstRunning
        )

        try await archive.writeCurrentSession(session)
        try await archive.writeRunMetadata(ActivityRunMetadata(session: session))

        let restoredSession = try await archive.currentSession()
        let restoredMetadata = try await archive.runMetadata(runID: runID)
        XCTAssertEqual(restoredSession, session)
        XCTAssertEqual(restoredMetadata?.localRunID, runID)
    }

    func testDeleteAllRemovesSessionAndRunMetadata() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelope = TelemetryTestSupport.envelope()
        let session = ActivitySessionState(
            localRunID: envelope.localRunID,
            garminDeviceIdentifier: envelope.garminDeviceIdentifier,
            phase: .active,
            activityStartEpochSeconds: envelope.sample.activityStartEpochSeconds,
            lastElapsedTimeMilliseconds: envelope.sample.elapsedTimeMilliseconds,
            lastDistanceDecimeters: envelope.sample.distanceDecimeters,
            lastActivityState: .running,
            lastWatchSequence: envelope.sample.sequence,
            openedAt: envelope.phoneReceivedAt,
            lastPhoneReceivedAt: envelope.phoneReceivedAt,
            lastBoundaryReason: .firstRunning
        )
        try await archive.append(envelope)
        try await archive.writeCurrentSession(session)
        try await archive.writeRunMetadata(ActivityRunMetadata(session: session))

        try await archive.deleteAll()

        let restoredSession = try await archive.currentSession()
        let restoredEnvelopes = try await archive.envelopes(runID: envelope.localRunID)
        XCTAssertNil(restoredSession)
        XCTAssertTrue(restoredEnvelopes.isEmpty)
    }
}
