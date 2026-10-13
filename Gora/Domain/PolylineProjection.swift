//
//  PolylineProjection.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import Foundation
import simd

/// A polyline with cumulative distances. Positions along it are meters from the first vertex.
nonisolated struct PolylinePath: Equatable {

    struct Projection: Equatable {
        let coordinate: Coordinates
        let distanceAlong: Double
        let distanceFromLine: Double
        let segmentIndex: Int
    }

    let coordinates: [Coordinates]
    /// `cumulative[i]` is the length from vertex 0 to vertex `i`.
    let cumulative: [Double]

    var length: Double { cumulative.last ?? 0 }

    init(_ coordinates: [Coordinates]) {
        self.coordinates = coordinates
        var sums: [Double] = coordinates.isEmpty ? [] : [0]
        for i in coordinates.indices.dropFirst() {
            sums.append(sums[i - 1] + GeoARTransform.distance(from: coordinates[i - 1], to: coordinates[i]))
        }
        cumulative = sums
    }

    /// Closest point on the polyline to `point`. `nil` when the polyline has no vertex.
    func project(_ point: Coordinates) -> Projection? {
        guard let first = coordinates.first else { return nil }
        guard coordinates.count > 1 else {
            return Projection(coordinate: first, distanceAlong: 0,
                              distanceFromLine: GeoARTransform.distance(from: point, to: first), segmentIndex: 0)
        }
        var best: Projection?
        for i in 0..<(coordinates.count - 1) {
            let a = coordinates[i]
            let ab = GeoARTransform.enuOffset(of: coordinates[i + 1], from: a)
            let ap = GeoARTransform.enuOffset(of: point, from: a)
            let lengthSquared = simd_length_squared(ab)
            let t = lengthSquared > 0 ? max(0, min(1, simd_dot(ap, ab) / lengthSquared)) : 0
            let foot = ab * t
            let distance = simd_length(ap - foot)
            if best == nil || distance < best!.distanceFromLine {
                let along = cumulative[i] + t * sqrt(lengthSquared)
                let coordinate = GeoARTransform.coordinates(offsetEast: foot.x, north: foot.y, from: a)
                best = Projection(coordinate: coordinate, distanceAlong: along,
                                  distanceFromLine: distance, segmentIndex: i)
            }
        }
        return best
    }

    /// The point `distance` meters along the polyline, clamped to its ends, and the unit
    /// east-north direction of the segment there.
    func sample(at distance: Double) -> (coordinate: Coordinates, direction: SIMD2<Double>)? {
        guard coordinates.count > 1 else { return nil }
        let d = max(0, min(length, distance))
        var low = 0
        var high = coordinates.count - 2
        while low < high {
            let mid = (low + high) / 2
            if cumulative[mid + 1] < d { low = mid + 1 } else { high = mid }
        }
        let i = low
        let a = coordinates[i]
        let ab = GeoARTransform.enuOffset(of: coordinates[i + 1], from: a)
        let segment = cumulative[i + 1] - cumulative[i]
        guard segment > 0 else { return (a, SIMD2(0, 1)) }
        let t = (d - cumulative[i]) / segment
        let point = GeoARTransform.coordinates(offsetEast: ab.x * t, north: ab.y * t, from: a)
        return (point, ab / segment)
    }
}
