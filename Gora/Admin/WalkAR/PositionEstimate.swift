//
//  PositionEstimate.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import Foundation

/// The rung that set the current estimate.
nonisolated enum Rung: Sendable {
    case l1WorldMap
    case l2ImageAnchor
    case l3Odometry
    case l4GPS
    case l6RouteSnap
}

/// The best known position along the route. `s` is meters from the first route vertex.
nonisolated struct PositionEstimate: Sendable {
    let s: Double
    /// Degrees clockwise from true north, or `nil` when no heading is known.
    let heading: Double?
    /// 0 to 1.
    let confidence: Double
    let authoritativeRung: Rung
    let time: TimeInterval
}
