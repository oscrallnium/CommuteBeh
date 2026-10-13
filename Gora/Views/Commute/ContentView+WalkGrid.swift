//
//  ContentView+WalkGrid.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/4/26.
//

import SwiftUI
import MapKit

extension ContentView {
    /// Minimum seconds between two measurements of `walkGridStep` in the follow loop.
    private static let walkGridStepInterval: TimeInterval = 1
    /// Relative change in the measured step that replaces `walkGridStep`.
    private static let walkGridStepTolerance = 0.03

    /// Measures the ground distance of one walking dot pitch at the puck, at the current zoom.
    func refreshWalkGridStep(now: Date) {
        walkGridStepUpdatedAt = now
        guard let proxy = mapProxy, let puck = displayedPuckCoordinate,
              let origin = proxy.convert(puck, to: .local),
              let offset = proxy.convert(CGPoint(x: origin.x + RouteLine.walkPitch, y: origin.y), from: .local)
        else { return }
        let step = CLLocation(latitude: puck.latitude, longitude: puck.longitude)
            .distance(from: CLLocation(latitude: offset.latitude, longitude: offset.longitude))
        guard step.isFinite, step > 0 else { return }
        if let current = walkGridStep, abs(step - current) <= current * Self.walkGridStepTolerance { return }
        walkGridStep = step
    }

    /// `refreshWalkGridStep` at most once per `walkGridStepInterval`.
    func refreshWalkGridStepIfStale(now: Date) {
        if let last = walkGridStepUpdatedAt, now.timeIntervalSince(last) < Self.walkGridStepInterval { return }
        refreshWalkGridStep(now: now)
    }
}
