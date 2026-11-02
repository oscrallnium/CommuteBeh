//
//  RouteCalloutPlacement.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/14/26.
//

import CoreGraphics

// MARK: - Route Callout Placement

/// Chooses where each route's callout tip sits on its line, in screen points. See `Commute-State.md`.
enum RouteCalloutPlacement {

    struct Route<ID: Hashable> {
        let id: ID
        /// The route in screen points.
        let path: [CGPoint]
        /// The callout frame size, tail included, at the current zoom scale.
        let size: CGSize
        /// The tail room at the current zoom scale.
        let tail: CGFloat
    }

    struct Spot {
        let tip: CGPoint
        let corner: RouteCalloutCorner
    }

    /// Gap in points between any line and the callout body.
    private static let lineClearance: CGFloat = 3
    /// Gap in points between a marker point and the callout frame.
    private static let markerClearance: CGFloat = 36
    /// Gap in points between two callout frames.
    private static let calloutGap: CGFloat = 6
    /// Gap in points between a callout and the edge of the visible area.
    private static let edgeMargin: CGFloat = 8
    /// A sample closer than this to another route's line counts as a shared stretch.
    private static let sharedDistance: CGFloat = 24
    private static let minimumStep: CGFloat = 8
    private static let maximumSamples: CGFloat = 300

    private struct Sample {
        let point: CGPoint
        let distance: CGFloat
    }

    /// One spot per route that has a valid position. The first route is placed first and
    /// takes its pick of the line. Every later route prefers a stretch that no other route shares.
    static func place<ID: Hashable>(routes: [Route<ID>], avoid: [CGPoint], visible: CGRect) -> [ID: Spot] {
        let sampled = routes.map { resample($0.path) }
        let area = visible.insetBy(dx: edgeMargin, dy: edgeMargin)
        var placedFrames: [CGRect] = []
        var spots: [ID: Spot] = [:]

        for (index, route) in routes.enumerated() {
            let ownSamples = sampled[index]
            let otherPoints = sampled.enumerated().filter { $0.offset != index }.flatMap { $0.element.map(\.point) }
            let allPoints = ownSamples.map(\.point) + otherPoints
            let onScreen = ownSamples.filter { visible.contains($0.point) }
            let isUnique: (Sample) -> Bool = { sample in
                index == 0 || !otherPoints.contains { hypot($0.x - sample.point.x, $0.y - sample.point.y) < sharedDistance }
            }
            let preferred = onScreen.filter(isUnique)
            let reference = preferred.isEmpty ? onScreen : preferred
            guard let first = reference.first, let last = reference.last else { continue }
            let middle = (first.distance + last.distance) / 2
            let keepClear = avoid + route.path.prefix(1)

            var best: (spot: Spot, frame: CGRect, score: CGFloat)?
            for sample in onScreen {
                for corner in RouteCalloutCorner.allCases {
                    let frame = corner.frame(tip: sample.point, size: route.size)
                    let body = corner.body(of: frame, tail: route.tail).insetBy(dx: -lineClearance, dy: -lineClearance)
                    guard area.contains(frame),
                          !keepClear.contains(where: { frame.insetBy(dx: -markerClearance, dy: -markerClearance).contains($0) }),
                          !placedFrames.contains(where: { $0.insetBy(dx: -calloutGap, dy: -calloutGap).intersects(frame) }),
                          !allPoints.contains(where: { body.contains($0) })
                    else { continue }
                    let score = abs(sample.distance - middle)
                        + (isUnique(sample) ? 0 : 2000)
                        + 0.01 * hypot(frame.midX - visible.midX, frame.midY - visible.midY)
                    if best == nil || score < best!.score {
                        best = (Spot(tip: sample.point, corner: corner), frame, score)
                    }
                }
            }
            guard let best else { continue }
            spots[route.id] = best.spot
            placedFrames.append(best.frame)
        }
        return spots
    }

    /// Points spaced along `path`, each with its distance from the start of the path.
    private static func resample(_ path: [CGPoint]) -> [Sample] {
        let total = zip(path, path.dropFirst()).reduce(CGFloat(0)) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        let step = max(minimumStep, total / maximumSamples)
        var samples: [Sample] = []
        var walked: CGFloat = 0
        var nextAt: CGFloat = 0
        for (a, b) in zip(path, path.dropFirst()) {
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 0 else { continue }
            while nextAt <= walked + length {
                let along = (nextAt - walked) / length
                samples.append(Sample(
                    point: CGPoint(x: a.x + (b.x - a.x) * along, y: a.y + (b.y - a.y) * along),
                    distance: nextAt))
                nextAt += step
            }
            walked += length
        }
        return samples
    }
}
