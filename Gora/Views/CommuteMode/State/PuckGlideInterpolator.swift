//
//  PuckGlideInterpolator.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/29/26.
//

import CoreLocation
import Foundation

/// Moves the passenger dot between snapped positions with its own 30 Hz tick loop,
/// because MapKit's `Annotation` re-places its coordinate instantly rather than
/// animating it. See `CommuteMode-State.md`.
@Observable
final class PuckGlideInterpolator {

    /// The coordinate the passenger annotation draws at. Written ~30 times per second
    /// while a glide is in flight; equals the last target once the glide lands.
    private(set) var displayedCoordinate: Coordinates?

    /// Identifies the newest glide. A superseded loop compares its copy and stops, so
    /// back-to-back fixes cannot leave two loops writing against each other.
    private var glideToken = 0
    private var glideTask: Task<Void, Never>?
    /// When the previous target arrived, so a glide's duration matches the real gap
    /// between fixes instead of a fixed length.
    private var lastTargetAt: Date?

    /// Beyond this jump the dot moves instantly. A leg switch or an off-route raw fix
    /// is a correction, not travel, and gliding across it would read as flight.
    static let maxGlideMeters: CLLocationDistance = 120
    /// Bounds for one glide. The lower bound keeps near-simultaneous fixes from
    /// flickering; the upper bound keeps a long GPS gap from stranding the dot in
    /// slow motion after fixes resume.
    static let minDuration: TimeInterval = 0.2
    static let maxDuration: TimeInterval = 12

    /// Call with each new snapped position. Starts a glide from the currently
    /// displayed coordinate to `target`, paced to the time since the previous call.
    func move(to target: Coordinates, now: Date = .now) {
        glideToken += 1
        let token = glideToken
        glideTask?.cancel()

        let elapsed = lastTargetAt.map { now.timeIntervalSince($0) } ?? Self.minDuration
        lastTargetAt = now

        guard let start = displayedCoordinate else {
            displayedCoordinate = target
            return
        }
        let span = CLLocation(latitude: start.lat, longitude: start.lng)
            .distance(from: CLLocation(latitude: target.lat, longitude: target.lng))
        guard span > 0.5, span <= Self.maxGlideMeters else {
            displayedCoordinate = target
            return
        }

        let duration = min(max(elapsed, Self.minDuration), Self.maxDuration)
        glideTask = Task { [weak self] in
            let startedAt = Date()
            while !Task.isCancelled {
                guard let self, self.glideToken == token else { return }
                let fraction = min(1, Date().timeIntervalSince(startedAt) / duration)
                self.displayedCoordinate = Coordinates(
                    lat: start.lat + fraction * (target.lat - start.lat),
                    lng: start.lng + fraction * (target.lng - start.lng))
                if fraction >= 1 { return }
                try? await Task.sleep(for: .seconds(DesignTokens.Motion.headingTickInterval))
            }
        }
    }

    /// Clears all state when Commute Mode starts or ends.
    func reset() {
        glideToken += 1
        glideTask?.cancel()
        glideTask = nil
        displayedCoordinate = nil
        lastTargetAt = nil
    }
}
