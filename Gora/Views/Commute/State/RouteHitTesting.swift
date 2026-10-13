//
//  RouteHitTesting.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import CoreGraphics

// MARK: - Route Hit Testing

/// Finds which route a tap on the map lands on. `MapPolyline` is not selectable, so the
/// map view projects each route to screen points and this type measures the distance.
enum RouteHitTesting {

    /// Farthest a tap may land from a route line, in points, and still select it.
    static let tolerance: CGFloat = 22
    /// Distance difference in points below which two routes tie.
    private static let tieEpsilon: CGFloat = 1

    /// One route's screen-space legs, in route order.
    struct ProjectedRoute {
        let id: RouteOption.ID
        let legs: [[CGPoint]]
    }

    /// The route nearest to `point` within `tolerance`. On a tie the `current` route wins.
    /// Returns nil when no route is within `tolerance`.
    static func nearestRoute(
        to point: CGPoint, in routes: [ProjectedRoute], current: RouteOption.ID?
    ) -> RouteOption.ID? {
        let distances = routes.compactMap { route -> (id: RouteOption.ID, distance: CGFloat)? in
            guard let distance = distance(from: point, to: route.legs), distance <= tolerance else { return nil }
            return (route.id, distance)
        }
        guard let best = distances.map(\.distance).min() else { return nil }
        let tied = distances.filter { $0.distance - best <= tieEpsilon }
        if let current, tied.contains(where: { $0.id == current }) { return current }
        return tied.first?.id
    }

    private static func distance(from point: CGPoint, to legs: [[CGPoint]]) -> CGFloat? {
        var best: CGFloat?
        for leg in legs where leg.count >= 2 {
            for i in 0..<(leg.count - 1) {
                let d = distance(from: point, toSegment: leg[i], leg[i + 1])
                best = min(best ?? d, d)
            }
        }
        return best
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared)) : 0
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
