//
//  ARHeadingEstimator.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import Foundation
import simd

/// Two poses and the two geo positions at the same instants.
nonisolated struct ARDisplacementPair: Equatable {
    var arStart: SIMD3<Float>
    var arEnd: SIMD3<Float>
    var geoStart: Coordinates
    var geoEnd: Coordinates
    /// Horizontal meters walked in the AR frame between the two poses.
    var arPathLength: Double
    var elapsed: TimeInterval
}

/// Estimates the yaw of `GeoARTransform` from walked segments.
nonisolated struct ARHeadingEstimator: Equatable {
    static let minDisplacementMeters = 5.0
    static let maxElapsedSeconds = 20.0
    static let minStraightness = 0.9
    static let newestWeightEarly = 0.5
    static let newestWeightLate = 0.2
    static let earlySampleCount = 8
    static let confidenceSampleCount = 3
    static let confidenceFloor = 0.9

    /// Radians. Starts at the seed and moves with each accepted sample.
    private(set) var yaw: Double
    /// The newest eight accepted yaw samples, in radians.
    private(set) var recent: [Double] = []
    private(set) var acceptedCount = 0

    init(seedYaw: Double) {
        yaw = seedYaw
    }

    /// Resultant length of the recent samples, 0 to 1. 0 until three samples exist.
    var confidence: Double {
        guard recent.count >= Self.confidenceSampleCount else { return 0 }
        return Self.resultantLength(of: recent)
    }

    var isConfident: Bool { confidence >= Self.confidenceFloor }

    /// Adds the pair when it passes every clause. Returns whether it was accepted.
    @discardableResult
    mutating func add(_ pair: ARDisplacementPair) -> Bool {
        guard let sample = Self.yawSample(from: pair) else { return false }
        let weight = acceptedCount < Self.earlySampleCount ? Self.newestWeightEarly : Self.newestWeightLate
        yaw = Self.circularBlend(yaw, sample, newestWeight: weight)
        recent.append(sample)
        if recent.count > Self.earlySampleCount { recent.removeFirst() }
        acceptedCount += 1
        return true
    }

    /// The yaw implied by one pair, or `nil` when a clause fails.
    static func yawSample(from pair: ARDisplacementPair) -> Double? {
        let ar = SIMD2(pair.arEnd.x - pair.arStart.x, pair.arEnd.z - pair.arStart.z)
        let arLength = Double(simd_length(ar))
        guard arLength >= minDisplacementMeters,
              pair.elapsed > 0, pair.elapsed <= maxElapsedSeconds,
              pair.arPathLength > 0, arLength / pair.arPathLength >= minStraightness
        else { return nil }
        let geo = GeoARTransform.enuOffset(of: pair.geoEnd, from: pair.geoStart)
        guard simd_length(geo) >= minDisplacementMeters else { return nil }
        let arBearing = GeoARTransform.arBearing(ofHorizontal: ar)
        return GeoARTransform.normalized(arBearing - GeoARTransform.bearing(ofENU: geo))
    }

    /// Circular mean of two angles in radians, with `newestWeight` on `new`.
    static func circularBlend(_ old: Double, _ new: Double, newestWeight w: Double) -> Double {
        let x = (1 - w) * cos(old) + w * cos(new)
        let y = (1 - w) * sin(old) + w * sin(new)
        return atan2(y, x)
    }

    /// Length of the mean unit vector of the angles. 1 means all equal.
    static func resultantLength(of angles: [Double]) -> Double {
        guard !angles.isEmpty else { return 0 }
        let x = angles.reduce(0) { $0 + cos($1) } / Double(angles.count)
        let y = angles.reduce(0) { $0 + sin($1) } / Double(angles.count)
        return (x * x + y * y).squareRoot()
    }
}
