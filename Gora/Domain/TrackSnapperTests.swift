//
//  TrackSnapperTests.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/13/26.
//

// Standalone validation — no GoraTests target exists yet to host a Swift Testing suite
// (see .claude/skills/swift-testing.md). Move each case into a @Test function there
// once that target exists; `TrackSnapperValidation.runAll()` covers the same ground
// in the meantime and can be called from anywhere in the app for a manual check.

import Foundation

enum TrackSnapperValidation {

    private static let originLat = 14.5500
    private static let originLng = 121.0000
    private static let metersPerDegreeLat = 111_320.0
    private static var metersPerDegreeLng: Double { metersPerDegreeLat * cos(originLat * .pi / 180) }

    private static func point(east: Double, north: Double) -> Coordinates {
        Coordinates(lat: originLat + north / metersPerDegreeLat,
                    lng: originLng + east / metersPerDegreeLng)
    }

    private static func testEdge(id: String, from: String, to: String, coordinates: [Coordinates]) -> TransitEdge {
        TransitEdge(id: id, from: from, to: to, mode: "train", line: "TEST_LINE",
                    travelTimeMinutes: 2, distanceKm: 1, baseFare: 15, farePerKm: 1,
                    acceptedPayments: ["cash"], isAirConditioned: true, crowdFactor: 0.5,
                    reliability: 0.9, bidirectional: false, direction: "eastbound",
                    polylineCoordinates: coordinates, mkDirectionsTransportType: "transit",
                    isRoadSnapped: false)
    }

    /// A straight 2000 m track running due east from a fixed origin, split into two
    /// edges at the 1000 m mark, so tests also exercise the junction-point drop.
    private static var trackEdges: [TransitEdge] {
        [
            testEdge(id: "E1", from: "A", to: "B", coordinates: [point(east: 0, north: 0), point(east: 1000, north: 0)]),
            testEdge(id: "E2", from: "B", to: "C", coordinates: [point(east: 1000, north: 0), point(east: 2000, north: 0)]),
        ]
    }

    /// Runs every case and returns the failure messages, empty when all pass.
    static func runAll() async -> [String] {
        var failures: [String] = []
        await fixNearTrackSnaps(&failures)
        await fixFarFromTrackDoesNotSnap(&failures)
        await backwardJitterIsRejected(&failures)
        await deadReckonsThroughGapThenReconciles(&failures)
        return failures
    }

    private static func check(_ condition: Bool, _ message: String, _ failures: inout [String]) {
        if !condition { failures.append(message) }
    }

    private static func fixNearTrackSnaps(_ failures: inout [String]) async {
        let snapper = TrackSnapper()
        let raw = point(east: 500, north: 40)

        let result = await snapper.snap(rawCoordinate: raw, currentLineEdges: trackEdges,
                                         lastConfirmed: nil, averageInterstationSpeedMetersPerSecond: 15)

        check(result.isSnapped, "40 m off-track fix should snap", &failures)
        check(abs(result.coordinate.lat - originLat) < 0.0001, "snapped fix should sit back on the track's latitude", &failures)
        check(abs(result.progress.metersFromLineStart - 500) < 5, "snapped progress should read ~500 m", &failures)
    }

    private static func fixFarFromTrackDoesNotSnap(_ failures: inout [String]) async {
        let snapper = TrackSnapper()
        let raw = point(east: 500, north: 200)

        let result = await snapper.snap(rawCoordinate: raw, currentLineEdges: trackEdges,
                                         lastConfirmed: nil, averageInterstationSpeedMetersPerSecond: 15)

        check(!result.isSnapped, "200 m off-track fix should not snap", &failures)
        check(result.coordinate.lat == raw.lat && result.coordinate.lng == raw.lng,
              "un-snapped result should return the raw coordinate unchanged", &failures)
    }

    private static func backwardJitterIsRejected(_ failures: inout [String]) async {
        let snapper = TrackSnapper()
        let now = Date()

        let first = await snapper.snap(rawCoordinate: point(east: 500, north: 0),
                                        currentLineEdges: trackEdges, lastConfirmed: nil,
                                        averageInterstationSpeedMetersPerSecond: 15, now: now)
        check(abs(first.progress.metersFromLineStart - 500) < 5, "first fix should read ~500 m", &failures)

        // 50 m behind the confirmed point — well past the 8 m jitter tolerance.
        let second = await snapper.snap(rawCoordinate: point(east: 450, north: 0),
                                         currentLineEdges: trackEdges, lastConfirmed: first.progress,
                                         averageInterstationSpeedMetersPerSecond: 15, now: now.addingTimeInterval(1))

        check(second.isSnapped, "rejection should still report a snapped (held) position", &failures)
        check(second.progress.metersFromLineStart == first.progress.metersFromLineStart,
              "backward jitter beyond tolerance should be rejected, holding the last confirmed progress", &failures)
        check(second.coordinate.lng == first.coordinate.lng, "rejection should keep the last confirmed coordinate", &failures)
    }

    private static func deadReckonsThroughGapThenReconciles(_ failures: inout [String]) async {
        let snapper = TrackSnapper()
        let t0 = Date()

        let confirmed = await snapper.snap(rawCoordinate: point(east: 500, north: 0),
                                            currentLineEdges: trackEdges, lastConfirmed: nil,
                                            averageInterstationSpeedMetersPerSecond: 15, now: t0)

        // 30 s GPS gap (tunnel) — well past the 5 s timeout.
        let duringGap = await snapper.snap(rawCoordinate: nil, currentLineEdges: trackEdges,
                                            lastConfirmed: confirmed.progress,
                                            averageInterstationSpeedMetersPerSecond: 15,
                                            now: t0.addingTimeInterval(30))
        check(duringGap.isDeadReckoned, "a 30 s gap should trigger dead reckoning", &failures)
        check(abs(duringGap.progress.metersFromLineStart - 950) < 1, "dead reckoning should advance 500 + 30*15 = 950 m", &failures)

        // GPS resumes, disagreeing sharply with the dead-reckoned estimate (1300 vs 950).
        // The dot must not jump straight to the new fix.
        let justResumed = await snapper.snap(rawCoordinate: point(east: 1300, north: 0),
                                              currentLineEdges: trackEdges,
                                              lastConfirmed: duringGap.progress,
                                              averageInterstationSpeedMetersPerSecond: 15,
                                              now: t0.addingTimeInterval(30.5))
        check(justResumed.isDeadReckoned, "a fix that just resumed after a gap should still be blending", &failures)
        check(justResumed.progress.metersFromLineStart < 1300 && justResumed.progress.metersFromLineStart >= 950,
              "a resumed fix should ease toward the raw candidate, not jump to it", &failures)

        // Past the 6 s reconciliation window, fully settled on the resumed fix.
        let settled = await snapper.snap(rawCoordinate: point(east: 1300, north: 0),
                                          currentLineEdges: trackEdges,
                                          lastConfirmed: justResumed.progress,
                                          averageInterstationSpeedMetersPerSecond: 15,
                                          now: t0.addingTimeInterval(36.5))
        check(!settled.isDeadReckoned, "reconciliation should complete after the blend window", &failures)
        check(abs(settled.progress.metersFromLineStart - 1300) < 1, "settled progress should match the resumed fix", &failures)
    }
}
