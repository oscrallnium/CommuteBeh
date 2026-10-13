//
//  WalkARGuidanceScene.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import RealityKit
import SwiftUI
import UIKit
import simd

/// Chevrons, a lead arrow, and a turn callout under one root entity. The root moves to realign.
/// The children move only when the window of path distance they cover changes.
final class WalkARGuidanceScene {
    static let spacingMeters = 3.0
    static let lookAheadMeters = 60.0
    static let leadDistanceMeters = 7.0
    static let leadScale: Float = 3
    static let leadTiltRadians: Float = 0.35
    static let leadLiftMeters: Float = 0.4
    static let fallbackCameraHeightMeters: Float = 1.4
    static let floorTimeConstantSeconds = 0.15
    static let leadTimeConstantSeconds = 0.2
    static let leadSnapMeters = 10.0
    static let defaultFrameStepSeconds = 1.0 / 60
    static let maxFrameStepSeconds = 0.25
    static let crossfadeSeconds = 0.4

    let worldAnchor = AnchorEntity(world: .zero)
    private let root = Entity()
    private let path: PolylinePath
    private let routeAnchor: Coordinates
    private let pool: [Entity]
    private var assignedIndex: [Int]
    private let leadArrow: Entity
    private let callout: WalkARTurnCallout
    private(set) var floorY: Float = 0
    private var hasFloor = false
    private var slotEnabled: [Bool]
    private var isChevronCountReduced = false
    private var smoothedLeadDistance: Double?
    private var fade: Float = 0
    private var lastFrameTime: TimeInterval?
    private var frameStep = WalkARGuidanceScene.defaultFrameStepSeconds

    init(path: PolylinePath, turns: [WalkTurn]) {
        self.path = path
        routeAnchor = path.coordinates.first ?? Coordinates(lat: 0, lng: 0)
        let count = Int(Self.lookAheadMeters / Self.spacingMeters)
        let material = UnlitMaterial(color: UIColor(TransportMode.walk.color))
        let mesh = Self.chevronMesh(scale: 1)
        pool = (0..<count).map { _ in Self.makeChevron(scale: 1, mesh: mesh, material: material) }
        slotEnabled = Array(repeating: true, count: count)
        assignedIndex = Array(repeating: -1, count: count)
        leadArrow = Self.makeLeadArrow(material: material)
        callout = WalkARTurnCallout(path: path, turns: turns, routeAnchor: routeAnchor)
        pool.forEach { root.addChild($0) }
        root.addChild(leadArrow)
        root.addChild(callout.entity)
        worldAnchor.addChild(root)
        root.isEnabled = false
    }

    // MARK: Floor

    /// Sets the floor from a detected plane height, or from the camera height when none exists.
    /// The smoothing and the lead easing use the step to the frame at `time`.
    func updateFloor(planeY: Float?, cameraY: Float, time: TimeInterval) {
        frameStep = lastFrameTime.map { min(Self.maxFrameStepSeconds, max(0, time - $0)) } ?? Self.defaultFrameStepSeconds
        lastFrameTime = time
        let target = planeY ?? (cameraY - Self.fallbackCameraHeightMeters)
        if planeY == nil && hasFloor { return }
        floorY = hasFloor ? floorY + (target - floorY) * Float(1 - exp(-frameStep / Self.floorTimeConstantSeconds)) : target
        hasFloor = true
    }

    /// Forgets the floor height, so the next frames measure it again.
    func resetFloor() {
        hasFloor = false
    }

    /// Shows every second chevron slot only when `isReduced` is false.
    func setReducedChevrons(_ isReduced: Bool) {
        isChevronCountReduced = isReduced
    }

    func hide() {
        fade = 0
        root.isEnabled = false
    }

    // MARK: Update

