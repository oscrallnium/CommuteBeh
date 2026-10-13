//
//  ContentView+CameraPose.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import SwiftUI
import MapKit
import CoreLocation

/// A complete Commute Mode camera: where it looks, which way it faces, and how it is tilted.
struct CommuteCameraPose {
    var center: CLLocationCoordinate2D
    var heading: Double
    var pitch: Double
    var distance: CLLocationDistance
}

/// What a camera transition does with the camera centre.
enum CameraTransitionKind {
    /// Moves the centre to the follow pose, which keeps the puck in the strip.
    case followPassenger
    /// Keeps the centre where it is and changes heading, pitch, and distance.
    case keepCenter
}

// MARK: - Commute camera pose
// See `Commute.md` for the transition and heading rules.

extension ContentView {

    /// Seconds in which the smoothed route heading closes about 63% of a gap to the raw heading.
    private static let routeHeadingTimeConstant: TimeInterval = 0.6
    /// Metres the puck must move between two ticks before the route heading updates.
    private static let routeHeadingMinMovement: CLLocationDistance = 0.02

    /// The signed shortest turn in degrees from `b` to `a`, within -180 to 180.
    static func headingDifference(_ a: Double, _ b: Double) -> Double {
        (a - b + 540).truncatingRemainder(dividingBy: 360) - 180
    }

    private static func normalizedHeading(_ heading: Double) -> Double {
        let remainder = heading.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }

    private static func smoothstep(_ fraction: Double) -> Double {
        let clamped = min(1, max(0, fraction))
        return clamped * clamped * (3 - 2 * clamped)
    }

    // MARK: Target pose

    /// The pose the follow camera holds in `mode`. `nil` before the puck or the leg has a position.
    func targetPose(_ mode: CommuteCameraMode) -> CommuteCameraPose? {
        guard let anchor = poseAnchorCoordinate else { return nil }
        let heading = mode == .threeD ? (smoothedRouteHeading ?? rawRouteHeading ?? 0) : 0
        return CommuteCameraPose(
            center: positionedInStrip(anchor, fraction: mode.puckFraction),
            heading: heading,
            pitch: mode.pitch,
            distance: mode.distance
        )
    }

    /// The puck position, or the start of the current leg before the engine has a position.
    /// The raw GPS fix never anchors the camera, because it can sit far from the route.
    private var poseAnchorCoordinate: CLLocationCoordinate2D? {
        if puckInterpolator.displayedCoordinate != nil || commuteEngine?.snappedLocation != nil {
            return displayedPuckCoordinate
        }
        guard let engine = commuteEngine, let leg = currentCommuteLeg(for: engine) else { return nil }
        return CLLocationCoordinate2D(latitude: leg.fromStation.coordinates.lat,
                                      longitude: leg.fromStation.coordinates.lng)
    }

    func currentCommuteLeg(for engine: CommuteProgressEngine) -> RouteLeg? {
        guard let result = routeStore.routeResult, result.legs.indices.contains(engine.currentLegIndex)
        else { return nil }
        return result.legs[engine.currentLegIndex]
    }

    // MARK: Route heading

    /// The route direction ahead of the puck on the current leg. Falls back to the bearing
    /// from the leg's first station to its last station when the polyline has no direction.
    private var rawRouteHeading: Double? {
        guard let engine = commuteEngine, let leg = currentCommuteLeg(for: engine) else { return nil }
        let coords = routeGeometry?.polylines[leg.id] ?? []
        if let heading = routeHeading(along: coords, at: displayedPuckCoordinate) { return heading }
        let from = leg.fromStation.coordinates, to = leg.toStation.coordinates
        return bearingDegrees(from: CLLocationCoordinate2D(latitude: from.lat, longitude: from.lng),
                              to: CLLocationCoordinate2D(latitude: to.lat, longitude: to.lng))
    }

