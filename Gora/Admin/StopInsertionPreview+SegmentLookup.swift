//
//  StopInsertionPreview+SegmentLookup.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/7/26.
//

import Foundation
import CoreLocation

// Resolves a tap or a picker selection to the chain segment that an insert splits.

extension StopInsertionPreview {

    // MARK: - Segment lookup

    /// One segment ranked against a tap: the earlier stop of the pair (the reference stop
    /// for a `position: "after"` insert), how close its polyline passes to the tap, and
    /// the direction of travel at the closest point.
    struct SegmentCandidate {
        let station: Station
        /// Position of this segment among the chain's segments, earliest first.
        let chainIndex: Int
        let distanceMeters: CLLocationDistance
        /// Direction of travel at the point on this segment closest to the tap. `nil`
        /// when the segment has fewer than two recorded points to derive one from.
        let headingDegrees: CLLocationDirection?
    }

    /// Every segment ranked by how close its polyline passes to `coordinate`, nearest
    /// first, each carrying the direction of travel at its closest point. The runner-up
    /// matters: on a route that doubles back, the outbound and return segments run
    /// alongside each other, and `resolveTap` uses the heading to tell that case apart
    /// from an ordinary stop, where two segments also sit close together (they share it).
    static func segmentCandidates(
        to coordinate: CLLocationCoordinate2D,
        stations: [Station],
        edges: [TransitEdge]
    ) -> [SegmentCandidate] {
        let ordered = StationChain.ordered(stations)
        guard ordered.count >= 2 else { return [] }
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        var pairs = Array(zip(ordered, ordered.dropFirst()))
        if isClosedLoop(ordered, edges: edges), let last = ordered.last, let first = ordered.first {
            pairs.append((last, first))
        }

        return pairs.enumerated().compactMap { i, pair -> SegmentCandidate? in
            let (station, next) = pair
            guard let match = edge(from: station.id, to: next.id, in: edges) else { return nil }
            let coords = match.coordinates
            guard !coords.isEmpty else { return nil }

            var nearestIndex = 0
            var nearestDistance = CLLocationDistance.greatestFiniteMagnitude
            for (index, point) in coords.enumerated() {
                let distance = target.distance(from: CLLocation(latitude: point.lat, longitude: point.lng))
                if distance < nearestDistance { nearestDistance = distance; nearestIndex = index }
            }

            let heading: CLLocationDirection?
            if coords.count < 2 {
                heading = nil
            } else if nearestIndex < coords.count - 1 {
                heading = bearingDegrees(from: coords[nearestIndex], to: coords[nearestIndex + 1])
            } else {
                heading = bearingDegrees(from: coords[nearestIndex - 1], to: coords[nearestIndex])
            }

            return SegmentCandidate(station: station, chainIndex: i,
                                     distanceMeters: nearestDistance, headingDegrees: heading)
        }
        .sorted { $0.distanceMeters < $1.distanceMeters }
    }

    /// What a tap resolves to: the segment to preview a split of, and — only when a
    /// nearby segment genuinely points the opposite way — the other option, so the admin
    /// chooses between two named stops instead of the app guessing which carriageway of a
    /// doubled-back road they mean.
    struct TapResolution {
        let chosen: SegmentCandidate
        let alternative: SegmentCandidate?
    }

    /// Beyond this, a nearby segment isn't a real alternative for the *same* tap — it's
    /// some other part of the route. Wide enough to span two carriageways of one real
    /// road; narrow enough that an unrelated nearby street isn't offered as a choice.
    static let opposingSegmentRadiusMeters: CLLocationDistance = 40
    /// Two segments must point at least this far apart to read as opposite directions of
    /// travel rather than a turn or an ordinary bend in the road.
    static let opposingHeadingDegrees: Double = 135

