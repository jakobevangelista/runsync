import XCTest
@testable import RunSync

final class GarminMessageDecoderTests: XCTestCase {
    func testDecodesCompletePayload() throws {
        let decoded = try GarminMessageDecoder.decode([
            "v": NSNumber(value: 1),
            "q": NSNumber(value: 175),
            "st": NSNumber(value: 1),
            "rt": NSNumber(value: 1_783_884_160),
            "tm": NSNumber(value: 523_000),
            "d": NSNumber(value: 184_260),
            "sp": NSNumber(value: 3_710),
            "hr": NSNumber(value: 154),
            "cad": NSNumber(value: 87),
            "lat": NSNumber(value: 37_774_920),
            "lon": NSNumber(value: -122_419_380),
            "gps": NSNumber(value: 4),
            "alt": NSNumber(value: 382),
            "asc": NSNumber(value: 22)
        ] as NSDictionary)

        let sample = decoded.sample
        XCTAssertTrue(decoded.warnings.isEmpty)
        XCTAssertEqual(sample.sequence, 175)
        XCTAssertEqual(sample.state, .running)
        XCTAssertEqual(sample.cadenceRPM, 87)
        XCTAssertEqual(sample.longitudeMicrodegrees, -122_419_380)
        XCTAssertEqual(sample.totalAscentMeters, 22)
    }

    func testRejectsBooleanAsInteger() {
        XCTAssertThrowsError(try GarminMessageDecoder.decode(["v": true, "q": 1, "st": 1])) {
            XCTAssertEqual($0 as? GarminMessageDecoderError, .invalidInteger("v"))
        }
    }

    func testRejectsUnpairedCoordinates() {
        XCTAssertThrowsError(try GarminMessageDecoder.decode(["v": 1, "q": 1, "st": 1, "lat": 20])) {
            XCTAssertEqual($0 as? GarminMessageDecoderError, .invalidCoordinates)
        }
    }

    func testIgnoresUnknownKeysAndAllowsMissingOptionals() throws {
        let sample = try GarminMessageDecoder.decode(["v": 1, "q": 1, "st": 0, "future": "ignored"]).sample
        XCTAssertEqual(sample.state, .waiting)
        XCTAssertNil(sample.heartRateBPM)
    }

    func testDecodesMinimalEndedPayloadWithOptionalStart() throws {
        let withoutStart = try GarminMessageDecoder.decode(["v": 1, "q": 2, "st": 4]).sample
        let withStart = try GarminMessageDecoder.decode(["v": 1, "q": 3, "st": 4, "rt": 123]).sample
        XCTAssertEqual(withoutStart.state, .ended)
        XCTAssertNil(withoutStart.activityStartEpochSeconds)
        XCTAssertEqual(withStart.activityStartEpochSeconds, 123)
    }

    func testDecodesWatchDiagnostics() throws {
        let decoded = try GarminMessageDecoder.decode([
            "v": 1,
            "q": 7,
            "st": 1,
            "wb": "e4764923abcd-dirty",
            "wt": 2,
            "we": 3,
            "wx": 4,
            "wf": 5,
            "wo": 3
        ])
        XCTAssertTrue(decoded.warnings.isEmpty)
        XCTAssertEqual(decoded.sample.watchBuildID, "e4764923abcd-dirty")
        XCTAssertEqual(decoded.sample.transportTimeoutCount, 2)
        XCTAssertEqual(decoded.sample.transportErrorCount, 3)
        XCTAssertEqual(decoded.sample.transportExceptionCount, 4)
        XCTAssertEqual(decoded.sample.transportConsecutiveFailures, 5)
        XCTAssertEqual(decoded.sample.transportLastOutcome, .timeout)
    }

    func testInvalidWatchDiagnosticsWarnWithoutRejectingCoreSample() throws {
        let decoded = try GarminMessageDecoder.decode([
            "v": 1,
            "q": 7,
            "st": 1,
            "wb": "bad value",
            "wt": -1,
            "we": "bad",
            "wo": 9
        ])
        XCTAssertEqual(decoded.sample.sequence, 7)
        XCTAssertNil(decoded.sample.watchBuildID)
        XCTAssertNil(decoded.sample.transportTimeoutCount)
        XCTAssertNil(decoded.sample.transportErrorCount)
        XCTAssertNil(decoded.sample.transportLastOutcome)
        XCTAssertEqual(Set(decoded.warnings), [
            .invalidWatchDiagnostic("wb"),
            .invalidWatchDiagnostic("wt"),
            .invalidWatchDiagnostic("we"),
            .invalidWatchDiagnostic("wo")
        ])
    }

    func testDiagnosticIncludesFieldTypesButNotValues() {
        let message: NSDictionary = [
            "v": NSNumber(value: 1),
            "q": NSNumber(value: 511),
            "st": NSNumber(value: 1),
            "hr": "unexpected-heart-rate"
        ]

        let shape = GarminMessageDecoder.diagnosticShape(of: message)
        XCTAssertTrue(shape.contains("hr:"))
        XCTAssertTrue(shape.contains("String"))
        XCTAssertTrue(shape.contains("q:NSNumber(objCType="))
        XCTAssertFalse(shape.contains("511"))
        XCTAssertFalse(shape.contains("unexpected-heart-rate"))
        XCTAssertEqual(
            GarminMessageDecoder.diagnosticReason(for: GarminMessageDecoderError.invalidInteger("hr")),
            "invalidInteger(hr)"
        )
        XCTAssertEqual(
            GarminMessageDecoder.diagnosticReason(for: GarminMessageDecoderError.invalidGPSQuality(99)),
            "invalidGPSQuality"
        )
    }

    func testDiagnosticReportsInvalidRootTypeWithoutDescription() {
        let shape = GarminMessageDecoder.diagnosticShape(of: ["private-value"])
        XCTAssertTrue(shape.hasPrefix("root:"))
        XCTAssertFalse(shape.contains("private-value"))
    }

    func testWatchReceiptFreshnessThresholds() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(
            WatchReceiptFreshness.evaluate(captureEnabled: false, lastReceiptAt: now, now: now),
            .captureDisabled
        )
        XCTAssertEqual(
            WatchReceiptFreshness.evaluate(captureEnabled: true, lastReceiptAt: nil, now: now),
            .never
        )
        XCTAssertEqual(
            WatchReceiptFreshness.evaluate(captureEnabled: true, lastReceiptAt: now.addingTimeInterval(-10), now: now),
            .current(age: 10)
        )
        if case .delayed(let age) = WatchReceiptFreshness.evaluate(
            captureEnabled: true,
            lastReceiptAt: now.addingTimeInterval(-10.001),
            now: now
        ) {
            XCTAssertEqual(age, 10.001, accuracy: 0.001)
        } else {
            XCTFail("Expected delayed freshness")
        }
        XCTAssertEqual(
            WatchReceiptFreshness.evaluate(captureEnabled: true, lastReceiptAt: now.addingTimeInterval(-30), now: now),
            .delayed(age: 30)
        )
        if case .unavailable(let age) = WatchReceiptFreshness.evaluate(
            captureEnabled: true,
            lastReceiptAt: now.addingTimeInterval(-30.001),
            now: now
        ) {
            XCTAssertEqual(age, 30.001, accuracy: 0.001)
        } else {
            XCTFail("Expected unavailable freshness")
        }
        XCTAssertEqual(
            WatchReceiptFreshness.evaluate(captureEnabled: true, lastReceiptAt: now.addingTimeInterval(1), now: now),
            .current(age: 0)
        )
    }
}
