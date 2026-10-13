//
//  StopInsertionPreviewValidation.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/30/26.
//

// Standalone validation — no GoraTests target exists yet to host a Swift Testing suite
// (see .claude/skills/swift-testing.md). Move each case into a @Test function there
// once that target exists; `StopInsertionPreviewValidation.runAll()` covers the same
// ground in the meantime and can be called from anywhere in the app for a manual check.
// Mirrors the pattern in `TrackSnapperTests.swift`.

import Foundation
import CoreLocation

enum StopInsertionPreviewValidation {

    private static let originLat = 14.5500
    private static let originLng = 121.0000
    private static let metersPerDegreeLat = 111_320.0
    private static var metersPerDegreeLng: Double { metersPerDegreeLat * cos(originLat * .pi / 180) }

    private static func point(east: Double, north: Double) -> Coordinates {
        Coordinates(lat: originLat + north / metersPerDegreeLat,
                    lng: originLng + east / metersPerDegreeLng)
    }

    private static func testStation(id: String, coordinate: Coordinates) -> Station {
        Station(id: id, name: id, shortName: id, line: "TEST_LINE", type: "jeepney",
                coordinates: coordinate, isTerminal: false, isInterchange: false,
                interchangesWith: nil, amenities: [],
                operatingHours: Station.OperatingHours(open: "05:00", close: "22:00"),
                accessPoints: nil, sequence: nil, boarding: nil)
    }

    private static func testEdge(id: String, from: String, to: String, coordinates: [Coordinates]) -> TransitEdge {
        TransitEdge(id: id, from: from, to: to, mode: "jeepney", line: "TEST_LINE",
                    travelTimeMinutes: 2, distanceKm: 1, baseFare: 12, farePerKm: 1,
                    acceptedPayments: ["cash"], isAirConditioned: false, crowdFactor: 0.5,
                    reliability: 0.9, bidirectional: false, direction: nil,
                    polylineCoordinates: coordinates, mkDirectionsTransportType: "automobile",
                    isRoadSnapped: true)
    }

    /// A straight 1000 m chain running due east — no doubling back anywhere. The single
    /// most important fixture: the real-world bug this file exists to catch reproduces
    /// with a tap near any ordinary stop on any route, doubled-back or not.
    private static var straightChain: (stations: [Station], edges: [TransitEdge]) {
        let stations = [
            testStation(id: "TEST_STOP1", coordinate: point(east: 0, north: 0)),
            testStation(id: "TEST_STOP2", coordinate: point(east: 500, north: 0)),
            testStation(id: "TEST_STOP3", coordinate: point(east: 1000, north: 0))
        ]
        let edges = [
            testEdge(id: "TEST_SEG1", from: "TEST_STOP1", to: "TEST_STOP2",
                     coordinates: [point(east: 0, north: 0), point(east: 500, north: 0)]),
            testEdge(id: "TEST_SEG2", from: "TEST_STOP2", to: "TEST_STOP3",
                     coordinates: [point(east: 500, north: 0), point(east: 1000, north: 0)])
        ]
        return (stations, edges)
    }

    /// A loop that goes out east along one carriageway, turns, and comes back west along
    /// a second carriageway `separationMeters` north of the first — the UPLB Kanan /
    /// Lopez Avenue shape. `TEST_SEG1` (outbound) and `TEST_SEG3` (return) run parallel
    /// and opposite.
    /// Segment lookup is vertex-only, mirroring the backend's own `split_point_index`
    /// (see `nearestVertexIndex`'s doc comment) — a tap between two recorded vertices is
    /// only ever as close as the nearer one. A real recorded route has a vertex every few
    /// metres; a bare two-point chord does not, so fixtures need a midpoint wherever a
    /// test taps mid-segment, or the tap simply finds no vertex nearby and resolves to
    /// nothing — which is a fixture bug, not a `resolveTap` one.
    private static func doubledBackChain(separationMeters: Double)
    -> (stations: [Station], edges: [TransitEdge]) {
        let stations = [
            testStation(id: "TEST_STOP1", coordinate: point(east: 0, north: 0)),
            testStation(id: "TEST_STOP2", coordinate: point(east: 1000, north: 0)),
            testStation(id: "TEST_STOP3", coordinate: point(east: 1000, north: separationMeters)),
            testStation(id: "TEST_STOP4", coordinate: point(east: 0, north: separationMeters))
        ]
        let edges = [
            testEdge(id: "TEST_SEG1", from: "TEST_STOP1", to: "TEST_STOP2",     // outbound, heading east
                     coordinates: [point(east: 0, north: 0), point(east: 500, north: 0),
                                   point(east: 1000, north: 0)]),
            testEdge(id: "TEST_SEG2", from: "TEST_STOP2", to: "TEST_STOP3",     // the turn
                     coordinates: [point(east: 1000, north: 0), point(east: 1000, north: separationMeters)]),
            testEdge(id: "TEST_SEG3", from: "TEST_STOP3", to: "TEST_STOP4",     // return, heading west
                     coordinates: [point(east: 1000, north: separationMeters), point(east: 500, north: separationMeters),
                                   point(east: 0, north: separationMeters)])
        ]
        return (stations, edges)
    }