    /// Moves the root to the transform and refreshes the chevron window around `progress`.
    /// The root fades in or out over `crossfadeSeconds` when `isVisible` changes.
    func update(transform: GeoARTransform, progress: Double, isVisible: Bool,
                cameraPosition: SIMD3<Float>, time: TimeInterval) {
        stepFade(toward: isVisible ? 1 : 0)
        root.isEnabled = fade > 0 && hasFloor
        guard root.isEnabled else { return }
        let placement = transform.rootPlacement(routeAnchor: routeAnchor, floorY: floorY)
        root.position = placement.translation
        root.orientation = simd_quatf(angle: placement.rotationY, axis: SIMD3(0, 1, 0))
        refreshChevrons(progress: progress)
        place(leadArrow, at: smoothedLead(progress: progress), lift: Self.leadLiftMeters)
        callout.update(progress: progress, cameraPosition: cameraPosition, time: time)
    }

    private func stepFade(toward target: Float) {
        guard fade != target else { return }
        let step = Float(frameStep / Self.crossfadeSeconds)
        fade = target > fade ? min(target, fade + step) : max(target, fade - step)
        root.components.set(OpacityComponent(opacity: fade))
    }

    /// Eases the lead distance toward `progress + leadDistanceMeters`. It snaps on a large jump.
    private func smoothedLead(progress: Double) -> Double {
        let target = min(path.length, progress + Self.leadDistanceMeters)
        guard let current = smoothedLeadDistance, abs(target - current) <= Self.leadSnapMeters else {
            smoothedLeadDistance = target
            return target
        }
        let next = current + (target - current) * (1 - exp(-frameStep / Self.leadTimeConstantSeconds))
        smoothedLeadDistance = next
        return next
    }

    private func refreshChevrons(progress: Double) {
        let first = Int(floor(progress / Self.spacingMeters)) + 1
        for k in 0..<pool.count {
            let index = first + k
            let slot = index % pool.count
            let distance = Double(index) * Self.spacingMeters
            let isInside = distance <= path.length && !(isChevronCountReduced && slot % 2 == 1)
            if slotEnabled[slot] != isInside {
                slotEnabled[slot] = isInside
                pool[slot].isEnabled = isInside
            }
            guard isInside, assignedIndex[slot] != index else { continue }
            assignedIndex[slot] = index
            place(pool[slot], at: distance, lift: 0.01)
        }
    }

    private func place(_ entity: Entity, at distance: Double, lift: Float) {
        guard let sample = path.sample(at: distance) else { return }
        let offset = GeoARTransform.enuOffset(of: sample.coordinate, from: routeAnchor)
        entity.position = SIMD3(Float(offset.x), lift, Float(-offset.y))
        entity.orientation = simd_quatf(angle: Self.facingAngle(of: sample.direction), axis: SIMD3(0, 1, 0))
    }

    /// Rotation about +Y that turns local -Z toward an east-north direction.
    static func facingAngle(of direction: SIMD2<Double>) -> Float {
        Float(atan2(-direction.x, direction.y))
    }

    // MARK: Meshes

    /// The arm mesh that `makeChevron` shares across the chevrons of one scale.
    static func chevronMesh(scale: Float) -> MeshResource {
        MeshResource.generateBox(size: SIMD3(0.12 * scale, 0.01, 0.5 * scale))
    }

    /// A flat V that points along local -Z, built from two thin boxes.
    static func makeChevron(scale: Float, mesh: MeshResource, material: UnlitMaterial) -> Entity {
        let armLength: Float = 0.5 * scale
        let chevron = Entity()
        for angle in [Float.pi / 4, -Float.pi / 4] {
            let arm = ModelEntity(mesh: mesh, materials: [material])
            let direction = SIMD3<Float>(sin(angle), 0, cos(angle))
            arm.position = direction * (armLength / 2)
            arm.orientation = simd_quatf(angle: angle, axis: SIMD3(0, 1, 0))
            chevron.addChild(arm)
        }
        return chevron
    }

    /// A large chevron tilted about local X so its surface faces back toward the passenger.
    private static func makeLeadArrow(material: UnlitMaterial) -> Entity {
        let tilt = Entity()
        tilt.orientation = simd_quatf(angle: leadTiltRadians, axis: SIMD3(1, 0, 0))
        tilt.addChild(makeChevron(scale: leadScale, mesh: chevronMesh(scale: leadScale), material: material))
        let holder = Entity()
        holder.addChild(tilt)
        return holder
    }
}
