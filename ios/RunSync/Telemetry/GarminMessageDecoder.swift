import CoreFoundation
import Foundation

enum GarminMessageDecoderError: Error, Equatable {
    case invalidRoot
    case missingField(String)
    case invalidInteger(String)
    case unsupportedVersion(Int)
    case invalidState(Int)
    case invalidCoordinates
    case invalidGPSQuality(Int)
}

enum GarminMessageDecoder {
    static func decode(_ message: Any) throws -> TelemetrySample {
        guard let source = message as? [AnyHashable: Any] else {
            throw GarminMessageDecoderError.invalidRoot
        }

        var values: [String: Any] = [:]
        for (key, value) in source {
            guard let key = key as? String else {
                throw GarminMessageDecoderError.invalidRoot
            }
            values[key] = value
        }

        let version = try requiredInteger("v", from: values)
        guard version == 1 else {
            throw GarminMessageDecoderError.unsupportedVersion(version)
        }

        let sequence = try requiredInteger("q", from: values)
        guard sequence >= 0 else {
            throw GarminMessageDecoderError.invalidInteger("q")
        }

        let stateValue = try requiredInteger("st", from: values)
        guard let state = ActivityState(rawValue: stateValue) else {
            throw GarminMessageDecoderError.invalidState(stateValue)
        }

        let latitude = try optionalInteger("lat", from: values)
        let longitude = try optionalInteger("lon", from: values)
        guard (latitude == nil) == (longitude == nil) else {
            throw GarminMessageDecoderError.invalidCoordinates
        }
        if let latitude, let longitude,
           (!(-90_000_000...90_000_000).contains(latitude) ||
            !(-180_000_000...180_000_000).contains(longitude)) {
            throw GarminMessageDecoderError.invalidCoordinates
        }

        let gpsValue = try optionalInteger("gps", from: values)
        let gpsQuality: GPSQuality?
        if let gpsValue {
            guard let quality = GPSQuality(rawValue: gpsValue) else {
                throw GarminMessageDecoderError.invalidGPSQuality(gpsValue)
            }
            gpsQuality = quality
        } else {
            gpsQuality = nil
        }

        return TelemetrySample(
            protocolVersion: version,
            sequence: sequence,
            state: state,
            activityStartEpochSeconds: try optionalInteger("rt", from: values),
            elapsedTimeMilliseconds: try optionalInteger("tm", from: values),
            distanceDecimeters: try optionalInteger("d", from: values),
            speedMillimetersPerSecond: try optionalInteger("sp", from: values),
            heartRateBPM: try optionalInteger("hr", from: values),
            cadenceRPM: try optionalInteger("cad", from: values),
            latitudeMicrodegrees: latitude,
            longitudeMicrodegrees: longitude,
            gpsQuality: gpsQuality,
            altitudeDecimeters: try optionalInteger("alt", from: values),
            totalAscentMeters: try optionalInteger("asc", from: values)
        )
    }

    static func diagnosticReason(for error: Error) -> String {
        guard let error = error as? GarminMessageDecoderError else {
            return String(reflecting: type(of: error))
        }
        switch error {
        case .invalidRoot:
            return "invalidRoot"
        case let .missingField(key):
            return "missingField(\(key))"
        case let .invalidInteger(key):
            return "invalidInteger(\(key))"
        case .unsupportedVersion:
            return "unsupportedVersion"
        case .invalidState:
            return "invalidState"
        case .invalidCoordinates:
            return "invalidCoordinates"
        case .invalidGPSQuality:
            return "invalidGPSQuality"
        }
    }

    static func diagnosticShape(of message: Any) -> String {
        guard let source = message as? [AnyHashable: Any] else {
            return "root:\(String(reflecting: type(of: message)))"
        }
        return source.map { key, value in
            let keyName = (key as? String) ?? "<non-string-key>"
            return "\(keyName):\(diagnosticType(of: value))"
        }
        .sorted()
        .joined(separator: ",")
    }

    private static func diagnosticType(of value: Any) -> String {
        guard let number = value as? NSNumber else {
            return String(reflecting: type(of: value))
        }
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return "NSNumber(bool)"
        }
        return "NSNumber(objCType=\(String(cString: number.objCType)))"
    }

    private static func requiredInteger(_ key: String, from values: [String: Any]) throws -> Int {
        guard values[key] != nil else {
            throw GarminMessageDecoderError.missingField(key)
        }
        guard let value = try optionalInteger(key, from: values) else {
            throw GarminMessageDecoderError.invalidInteger(key)
        }
        return value
    }

    private static func optionalInteger(_ key: String, from values: [String: Any]) throws -> Int? {
        guard let rawValue = values[key], !(rawValue is NSNull) else {
            return nil
        }
        guard let number = rawValue as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw GarminMessageDecoderError.invalidInteger(key)
        }

        let value = number.doubleValue
        guard value.isFinite,
              value.rounded(.towardZero) == value,
              value >= Double(Int32.min),
              value <= Double(Int32.max) else {
            throw GarminMessageDecoderError.invalidInteger(key)
        }
        return Int(value)
    }
}