    /// Resolves a tap to the segment it should split, honestly reporting when a second,
    /// opposite-direction segment sits close enough that the tap alone can't say which one
    /// is meant. Never returns nil for a tap anywhere near the route — see `place(_:)` in
    /// `AddStopView`, which relied on an earlier version of this silently doing nothing on
    /// an ambiguous tap, and silence is indistinguishable from a broken app.
    ///
    /// `preferredHeading` carries forward a direction the admin already confirmed (by
    /// picking a side, or by hand in the Reference-stop picker), so a later tap — nudging
    /// the pin along the same carriageway — resolves to the same side instead of flipping
    /// to whichever segment happens to be a hair closer.
    static func resolveTap(
        at coordinate: CLLocationCoordinate2D,
        stations: [Station],
        edges: [TransitEdge],
        preferredHeading: CLLocationDirection? = nil
    ) -> TapResolution? {
        let candidates = segmentCandidates(to: coordinate, stations: stations, edges: edges)
        guard let nearest = candidates.first, nearest.distanceMeters <= 150 else { return nil }

        let alternative = candidates.dropFirst().first { candidate in
            guard candidate.distanceMeters <= opposingSegmentRadiusMeters,
                  let nearestHeading = nearest.headingDegrees,
                  let candidateHeading = candidate.headingDegrees else { return false }
            return headingDifference(nearestHeading, candidateHeading) >= opposingHeadingDegrees
        }

        guard let alternative, let preferredHeading,
              let alternativeHeading = alternative.headingDegrees,
              let nearestHeading = nearest.headingDegrees,
              headingDifference(alternativeHeading, preferredHeading)
                  < headingDifference(nearestHeading, preferredHeading)
        else {
            return TapResolution(chosen: nearest, alternative: alternative)
        }
        return TapResolution(chosen: alternative, alternative: nearest)
    }

    /// Smallest angle between two compass bearings, in `0...180`.
    private static func headingDifference(_ a: CLLocationDirection, _ b: CLLocationDirection) -> Double {
        let diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        return diff > 180 ? 360 - diff : diff
    }

    /// True-north bearing from `a` to `b`. Mirrors `DebugTrainSimulator.bearing`'s formula
    /// (kept separate: that one is compiled out of release builds).
    private static func bearingDegrees(from a: Coordinates, to b: Coordinates) -> CLLocationDirection {
        let lat1 = a.lat * .pi / 180, lat2 = b.lat * .pi / 180
        let deltaLng = (b.lng - a.lng) * .pi / 180
        let y = sin(deltaLng) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLng)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// The segment an insert at `position` relative to `referenceStationID` would split,
    /// oriented from → to. Depends only on the chain and the picker selection, not on
    /// where the stop lands, so it can be resolved before a coordinate is chosen — which
    /// is what lets a tap snap to the selected segment rather than to the whole line.
    /// Nil for a head or tail insert, which splits nothing.
    static func segmentToSplit(
        referenceStationID: StationID,
        position: String,
        stations: [Station],
        edges: [TransitEdge]
    ) -> (id: String, coordinates: [Coordinates])? {
        let ordered = StationChain.ordered(stations)
        guard let slot = slot(referenceStationID: referenceStationID, position: position,
                              ordered: ordered, edges: edges),
              let previous = slot.previous, let next = slot.next,
              let match = edge(from: previous.id, to: next.id, in: edges) else { return nil }
        return (match.edge.id, match.coordinates)
    }

    /// Overall direction of travel along the segment starting at `stationID` — the
    /// bearing from its polyline's first point to its last. Used to keep
    /// `AddStopView.resolvedHeading` current when the admin picks a reference stop by
    /// hand, where (unlike `resolveTap`) there is no tapped point to measure a
    /// nearest-vertex heading against.
    static func headingOfSegment(
        startingAt stationID: StationID,
        stations: [Station],
        edges: [TransitEdge]
    ) -> CLLocationDirection? {
        let ordered = StationChain.ordered(stations)
        guard let index = ordered.firstIndex(where: { $0.id == stationID }), index + 1 < ordered.count,
              let match = edge(from: ordered[index].id, to: ordered[index + 1].id, in: edges),
              let first = match.coordinates.first, let last = match.coordinates.last
        else { return nil }
        return bearingDegrees(from: first, to: last)
    }
}
