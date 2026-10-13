//
//  RouteDrawAnimator.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 9/23/26.
//

import Foundation

/// Reveals a freshly computed route's polylines progressively from origin to destination.
/// Ticks at the same cadence as `PuckGlideInterpolator` so both animations read as one
/// motion language. See `Commute-State.md`.
@Observable
final class RouteDrawAnimator {

    /// Fraction of the route's total length revealed so far, 0...1. Callers trim each
    /// leg's polyline to this fraction via `RouteGeometry.revealedCoordinates`.
    private(set) var revealedFraction: Double = 1

    /// Identifies the newest draw-on. A superseded loop compares its copy and stops, so
    /// back-to-back routes can't leave two loops writing against each other.
    private var token = 0
    private var task: Task<Void, Never>?

    static let duration: TimeInterval = 0.9

    /// Hides the route until `start()` runs. Call before a search begins, so the first frame
    /// of the new route already draws empty and nothing shows during the camera glide.
    func prepareForNewRoute() {
        token += 1
        task?.cancel()
        task = nil
        revealedFraction = 0
    }

    /// Ticks the draw-on from empty to full. Call once the camera has finished fitting the
    /// route, so the line draws inside an already-settled frame rather than racing it.
    func start() {
        token += 1
        let current = token
        task?.cancel()
        revealedFraction = 0
        task = Task { [weak self] in
            let startedAt = Date()
            while !Task.isCancelled {
                guard let self, self.token == current else { return }
                let fraction = min(1, Date().timeIntervalSince(startedAt) / Self.duration)
                self.revealedFraction = fraction
                if fraction >= 1 { return }
                try? await Task.sleep(for: .seconds(DesignTokens.Motion.headingTickInterval))
            }
        }
    }
}
