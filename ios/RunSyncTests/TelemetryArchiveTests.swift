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

    func testSurfacesCorruptCompleteLinesAndContinuesScanning() async throws {
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
        let later = TelemetryEnvelope(
            id: UUID(),
            installationID: envelope.installationID,
            localRunID: envelope.localRunID,
            phoneReceivedAt: envelope.phoneReceivedAt.addingTimeInterval(1),
            garminDeviceIdentifier: envelope.garminDeviceIdentifier,
            appVersion: envelope.appVersion,
            sample: envelope.sample
        )
        try await archive.append(later)

        let scan = try await archive.scanPendingEnvelopes()
        XCTAssertEqual(scan.pendingEnvelopes.map(\.id), [envelope.id, later.id])
        XCTAssertEqual(scan.issues, [
            LocalArchiveIssue(
                runID: envelope.localRunID,
                fileName: "samples.ndjson",
                lineNumber: 2,
                category: .invalidEnvelope
            ),
            LocalArchiveIssue(
                runID: envelope.localRunID,
                fileName: "server-acks.ndjson",
                lineNumber: 1,
                category: .invalidAcknowledgement
            )
        ])
        XCTAssertTrue(try String(contentsOf: sampleURL, encoding: .utf8).contains("{not-json}"))
    }

    func testPendingOrderUsesEnvelopeIDForEqualTimestamps() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let lowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let highID = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        let high = TelemetryTestSupport.envelope(id: highID)
        let low = TelemetryEnvelope(
            id: lowID,
            installationID: high.installationID,
            localRunID: high.localRunID,
            phoneReceivedAt: high.phoneReceivedAt,
            garminDeviceIdentifier: high.garminDeviceIdentifier,
            appVersion: high.appVersion,
            sample: high.sample
        )
        try await archive.append(high)
        try await archive.append(low)

        let pending = try await archive.pendingEnvelopes()
        XCTAssertEqual(pending.map(\.id), [lowID, highID])
    }

    func testQuarantineMetadataSkipsEnvelopeWithoutChangingSourceArchive() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let envelope = TelemetryTestSupport.envelope()
        try await archive.append(envelope)
        let sampleURL = root
            .appendingPathComponent(envelope.localRunID.uuidString)
            .appendingPathComponent("samples.ndjson")
        let original = try Data(contentsOf: sampleURL)

        try await archive.quarantine(TelemetryQuarantineRecord(
            envelopeID: envelope.id,
            runID: envelope.localRunID,
            category: "invalid_envelope",
            serverCode: .invalidEnvelope,
            statusCode: 422,
            quarantinedAt: Date(timeIntervalSince1970: 123),
            appVersion: "1.0"
        ))

        let scan = try await archive.scanPendingEnvelopes()
        let metadataURL = root
            .appendingPathComponent("Quarantine")
            .appendingPathComponent("\(envelope.id.uuidString).json")
        let metadata = try String(contentsOf: metadataURL, encoding: .utf8)
        XCTAssertTrue(scan.pendingEnvelopes.isEmpty)
        XCTAssertEqual(scan.quarantined.map(\.envelopeID), [envelope.id])
        XCTAssertEqual(try Data(contentsOf: sampleURL), original)
        XCTAssertFalse(metadata.contains("latitude"))
        XCTAssertFalse(metadata.contains("longitude"))
        XCTAssertFalse(metadata.contains("token"))
        XCTAssertFalse(metadata.contains("sample"))
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
