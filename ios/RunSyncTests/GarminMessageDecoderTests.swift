import XCTest
@testable import RunSync

final class GarminMessageDecoderTests: XCTestCase {
    func testDecodesCompletePayload() throws {
        let sample = try GarminMessageDecoder.decode([
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
        let sample = try GarminMessageDecoder.decode(["v": 1, "q": 1, "st": 0, "future": "ignored"])
        XCTAssertEqual(sample.state, .waiting)
        XCTAssertNil(sample.heartRateBPM)
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
}
