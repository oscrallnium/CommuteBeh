//
//  RouteBubblePlacement.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import CoreGraphics

// MARK: - Route Bubble Placement

/// Chooses where the selected route's time bubble sits, in screen points.
/// The bubble sits beside the line, inside the visible area, clear of the markers. Among the
/// valid spots it takes the one closest to the middle of the visible part of the route.
enum RouteBubblePlacement {

    /// Gap in points between the line centre and the nearest bubble edge.
    private static let lineClearance: CGFloat = 14
    /// Gap in points between a marker point and the nearest bubble edge.
    private static let markerClearance: CGFloat = 44
    /// Gap in points between the bubble and the edge of the visible area.
    private static let edgeMargin: CGFloat = 8
    private static let minimumStep: CGFloat = 12
    private static let maximumSamples: CGFloat = 600

    private struct Sample {
        let point: CGPoint
        let tangent: CGVector
        let distance: CGFloat
    }

    /// The bubble centre, or nil when no valid spot exists.
    /// `path` is the route in screen points. `avoid` holds the points the bubble must clear.
    static func center(path: [CGPoint], avoid: [CGPoint], visible: CGRect, size: CGSize) -> CGPoint? {
        let samples = resample(path)
        let onScreen = samples.filter { visible.contains($0.point) }
        guard let first = onScreen.first, let last = onScreen.last else { return nil }
        let middle = (first.distance + last.distance) / 2
        let keepClear = avoid + path.prefix(1)
        let area = visible.insetBy(dx: edgeMargin, dy: edgeMargin)

        var best: (center: CGPoint, score: CGFloat)?
        for sample in onScreen {
            for side: CGFloat in [-1, 1] {
                let normal = CGVector(dx: -sample.tangent.dy * side, dy: sample.tangent.dx * side)
                let reach = abs(normal.dx) * size.width / 2 + abs(normal.dy) * size.height / 2 + lineClearance
                let center = CGPoint(x: sample.point.x + normal.dx * reach, y: sample.point.y + normal.dy * reach)
                let frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                   width: size.width, height: size.height)
                guard area.contains(frame),
                      !keepClear.contains(where: { frame.insetBy(dx: -markerClearance, dy: -markerClearance).contains($0) }),
                      !samples.contains(where: { frame.insetBy(dx: -(lineClearance - 1), dy: -(lineClearance - 1)).contains($0.point) })
                else { continue }
                let score = abs(sample.distance - middle)
                    + 0.01 * hypot(center.x - visible.midX, center.y - visible.midY)
                if best == nil || score < best!.score { best = (center, score) }
            }
        }
        return best?.center
    }

    /// Points spaced along `path` with the direction of the segment each one lies on.
    private static func resample(_ path: [CGPoint]) -> [Sample] {
        let total = zip(path, path.dropFirst()).reduce(CGFloat(0)) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        let step = max(minimumStep, total / maximumSamples)
        var samples: [Sample] = []
        var walked: CGFloat = 0
        var nextAt: CGFloat = 0
        for (a, b) in zip(path, path.dropFirst()) {
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 0 else { continue }
            let tangent = CGVector(dx: (b.x - a.x) / length, dy: (b.y - a.y) / length)
            while nextAt <= walked + length {
                let along = nextAt - walked
                samples.append(Sample(
                    point: CGPoint(x: a.x + tangent.dx * along, y: a.y + tangent.dy * along),
                    tangent: tangent, distance: nextAt))
                nextAt += step
            }
            walked += length
        }
        return samples
    }
}
