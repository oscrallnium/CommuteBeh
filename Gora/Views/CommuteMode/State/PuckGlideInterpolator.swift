//
//  PuckGlideInterpolator.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/29/26.
//

import CoreLocation
import Foundation

/// Moves the passenger dot between snapped positions. The position is a pure function of
/// time, and the camera follow tick samples it, so the dot and the camera share one clock.
/// See `CommuteMode-State.md`.
@Observable
final class PuckGlideInterpolator {

    /// The coordinate the passenger annotation draws at. `advance(to:)` writes it once per
    /// follow tick; it equals the last target once the glide lands.
    private(set) var displayedCoordinate: Coordinates?

    /// One straight-line move from `start` to `target`, paced over `duration` seconds.
    private struct Glide {
        let start: Coordinates
        let target: Coordinates
        let startedAt: Date
        let duration: TimeInterval

        func coordinate(at now: Date) -> Coordinates {
            let fraction = min(1, max(0, now.timeIntervalSince(startedAt) / duration))
            return Coordinates(
                lat: start.lat + fraction * (target.lat - start.lat),
                lng: start.lng + fraction * (target.lng - start.lng))
        }

        func isFinished(at now: Date) -> Bool { now.timeIntervalSince(startedAt) >= duration }
    }

    private var glide: Glide?
    /// When the previous target arrived, so the pace follows the real gap between fixes.
    private var lastTargetAt: Date?
    /// Exponential moving average of the gaps between targets. One glide lasts this long, so
    /// a jittery fix interval does not change the dot's speed from glide to glide.
    private var smoothedGap: TimeInterval?
    /// The newest target, so the dot can jump to it when a suspension starts or ends.
    private var latestTarget: Coordinates?
    /// True while the app is in the background. `move(to:)` then records the target without gliding.
    @ObservationIgnored private(set) var isSuspended = false

    /// Beyond this jump the dot moves instantly. A leg switch or an off-route raw fix
    /// is a correction, not travel, and gliding across it would read as flight.
    static let maxGlideMeters: CLLocationDistance = 120
    /// Bounds for one glide. The lower bound keeps near-simultaneous fixes from
    /// flickering; the upper bound keeps a long GPS gap from stranding the dot in
    /// slow motion after fixes resume.
    static let minDuration: TimeInterval = 0.2
    static let maxDuration: TimeInterval = 12
    /// Weight of the newest gap in `smoothedGap`.
    private static let gapSmoothing: Double = 0.3

    /// Where the dot is at `now`: on the glide while one is in flight, else at the last
    /// displayed position. Has no side effects.
    func coordinate(at now: Date) -> Coordinates? {
        glide?.coordinate(at: now) ?? displayedCoordinate
    }

    /// Publishes the position for `now` as `displayedCoordinate` and returns it. Ends the
    /// glide once it lands. The camera follow tick calls this once per tick.
    @discardableResult
    func advance(to now: Date) -> Coordinates? {
        guard let position = coordinate(at: now) else { return nil }
        if displayedCoordinate != position { displayedCoordinate = position }
        if glide?.isFinished(at: now) == true { glide = nil }
        return position
    }

    /// Call with each new snapped position. Starts a glide from the position at `now` to
    /// `target`, paced to the smoothed gap between fixes.
    func move(to target: Coordinates, now: Date = .now) {
        latestTarget = target
        let gap = lastTargetAt.map { now.timeIntervalSince($0) }
        lastTargetAt = now
        if isSuspended { return }
        if let gap { noteGap(gap) }

        guard let start = coordinate(at: now) else {
            glide = nil
            displayedCoordinate = target
            return
        }
        let span = CLLocation(latitude: start.lat, longitude: start.lng)
            .distance(from: CLLocation(latitude: target.lat, longitude: target.lng))
        guard span > 0.5, span <= Self.maxGlideMeters else {
            glide = nil
            displayedCoordinate = target
            return
        }
        let duration = min(max(smoothedGap ?? Self.minDuration, Self.minDuration), Self.maxDuration)
        glide = Glide(start: start, target: target, startedAt: now, duration: duration)
    }

    private func noteGap(_ gap: TimeInterval) {
        let clamped = min(max(gap, Self.minDuration), Self.maxDuration)
        guard let smoothed = smoothedGap else {
            smoothedGap = clamped
            return
        }
        smoothedGap = smoothed + Self.gapSmoothing * (clamped - smoothed)
    }

    /// Ends the glide and jumps the dot to the newest target. Later targets do not glide.
    func suspend() {
        isSuspended = true
        stopGlide()
    }

    /// Jumps the dot to the newest target and lets later targets glide again.
    func resume() {
        isSuspended = false
        stopGlide()
    }

    private func stopGlide() {
        glide = nil
        if let latestTarget { displayedCoordinate = latestTarget }
    }

    /// Clears all state when Commute Mode starts or ends.
    func reset() {
        glide = nil
        displayedCoordinate = nil
        lastTargetAt = nil
        smoothedGap = nil
        latestTarget = nil
    }
}
