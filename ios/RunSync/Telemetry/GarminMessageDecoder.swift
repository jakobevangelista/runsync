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
