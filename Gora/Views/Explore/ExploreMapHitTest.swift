//
//  ExploreMapHitTest.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/18/26.
//

import CoreGraphics
import CoreLocation

/// Finds the route line nearest to a tap, because `MapPolyline` has no tap callback.
enum ExploreMapHitTest {
    /// Largest distance, in points, between a tap and a line that still selects the line.
    static let tolerance: CGFloat = 22

    /// Returns the layer ID of the nearest line within `tolerance`, or `nil` when none is near.
    static func nearestLayerID(
        to tap: CGPoint,
        in polylines: [ColoredPolyline],
        convert: (CLLocationCoordinate2D) -> CGPoint?
    ) -> String? {
        var best: (layerID: String, distance: CGFloat)?
        for polyline in polylines {
            let points = polyline.coordinates.compactMap(convert)
            for (a, b) in zip(points, points.dropFirst()) {
                let distance = distance(from: tap, toSegment: a, b)
                if distance <= tolerance, distance < (best?.distance ?? .infinity) {
                    best = (polyline.layerID, distance)
                }
            }
        }
        return best?.layerID
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
