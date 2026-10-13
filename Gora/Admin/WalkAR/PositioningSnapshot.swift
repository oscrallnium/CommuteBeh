//
//  PositioningSnapshot.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import Foundation
import simd

/// What the route alignment knows. The view model computes it; the coordinator only reads it.
nonisolated struct PositioningAlignment: Sendable {
    /// Meters along the route from the camera position, or 0 when the alignment is not seeded.
    let progress: Double
    let yawConfidence: Double
    let isSeeded: Bool
    /// True when the compass seed is accurate or the estimated yaw is confident.
    let isHeadingTrusted: Bool
}

/// One 10 Hz reading from the scene view.
nonisolated struct PositioningSample: Sendable {
    let time: TimeInterval
    let cameraPosition: SIMD3<Float>
    /// Radians above the horizon. Negative when the camera looks down.
    let pitchRadians: Double
    let isTrackingNormal: Bool
    let alignment: PositioningAlignment
    let power: WalkARPowerState
    let isThermalSerious: Bool
    /// 0 to 1. The caller passes 1 when the level is unknown.
    let batteryFraction: Double
}

/// Everything the coordinator accepts. The coordinator handles the cases in arrival order.
nonisolated enum PositioningInput: Sendable {
    case surveyReady(time: TimeInterval)
    case relocalized(time: TimeInterval)
    /// A survey sign image is tracked. `imagePosition` is the image origin in the session frame.
    case placedByL2(time: TimeInterval, imagePosition: SIMD3<Float>)
    case sample(PositioningSample)
    /// `routeDistance` is the fix snapped to the route. `now` uses the clock of the samples.
    case fix(GPSFix, routeDistance: Double, now: TimeInterval)
}

/// Why the tier has its value. The HUD shows it as a short label.
nonisolated enum TierReason: Sendable {
    case acquiring
    case aligned
    case lowConfidence
    case trackingLimited
    case cameraLowered
    case noRecentHardFix
    case devicePower

    var label: String {
        switch self {
        case .acquiring: "Acquiring"
        case .aligned: "Aligned"
        case .lowConfidence: "Low confidence"
        case .trackingLimited: "Tracking limited"
        case .cameraLowered: "Camera lowered"
        case .noRecentHardFix: "No recent survey fix"
        case .devicePower: "Device power"
        }
    }
}

/// The one value the coordinator publishes.
nonisolated struct PositioningSnapshot: Sendable {
    let estimate: PositionEstimate
    let tier: GuidanceTier
    let reason: TierReason
    /// `nil` when no survey is loaded.
    let surveyState: SurveyState?
    let showsSurveySigns: Bool
}
