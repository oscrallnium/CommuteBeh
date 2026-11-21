//
//  RouteDrawAnimator.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 9/23/26.
//

import UIKit

/// Draws a freshly computed route on from origin to destination. A `CADisplayLink` drives an
/// ease-out curve and reports the route fraction each frame to `onFrame`, which sets
/// `strokeEnd` on the route renderers. See `Commute-State.md`.
@MainActor
final class RouteDrawAnimator: NSObject {

    /// Share of the route length drawn now, 0...1. A renderer created mid-draw starts here.
    private(set) var fraction: Double = 1

    /// Receives the eased fraction on each frame. `CommuteMapCoordinator` sets it.
    var onFrame: ((Double) -> Void)?

    static let duration: TimeInterval = 0.9
    private static let easeOutExponent = 3.0

    /// True while a draw-on runs, between `start()` and the last frame.
    var isDrawing: Bool { displayLink != nil }

    private var displayLink: CADisplayLink?
    private var startedAt: CFTimeInterval = 0

    /// Hides the route until `start()` runs. Call before a search begins, so the new route
    /// is empty when it arrives and nothing shows during the camera glide.
    func prepareForNewRoute() {
        stop()
        publish(0)
    }

    /// Draws the route from empty to full. Call once the camera has finished fitting the
    /// route, so the line draws inside an already-settled frame.
    func start() {
        stop()
        publish(0)
        startedAt = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let progress = min(1, (CACurrentMediaTime() - startedAt) / Self.duration)
        publish(1 - pow(1 - progress, Self.easeOutExponent))
        if progress >= 1 { stop() }
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func publish(_ value: Double) {
        fraction = value
        onFrame?(value)
    }
}
