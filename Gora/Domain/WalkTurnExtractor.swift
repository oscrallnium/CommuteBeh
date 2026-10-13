//
//  WalkTurnExtractor.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import Foundation
import simd

/// One direction change on a walk polyline.
nonisolated struct WalkTurn: Equatable {
    enum Side { case left, right }
    enum Kind { case slight, turn, sharp, uTurn }

    let coordinate: Coordinates
    /// Meters from the start of the polyline.
    let distanceAlong: Double
    /// Degrees. Positive turns right, negative turns left.
    let bearingChange: Double

    var side: Side { bearingChange >= 0 ? .right : .left }
    var kind: Kind? { WalkTurnExtractor.kind(forChange: bearingChange) }
}

/// Derives turns from polyline geometry alone.
nonisolated enum WalkTurnExtractor {
    static let simplifyToleranceMeters = 2.0
    static let turnThresholdDegrees = 35.0
    static let turnMinDegrees = 60.0
    static let sharpThresholdDegrees = 120.0
    static let uTurnThresholdDegrees = 165.0
    static let mergeDistanceMeters = 8.0

    /// Turns in order along the polyline. Empty when the polyline has fewer than 2 coordinates.
    static func turns(in line: [Coordinates]) -> [WalkTurn] {
        guard line.count >= 2 else { return [] }
        let path = PolylinePath(line)
        let kept = simplifiedIndices(of: line)
        guard kept.count >= 3 else { return [] }
        var raw: [WalkTurn] = []
        for k in 1..<(kept.count - 1) {
            let (a, b, c) = (line[kept[k - 1]], line[kept[k]], line[kept[k + 1]])
            let change = bearingChange(from: a, through: b, to: c)
            guard kind(forChange: change) != nil else { continue }
            raw.append(WalkTurn(coordinate: b, distanceAlong: path.cumulative[kept[k]], bearingChange: change))
        }
        return merged(raw)
    }

    /// Classification of a signed change in degrees. `nil` means straight.
    static func kind(forChange change: Double) -> WalkTurn.Kind? {
        let size = abs(change)
        if size < turnThresholdDegrees { return nil }
        if size < turnMinDegrees { return .slight }
        if size < sharpThresholdDegrees { return .turn }
        if size < uTurnThresholdDegrees { return .sharp }
        return .uTurn
    }

    /// Signed change in degrees in (-180, 180]. Positive turns right.
    static func bearingChange(from a: Coordinates, through b: Coordinates, to c: Coordinates) -> Double {
        let incoming = GeoARTransform.bearing(ofENU: GeoARTransform.enuOffset(of: b, from: a))
        let outgoing = GeoARTransform.bearing(ofENU: GeoARTransform.enuOffset(of: c, from: b))
        return GeoARTransform.normalized(outgoing - incoming) * 180 / .pi
    }

    // MARK: Simplify

    /// Indices that survive Ramer-Douglas-Peucker simplification, in order.
    static func simplifiedIndices(of line: [Coordinates], tolerance: Double = simplifyToleranceMeters) -> [Int] {
        guard line.count > 2 else { return Array(line.indices) }
        let origin = line[0]
        let points = line.map { GeoARTransform.enuOffset(of: $0, from: origin) }
        var keep = Set([0, line.count - 1])
        var stack = [(0, line.count - 1)]
        while let (first, last) = stack.popLast() {
            var farthest = -1
            var farthestDistance = tolerance
            for i in (first + 1)..<max(first + 1, last) {
                let d = distance(of: points[i], toSegment: points[first], points[last])
                if d > farthestDistance { (farthest, farthestDistance) = (i, d) }
            }
            if farthest >= 0 {
                keep.insert(farthest)
                stack.append((first, farthest))
                stack.append((farthest, last))
            }
        }
        return keep.sorted()
    }

    private static func distance(of p: SIMD2<Double>, toSegment a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 0 else { return simd_length(p - a) }
        let t = max(0, min(1, simd_dot(p - a, ab) / lengthSquared))
        return simd_length(p - (a + ab * t))
    }

    // MARK: Merge

    /// Joins turns closer than `mergeDistanceMeters` into one turn that sums their changes.
    static func merged(_ turns: [WalkTurn]) -> [WalkTurn] {
        var result: [[WalkTurn]] = []
        for turn in turns {
            if let last = result.last?.last, turn.distanceAlong - last.distanceAlong < mergeDistanceMeters {
                result[result.count - 1].append(turn)
            } else {
                result.append([turn])
            }
        }
        return result.compactMap { group in
            let total = GeoARTransform.normalized(group.reduce(0) { $0 + $1.bearingChange } * .pi / 180) * 180 / .pi
            guard kind(forChange: total) != nil, let anchor = group.max(by: { abs($0.bearingChange) < abs($1.bearingChange) }) else {
                return nil
            }
            let along = group.reduce(0) { $0 + $1.distanceAlong } / Double(group.count)
            return WalkTurn(coordinate: anchor.coordinate, distanceAlong: along, bearingChange: total)
        }
    }
}
