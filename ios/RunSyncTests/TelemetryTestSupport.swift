import Foundation
@testable import RunSync

enum TelemetryTestSupport {
    static func sample(
        sequence: Int = 1,
        state: ActivityState = .running,
        start: Int? = 1_783_884_160,
        elapsed: Int? = 1_000
    ) -> TelemetrySample {
        TelemetrySample(
            protocolVersion: 1,
            sequence: sequence,
            state: state,
            activityStartEpochSeconds: start,
            elapsedTimeMilliseconds: elapsed,
            distanceDecimeters: 100,
            speedMillimetersPerSecond: 3_000,
            heartRateBPM: 150,
            cadenceRPM: 87,
            latitudeMicrodegrees: 37_774_920,
            longitudeMicrodegrees: -122_419_380,
            gpsQuality: .good,
            altitudeDecimeters: 382,
            totalAscentMeters: 22
        )
    }

    static func envelope(id: UUID = UUID(), runID: UUID = UUID()) -> TelemetryEnvelope {
        TelemetryEnvelope(
            id: id,
            installationID: UUID(),
            localRunID: runID,
            phoneReceivedAt: Date(timeIntervalSince1970: 1_783_884_161),
            garminDeviceIdentifier: UUID(),
            appVersion: "test",
            sample: sample()
        )
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
