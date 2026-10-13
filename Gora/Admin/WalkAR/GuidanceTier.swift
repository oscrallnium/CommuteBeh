//
//  GuidanceTier.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import Foundation

/// What the passenger sees. A tier is never a claim about the sensors. Crowds and bad light
/// lower T1 to T2 and do not stop the feature.
nonisolated enum GuidanceTier: Int, Comparable, Sendable {
    case t1Precise
    case t2Directional
    case t3NonAR
    case t4Recovery

    /// A higher tier gives less guidance.
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var showsWorldLockedRoute: Bool { self == .t1Precise }

    var showsScreenChevron: Bool { self == .t2Directional || self == .t3NonAR }

    /// T3 hides the camera content, because the passenger is not looking at the screen.
    var showsCameraContent: Bool { self != .t3NonAR }

    var showsDistance: Bool { self == .t1Precise || self == .t2Directional }

    /// T2 shows survey signs only while an L1 or a fresh L2 fix holds.
    func showsSurveySigns(hardFixHolds: Bool) -> Bool {
        switch self {
        case .t1Precise: true
        case .t2Directional: hardFixHolds
        case .t3NonAR, .t4Recovery: false
        }
    }
}