    /// A genuine hairpin: the route reverses direction between two *adjacent* stops,
    /// rather than on a distant return pass. `resolveTap` must offer this as a choice too
    /// — chain adjacency was deliberately not used to suppress it (see the plan's
    /// rejected alternative of gating on `chainIndex` distance).
    private static var hairpinChain: (stations: [Station], edges: [TransitEdge]) {
        let stations = [
            testStation(id: "TEST_STOP1", coordinate: point(east: 0, north: 0)),
            testStation(id: "TEST_STOP2", coordinate: point(east: 500, north: 0)),
            testStation(id: "TEST_STOP3", coordinate: point(east: 20, north: 0))
        ]
        let edges = [
            testEdge(id: "TEST_SEG1", from: "TEST_STOP1", to: "TEST_STOP2",   // heading east
                     coordinates: [point(east: 0, north: 0), point(east: 500, north: 0)]),
            testEdge(id: "TEST_SEG2", from: "TEST_STOP2", to: "TEST_STOP3",   // heading west, back past STOP1
                     coordinates: [point(east: 500, north: 0), point(east: 20, north: 0)])
        ]
        return (stations, edges)
    }

    /// Runs every case and returns the failure messages, empty when all pass.
    static func runAll() -> [String] {
        var failures: [String] = []
        ordinaryStopIsNotAmbiguous(&failures)
        doubledBackRoadOffersAChoice(separationMeters: 12, failures: &failures)
        doubledBackRoadOffersAChoice(separationMeters: 3, failures: &failures)
        hairpinBetweenAdjacentStopsOffersAChoice(&failures)
        farTapResolvesToNil(&failures)
        preferredHeadingPicksTheMatchingSide(&failures)
        return failures
    }

    private static func check(_ condition: Bool, _ message: String, _ failures: inout [String]) {
        if !condition { failures.append(message) }
    }

    /// The regression test for the actual reported bug: a tap near any ordinary stop
    /// makes the two segments meeting there equidistant from the tap, which the old
    /// distance-similarity guard mistook for a doubled-back road. This must resolve with
    /// no alternative — that heading at TEST_STOP2 doesn't turn (0°), it just continues.
    private static func ordinaryStopIsNotAmbiguous(_ failures: inout [String]) {
        let (stations, edges) = straightChain
        let tap = point(east: 500, north: 2).clCoordinate

        let resolution = StopInsertionPreview.resolveTap(at: tap, stations: stations, edges: edges)
        check(resolution != nil, "a tap 2 m from an ordinary stop should resolve", &failures)
        check(resolution?.alternative == nil,
              "a tap near an ordinary mid-chain stop must not offer a direction choice — this is the reported bug", &failures)
        // Either neighbouring segment is a correct resolution here — both splits land at
        // the same physical point — so this only checks it's one of the two, not which.
        check(["TEST_STOP1", "TEST_STOP2"].contains(resolution?.chosen.station.id),
              "should resolve to one of the two segments meeting at the tapped stop", &failures)
    }

    /// The doubled-back case the investigation named: two carriageways of one road,
    /// separated by anywhere from a few metres to a real road's width, running opposite
    /// directions. Both must offer a choice — a fixed distance-difference band (the old
    /// 5 m guard) only ever caught the narrow case, not the realistic one.
    private static func doubledBackRoadOffersAChoice(separationMeters: Double, failures: inout [String]) {
        let (stations, edges) = doubledBackChain(separationMeters: separationMeters)
        let tap = point(east: 500, north: separationMeters / 2).clCoordinate

        let resolution = StopInsertionPreview.resolveTap(at: tap, stations: stations, edges: edges)
        check(resolution != nil, "a tap between two \(separationMeters) m-apart carriageways should resolve, not return nil", &failures)
        check(resolution?.alternative != nil,
              "two opposite-direction segments \(separationMeters) m apart should offer a choice", &failures)

        let ids = Set([resolution?.chosen.station.id, resolution?.alternative?.station.id].compactMap { $0 })
        check(ids == ["TEST_STOP1", "TEST_STOP3"],
              "the choice should be between the outbound and return segment starts, got \(ids)", &failures)
    }

    private static func hairpinBetweenAdjacentStopsOffersAChoice(_ failures: inout [String]) {
        let (stations, edges) = hairpinChain
        let tap = point(east: 480, north: 3).clCoordinate

        let resolution = StopInsertionPreview.resolveTap(at: tap, stations: stations, edges: edges)
        check(resolution?.alternative != nil,
              "a hairpin between adjacent stops must still offer a choice — adjacency is not an exclusion rule", &failures)
    }

    private static func farTapResolvesToNil(_ failures: inout [String]) {
        let (stations, edges) = straightChain
        let tap = point(east: 500, north: 300).clCoordinate

        let resolution = StopInsertionPreview.resolveTap(at: tap, stations: stations, edges: edges)
        check(resolution == nil, "a tap 300 m from the nearest segment should not resolve", &failures)
    }

    /// A later tap — nudging the pin along the carriageway the admin already confirmed —
    /// must not flip back to whichever segment happens to be a hair closer.
    private static func preferredHeadingPicksTheMatchingSide(_ failures: inout [String]) {
        let (stations, edges) = doubledBackChain(separationMeters: 20)
        // 8 m from the outbound (east-heading) segment, 12 m from the return (west-heading)
        // one — nearer to outbound, but the admin already confirmed the return side.
        let tap = point(east: 500, north: 8).clCoordinate
        let returnHeading: CLLocationDirection = 270

        let resolution = StopInsertionPreview.resolveTap(
            at: tap, stations: stations, edges: edges, preferredHeading: returnHeading
        )
        check(resolution?.chosen.station.id == "TEST_STOP3",
              "a preferred heading matching the farther segment should still be chosen over the nearer one", &failures)
    }
}

private extension Coordinates {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}
