//
//  RouteGeometry+WalkChunks.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import CoreLocation

extension RouteGeometry {
    /// Grid steps in one walk chunk. A short chunk keeps the dot spacing error at a chunk join small.
    static let walkChunkSteps = 4

    /// The index of the first multiple of `step` metres from the leg start that is at or past
    /// `passenger`. `nil` when the leg has no geometry, `step` is not positive, or the passenger is at the leg end.
    func gridIndexAhead(
        leg legID: RouteLeg.ID, passenger: CLLocationCoordinate2D, step: CLLocationDistance
    ) -> Int? {
        guard step > 0, let coords = polylines[legID], coords.count >= 2,
              let cumulative = legCumulativeDistances[legID], cumulative.count == coords.count,
              let legLength = cumulative.last else { return nil }
        let behind = splitPolyline(coords, at: passenger).behind
        let index = behind.count - 2
        let along = cumulative[index] + CLLocation(latitude: coords[index].latitude, longitude: coords[index].longitude)
            .distance(from: CLLocation(latitude: behind[behind.count - 1].latitude, longitude: behind[behind.count - 1].longitude))
        guard along < legLength else { return nil }
        return Int((along / step).rounded(.up))
    }

    /// Number of chunks that cover the whole leg. Zero when the leg has no geometry.
    func walkChunkCount(leg legID: RouteLeg.ID, step: CLLocationDistance) -> Int {
        guard step > 0, let length = legCumulativeDistances[legID]?.last else { return 0 }
        return Int((length / (step * Double(Self.walkChunkSteps))).rounded(.up))
    }

    /// The part of the leg between two chunk boundaries on the ground grid. The last chunk ends at the leg end.
    func walkChunk(leg legID: RouteLeg.ID, index: Int, step: CLLocationDistance) -> [CLLocationCoordinate2D]? {
        guard step > 0, let coords = polylines[legID], coords.count >= 2,
              let cumulative = legCumulativeDistances[legID], cumulative.count == coords.count,
              let length = cumulative.last else { return nil }
        let span = step * Double(Self.walkChunkSteps)
        let start = Double(index) * span
        let end = min(start + span, length)
        guard start < end,
              let from = cumulative.firstIndex(where: { $0 > start }),
              let to = cumulative.firstIndex(where: { $0 >= end }) else { return nil }
        func point(at distance: Double, segment: Int) -> CLLocationCoordinate2D {
            let a = coords[segment - 1], b = coords[segment]
            let length = cumulative[segment] - cumulative[segment - 1]
            let t = length > 0 ? (distance - cumulative[segment - 1]) / length : 0
            return CLLocationCoordinate2D(
                latitude: a.latitude + t * (b.latitude - a.latitude),
                longitude: a.longitude + t * (b.longitude - a.longitude))
        }
        let inner = from < to ? Array(coords[from..<to]) : []
        return [point(at: start, segment: max(from, 1))] + inner + [point(at: end, segment: max(to, 1))]
    }
}
