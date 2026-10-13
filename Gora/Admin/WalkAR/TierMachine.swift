//
//  TierMachine.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import Foundation

/// Holds the current tier. A worse target applies at once. A better target applies after it
/// holds for `upshiftSettleSeconds`.
nonisolated struct TierMachine: Sendable {
    static let t1FloorConfidence = 0.75
    static let t1StaleMeters = 25.0
    static let t2FloorConfidence = 0.45
    static let cameraDownGraceSeconds = 3.0
    static let t4TriggerMeters = 60.0
    static let upshiftSettleSeconds = 1.5
    static let criticalBatteryFraction = 0.10

    /// One tick of inputs. `time` is in seconds on any monotonic clock.
    struct Input: Sendable {
        let routeConfidence: Double
        /// `nil` when the profile has no hard-fix rung, as on an outdoor walk with no survey.
        let metersSinceHardFix: Double?
        let isTrackingNormal: Bool
        let hasRecentGatedGPS: Bool
        let isCameraBelowMinPitch: Bool
        let power: WalkARPowerState
        let isThermalSerious: Bool
        let batteryFraction: Double
        let time: TimeInterval
    }

    private(set) var tier = GuidanceTier.t3NonAR
    private var cameraDownSince: TimeInterval?
    private var pendingTier: GuidanceTier?
    private var pendingSince: TimeInterval = 0
    private var isBatteryLatched = false

    @discardableResult
    mutating func update(_ input: Input) -> GuidanceTier {
        let target = targetTier(for: input)
        if target >= tier {
            pendingTier = nil
            tier = target
        } else {
            settle(toward: target, at: input.time)
        }
        return tier
    }

    /// The tier the inputs call for, before hysteresis.
    private mutating func targetTier(for input: Input) -> GuidanceTier {
        if input.batteryFraction < Self.criticalBatteryFraction { isBatteryLatched = true }
        var target = confidenceTier(input.routeConfidence)
        if !input.isTrackingNormal { target = max(target, .t2Directional) }
        if let walked = input.metersSinceHardFix {
            if walked > Self.t1StaleMeters { target = max(target, .t2Directional) }
            if walked > Self.t4TriggerMeters, !input.hasRecentGatedGPS { target = .t4Recovery }
        }
        target = max(target, cameraTier(input))
        if isBatteryLatched || input.isThermalSerious || isCritical(input.power) { target = max(target, .t3NonAR) }
        return target
    }

    private func confidenceTier(_ confidence: Double) -> GuidanceTier {
        if confidence >= Self.t1FloorConfidence { return .t1Precise }
        return confidence >= Self.t2FloorConfidence ? .t2Directional : .t3NonAR
    }

    /// T2 while the camera is down inside the grace period, then T3.
    private mutating func cameraTier(_ input: Input) -> GuidanceTier {
        guard input.isCameraBelowMinPitch else {
            cameraDownSince = nil
            return .t1Precise
        }
        let since = cameraDownSince ?? input.time
        cameraDownSince = since
        return input.time - since >= Self.cameraDownGraceSeconds ? .t3NonAR : .t2Directional
    }

    private func isCritical(_ power: WalkARPowerState) -> Bool {
        switch power {
        case .critical: true
        case .full, .reduced: false
        }
    }

    /// Applies a better tier once the same or a better target holds for the settle time.
    private mutating func settle(toward target: GuidanceTier, at time: TimeInterval) {
        if let pending = pendingTier, target <= pending {
            if time - pendingSince >= Self.upshiftSettleSeconds {
                tier = pending
                pendingTier = nil
            }
            return
        }
        pendingTier = target
        pendingSince = time
    }
}
