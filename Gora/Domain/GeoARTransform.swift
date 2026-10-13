//
//  GeoARTransform.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import Foundation
import simd

/// Maps latitude and longitude to the ARKit gravity frame: +Y up, and -Z is the camera
/// forward direction at session start. `yaw` is the angle from true north to AR forward.
nonisolated struct GeoARTransform: Equatable {
    static let metersPerDegreeLat = 111_132.0
    static let metersPerDegreeLng = 111_320.0

    /// The coordinate that the AR origin represents.
    var origin: Coordinates
    /// Radians. An AR bearing equals the true bearing plus `yaw`.
    var yaw: Double

    // MARK: ENU

    /// East and north offset in meters of `point` from `origin`.
    static func enuOffset(of point: Coordinates, from origin: Coordinates) -> SIMD2<Double> {
        let north = (point.lat - origin.lat) * metersPerDegreeLat
        let east = (point.lng - origin.lng) * metersPerDegreeLng * cos(origin.lat * .pi / 180)
        return SIMD2(east, north)
    }

    /// The coordinate at an east and north offset in meters from `origin`.
    static func coordinates(offsetEast east: Double, north: Double, from origin: Coordinates) -> Coordinates {
        let lat = origin.lat + north / metersPerDegreeLat
        let lng = origin.lng + east / (metersPerDegreeLng * cos(origin.lat * .pi / 180))
        return Coordinates(lat: lat, lng: lng)
    }

    /// Meters between two coordinates.
    static func distance(from a: Coordinates, to b: Coordinates) -> Double {
        simd_length(enuOffset(of: b, from: a))
    }

    // MARK: Angles

    /// Radians in (-pi, pi].
    static func normalized(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi }
        if a <= -.pi { a += 2 * .pi }
        return a
    }

    /// True bearing in radians, clockwise from north, of an east and north vector.
    static func bearing(ofENU enu: SIMD2<Double>) -> Double {
        atan2(enu.x, enu.y)
    }

    /// Bearing in the AR frame of a horizontal vector `(x, z)`. AR forward (-Z) is bearing 0.
    static func arBearing(ofHorizontal v: SIMD2<Float>) -> Double {
        atan2(Double(v.x), -Double(v.y))
    }

    /// Yaw that makes the camera forward vector point along the compass heading.
    static func yaw(trueHeadingDegrees: Double, cameraForward: SIMD2<Float>) -> Double {
        normalized(arBearing(ofHorizontal: cameraForward) - trueHeadingDegrees * .pi / 180)
    }

    // MARK: Geo and AR

    /// AR-frame position of a coordinate at height `groundY`.
    func arPosition(of point: Coordinates, groundY: Float = 0) -> SIMD3<Float> {
        let enu = Self.enuOffset(of: point, from: origin)
        let (c, s) = (cos(yaw), sin(yaw))
        return SIMD3(Float(enu.x * c + enu.y * s), groundY, Float(-enu.y * c + enu.x * s))
    }

    /// Coordinate under an AR-frame position. The height is ignored.
    func coordinates(ofAR p: SIMD3<Float>) -> Coordinates {
        let (x, z) = (Double(p.x), Double(p.z))
        let (c, s) = (cos(yaw), sin(yaw))
        return Self.coordinates(offsetEast: x * c + z * s, north: x * s - z * c, from: origin)
    }

    /// The origin that places `geo` at AR position `ar` when the yaw is `yaw`.
    static func origin(placing geo: Coordinates, atAR ar: SIMD3<Float>, yaw: Double) -> Coordinates {
        let at = GeoARTransform(origin: geo, yaw: yaw).coordinates(ofAR: ar)
        let shift = enuOffset(of: at, from: geo)
        return coordinates(offsetEast: -shift.x, north: -shift.y, from: geo)
    }

    // MARK: Route-frame placement

    /// Rotation about +Y and translation for a root entity whose children sit at
    /// `(east, 0, -north)` from `routeAnchor`. Children never move when the transform changes.
    func rootPlacement(routeAnchor: Coordinates, floorY: Float) -> (rotationY: Float, translation: SIMD3<Float>) {
        let o = Self.enuOffset(of: origin, from: routeAnchor)
        let theta = -yaw
        let (c, s) = (cos(theta), sin(theta))
        let local = SIMD2(o.x, -o.y)
        let x = Float(c * local.x + s * local.y)
        let z = Float(-s * local.x + c * local.y)
        return (Float(theta), SIMD3(-x, floorY, -z))
    }

    // MARK: Slew

    /// Moves toward `target` by at most `maxMeters` and `maxRadians`.
    func slewed(toward target: GeoARTransform, maxMeters: Double, maxRadians: Double) -> GeoARTransform {
        let delta = Self.enuOffset(of: target.origin, from: origin)
        let length = simd_length(delta)
        var next = origin
        if length > 0 {
            let step = delta * (min(length, maxMeters) / length)
            next = Self.coordinates(offsetEast: step.x, north: step.y, from: origin)
        }
        let yawDelta = Self.normalized(target.yaw - yaw)
        let nextYaw = Self.normalized(yaw + max(-maxRadians, min(maxRadians, yawDelta)))
        return GeoARTransform(origin: next, yaw: nextYaw)
    }
}
