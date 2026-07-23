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

    func testRoundTripsWatchDiagnostics() async throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelemetryArchive(rootURL: root)
        let original = TelemetryTestSupport.envelope()
        let sample = TelemetrySample(
            protocolVersion: original.sample.protocolVersion,
            sequence: original.sample.sequence,
            state: original.sample.state,
            activityStartEpochSeconds: original.sample.activityStartEpochSeconds,
            elapsedTimeMilliseconds: original.sample.elapsedTimeMilliseconds,
            distanceDecimeters: original.sample.distanceDecimeters,
            speedMillimetersPerSecond: original.sample.speedMillimetersPerSecond,
            heartRateBPM: original.sample.heartRateBPM,
            cadenceRPM: original.sample.cadenceRPM,
            latitudeMicrodegrees: original.sample.latitudeMicrodegrees,
            longitudeMicrodegrees: original.sample.longitudeMicrodegrees,
            gpsQuality: original.sample.gpsQuality,
            altitudeDecimeters: original.sample.altitudeDecimeters,
            totalAscentMeters: original.sample.totalAscentMeters,
            watchBuildID: "e4764923abcd",
            transportTimeoutCount: 2,
            transportErrorCount: 3,
            transportExceptionCount: 4,
            transportConsecutiveFailures: 5,
            transportLastOutcome: .timeout
        )
        let envelope = TelemetryEnvelope(
            id: original.id,
            installationID: original.installationID,
            localRunID: original.localRunID,
            phoneReceivedAt: original.phoneReceivedAt,
            garminDeviceIdentifier: original.garminDeviceIdentifier,
            appVersion: original.appVersion,
            sample: sample
        )

        try await archive.append(envelope)

        let restoredEnvelopes = try await archive.envelopes(runID: envelope.localRunID)
        let restored = try XCTUnwrap(restoredEnvelopes.first)
        XCTAssertEqual(restored.sample.watchBuildID, "e4764923abcd")
        XCTAssertEqual(restored.sample.transportTimeoutCount, 2)
        XCTAssertEqual(restored.sample.transportLastOutcome, .timeout)
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

final class GarminDiagnosticRecorderTests: XCTestCase {
    func testWritesRecordsInOrdinalOrderAndPreservesCapturedMetadata() throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = DiagnosticTestClock()
        let recorder = GarminDiagnosticRecorder(
            rootURL: root,
            dateProvider: { clock.nextDate() },
            uptimeProvider: { clock.nextUptime() },
            appVersionProvider: { "test-version" }
        )

        DispatchQueue.concurrentPerform(iterations: 25) { index in
            recorder.record(event: "event_\(index)")
        }
        recorder.waitForPendingWrites()

        let records = try Self.readRecords(rootURL: root)
        XCTAssertEqual(records.count, 25)
        XCTAssertEqual(records.map(\.ordinal), Array<UInt64>(1...25))
        XCTAssertEqual(records.first?.occurredAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(records.first?.systemUptimeSeconds, 200)
        XCTAssertEqual(records.first?.iOSAppVersion, "test-version")
    }

    func testQueueOverflowWritesAggregateRecord() throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = GarminDiagnosticRecorder(rootURL: root, maxPending: 1)

        recorder.performWithWriterBlockedForTesting {
            for index in 0..<20 {
                recorder.record(event: "event_\(index)")
            }
        }
        recorder.record(event: "after_overflow")
        recorder.waitForPendingWrites()

        let records = try Self.readRecords(rootURL: root)
        XCTAssertTrue(records.contains { $0.event == "diagnostic_queue_overflow" })
        XCTAssertTrue(records.compactMap { Int($0.details["dropped"] ?? "") }.reduce(0, +) > 0)
    }

    func testRotationRetainsActiveAndPreviousFiles() throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = GarminDiagnosticRecorder(rootURL: root, maxFileSize: 1)

        for index in 0..<5 {
            recorder.record(event: "event_\(index)")
            recorder.waitForPendingWrites()
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("garmin-events.ndjson").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("garmin-events.1.ndjson").path))
        XCTAssertEqual(try Self.readRecords(rootURL: root).count, 2)
    }

    func testLoadRecentSummariesSkipsMalformedAndPartialRecords() throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let valid = GarminDiagnosticRecord(
            schemaVersion: 1,
            ordinal: 1,
            occurredAt: Date(timeIntervalSince1970: 1_000),
            systemUptimeSeconds: 200,
            processSessionID: UUID(),
            iOSAppVersion: "test",
            event: "valid_event",
            details: [:]
        )
        var data = try JSONEncoder().encode(valid)
        data.append(0x0A)
        data.append(Data("{not-json}\n{\"partial\":".utf8))
        try data.write(to: root.appendingPathComponent("garmin-events.ndjson"))

        let recorder = GarminDiagnosticRecorder(rootURL: root)

        XCTAssertEqual(recorder.loadRecentSummaries(limit: 10).count, 1)
        XCTAssertTrue(recorder.loadRecentSummaries(limit: 10)[0].contains("valid_event"))
    }

    func testDeleteAllPreventsQueuedWritesFromRecreatingDiagnostics() throws {
        let root = try TelemetryTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = GarminDiagnosticRecorder(rootURL: root, maxPending: 256)

        for index in 0..<256 {
            recorder.record(event: "event_\(index)")
        }
        recorder.deleteAll()
        recorder.waitForPendingWrites()

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    private static func readRecords(rootURL: URL) throws -> [GarminDiagnosticRecord] {
        let decoder = JSONDecoder()
        let urls = [
            rootURL.appendingPathComponent("garmin-events.1.ndjson"),
            rootURL.appendingPathComponent("garmin-events.ndjson")
        ]
        var records: [GarminDiagnosticRecord] = []
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            for line in data.split(separator: 0x0A) {
                if let record = try? decoder.decode(GarminDiagnosticRecord.self, from: Data(line)) {
                    records.append(record)
                }
            }
        }
        return records
    }
}

private final class DiagnosticTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000)
    private var uptime: TimeInterval = 200

    func nextDate() -> Date {
        lock.withLock {
            defer { date = date.addingTimeInterval(1) }
            return date
        }
    }

    func nextUptime() -> TimeInterval {
        lock.withLock {
            defer { uptime += 1 }
            return uptime
        }
    }
}