    /// Moves `smoothedRouteHeading` one tick toward the raw route heading. Holds the value
    /// while the puck stands still, so the heading stays put during a station dwell.
    func advanceSmoothedRouteHeading() {
        guard let puck = displayedPuckCoordinate, let raw = rawRouteHeading else { return }
        guard let current = smoothedRouteHeading else {
            smoothedRouteHeading = raw
            lastHeadingSample = puck
            return
        }
        if let last = lastHeadingSample {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: puck.latitude, longitude: puck.longitude))
            if moved < Self.routeHeadingMinMovement { return }
        }
        lastHeadingSample = puck
        let blend = 1 - exp(-DesignTokens.Motion.headingTickInterval / Self.routeHeadingTimeConstant)
        smoothedRouteHeading = Self.normalizedHeading(current + Self.headingDifference(raw, current) * blend)
    }

    // MARK: Observed camera

    /// Stores the camera the map shows after a pan or a zoom, so a later transition starts
    /// from it. Our own writes already update the stored camera.
    func recordObservedCamera(_ camera: MapCamera) {
        guard isCommuting, !isFollowingPassenger, !isCameraTransitioning else { return }
        lastCommuteCameraCenter = camera.centerCoordinate
        lastCommuteCameraDistance = camera.distance
        lastCommuteCameraPitch = camera.pitch
        lastCommuteCameraHeading = camera.heading
    }

    private var currentCameraPose: CommuteCameraPose? {
        guard let center = lastCommuteCameraCenter,
              let distance = lastCommuteCameraDistance,
              let pitch = lastCommuteCameraPitch,
              let heading = lastCommuteCameraHeading else { return nil }
        return CommuteCameraPose(center: center, heading: heading, pitch: pitch, distance: distance)
    }

    // MARK: Transition

    /// Glides the camera from the pose on screen to the current mode's pose over
    /// `cameraPoseDuration`. The target is read again every tick, so it follows the moving puck.
    func beginCameraTransition(_ kind: CameraTransitionKind) {
        cameraTransitionToken += 1
        let token = cameraTransitionToken
        guard isCommuting, let start = currentCameraPose else {
            isCameraTransitioning = false
            return
        }
        isCameraTransitioning = true
        #if DEBUG
        print("[CameraDebug] transition START token=\(token) kind=\(kind) mode=\(commuteCameraMode) t=\(Date().timeIntervalSince1970)")
        #endif
        Task {
            let startedAt = Date()
            let duration = DesignTokens.Motion.cameraPoseDuration
            while cameraTransitionToken == token, isCommuting {
                if kind == .followPassenger, !isFollowingPassenger { break }
                let fraction = min(1, Date().timeIntervalSince(startedAt) / duration)
                if var goal = targetPose(commuteCameraMode) {
                    if kind == .keepCenter { goal.center = start.center }
                    writeCamera(Self.pose(from: start, to: goal, progress: Self.smoothstep(fraction)),
                                animation: nil)
                }
                if fraction >= 1 { break }
                try? await Task.sleep(for: .seconds(DesignTokens.Motion.headingTickInterval))
            }
            guard cameraTransitionToken == token else { return }
            #if DEBUG
            print("[CameraDebug] transition END token=\(token) t=\(Date().timeIntervalSince1970)")
            #endif
            isCameraTransitioning = false
        }
    }

    /// Stops a running transition at once and leaves the camera where it is.
    func cancelCameraTransition() {
        cameraTransitionToken += 1
        isCameraTransitioning = false
    }

    private static func pose(from start: CommuteCameraPose, to goal: CommuteCameraPose,
                             progress: Double) -> CommuteCameraPose {
        CommuteCameraPose(
            center: CLLocationCoordinate2D(
                latitude: start.center.latitude + progress * (goal.center.latitude - start.center.latitude),
                longitude: start.center.longitude + progress * (goal.center.longitude - start.center.longitude)),
            heading: normalizedHeading(start.heading + progress * headingDifference(goal.heading, start.heading)),
            pitch: start.pitch + progress * (goal.pitch - start.pitch),
            distance: start.distance + progress * (goal.distance - start.distance)
        )
    }
}
