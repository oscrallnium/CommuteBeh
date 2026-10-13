//
//  ARSurveyReticle.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import ARKit
import RealityKit
import UIKit
import SwiftUI

/// One flat square frame that follows the surface at the screen centre.
/// The frame lies in the hit plane, so on a wall it stands upright.
@MainActor
final class ARSurveyReticle {
    private static let side: Float = 0.12
    private static let bar: Float = 0.008
    private static let raycastInterval: TimeInterval = 1.0 / 15.0
    private static let timeConstant: Float = 0.08

    let anchor = AnchorEntity(world: .zero)
    private let frame = Entity()
    private var bars: [ModelEntity] = []
    private var lastRaycast: TimeInterval = 0
    private var lastFrame: TimeInterval?
    private var displayed: simd_float4x4?
    private(set) var quality: ARPlacementQuality = .none
    /// The newest raycast hit. Sign placement reads this, not the eased frame.
    private(set) var transform: simd_float4x4?

    init() {
        let half = Self.side / 2
        let long = Self.side + Self.bar
        let specs: [(size: SIMD3<Float>, offset: SIMD3<Float>)] = [
            ([long, 0.002, Self.bar], [0, 0.001, half]),
            ([long, 0.002, Self.bar], [0, 0.001, -half]),
            ([Self.bar, 0.002, long], [half, 0.001, 0]),
            ([Self.bar, 0.002, long], [-half, 0.001, 0])
        ]
        for spec in specs {
            let mesh = MeshResource.generateBox(size: spec.size)
            let bar = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: UIColor(Color.jade))])
            bar.position = spec.offset
            frame.addChild(bar)
            bars.append(bar)
        }
        frame.isEnabled = false
        anchor.addChild(frame)
    }

    /// Raycasts from the screen centre at 15 Hz and eases the frame toward the newest hit every frame.
    /// Returns the placement quality after the update.
    func update(frame arFrame: ARFrame, in arView: ARView) -> ARPlacementQuality {
        let now = arFrame.timestamp
        let dt = lastFrame.map { Float(max(now - $0, 0)) } ?? 0
        lastFrame = now
        if now - lastRaycast >= Self.raycastInterval {
            lastRaycast = now
            raycast(in: arView)
        }
        if let transform { ease(toward: transform, dt: dt) }
        return quality
    }

    func hide() {
        frame.isEnabled = false
        transform = nil
        displayed = nil
        lastFrame = nil
        quality = .none
    }

    private func raycast(in arView: ARView) {
        guard let hit = Self.centerHit(in: arView) else {
            hide()
            return
        }
        transform = hit.result.worldTransform
        guard hit.quality != quality else { return }
        quality = hit.quality
        let color: UIColor = hit.quality == .detected ? UIColor(Color.jade) : UIColor(Color.ember)
        for bar in bars { bar.model?.materials = [UnlitMaterial(color: color)] }
    }

    private static func centerHit(in arView: ARView) -> (result: ARRaycastResult, quality: ARPlacementQuality)? {
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        if let result = arView.raycast(from: center, allowing: .existingPlaneGeometry, alignment: .any).first {
            return (result, .detected)
        }
        if let result = arView.raycast(from: center, allowing: .estimatedPlane, alignment: .any).first {
            return (result, .estimated)
        }
        return nil
    }

    // The first frame after a hidden period snaps. Later frames ease with an exponential gain.
    private func ease(toward target: simd_float4x4, dt: Float) {
        guard let current = displayed, frame.isEnabled else {
            displayed = target
            frame.transform = Transform(matrix: target)
            frame.isEnabled = true
            return
        }
        let gain = 1 - exp(-dt / Self.timeConstant)
        let position = simd_mix(Self.position(of: current), Self.position(of: target), SIMD3(repeating: gain))
        let rotation = simd_slerp(Self.rotation(of: current), Self.rotation(of: target), gain)
        var blended = simd_float4x4(rotation)
        blended.columns.3 = SIMD4(position, 1)
        displayed = blended
        frame.transform = Transform(matrix: blended)
    }

    private static func position(of matrix: simd_float4x4) -> SIMD3<Float> {
        SIMD3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
    }

    private static func rotation(of matrix: simd_float4x4) -> simd_quatf {
        simd_quatf(matrix)
    }
}
