//
//  GPSConfidenceGate.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import Foundation

/// A GPS fix as plain values. The caller computes `snapResidualMeters` against the route.
nonisolated struct GPSFix: Sendable {
    let coordinate: Coordinates
    /// Horizontal accuracy in meters. A negative value is invalid.
    let accuracy: Double
    let timestamp: TimeInterval
    let snapResidualMeters: Double
}

nonisolated enum GPSRejection: Sendable {
    case invalidAccuracy
    case tooInaccurate
    case stale
    case implausibleSpeed
    case offRoute
}

/// Decides whether a GPS fix may move the estimate.
nonisolated struct GPSConfidenceGate: Sendable {
    static let corridorProgressAccuracyMeters = 10.0
    static let fixMaxAgeSeconds = 5.0
    static let maxWalkingSpeed = 3.0
    static let maxSnapResidualMeters = 15.0

    /// Returns `nil` when the fix passes. `previous` is the last accepted fix.
    func rejection(for fix: GPSFix, previous: GPSFix?, now: TimeInterval) -> GPSRejection? {
        if fix.accuracy < 0 { return .invalidAccuracy }
        if fix.accuracy > Self.corridorProgressAccuracyMeters { return .tooInaccurate }
        if now - fix.timestamp > Self.fixMaxAgeSeconds { return .stale }
        if let previous, impliedSpeed(from: previous, to: fix) > Self.maxWalkingSpeed { return .implausibleSpeed }
        if fix.snapResidualMeters > Self.maxSnapResidualMeters { return .offRoute }
        return nil
    }

    /// Meters per second between two fixes. A non-positive time step gives infinity.
    private func impliedSpeed(from a: GPSFix, to b: GPSFix) -> Double {
        let dt = b.timestamp - a.timestamp
        guard dt > 0 else { return .infinity }
        return GeoARTransform.distance(from: a.coordinate, to: b.coordinate) / dt
    }
}
