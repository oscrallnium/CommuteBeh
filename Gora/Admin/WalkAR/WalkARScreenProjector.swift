//
//  WalkARScreenProjector.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import CoreGraphics
import simd

/// Finds the screen direction toward a world target.
enum WalkARScreenProjector {
    static let margin: CGFloat = 24

    /// Radians clockwise from screen up. `nil` when the target is in view and inside the window.
    /// `projected` is the `ARView.project` result for `world`.
    static func edgeAngle(toWorld world: SIMD3<Float>, cameraTransform: simd_float4x4,
                          projected: CGPoint?, viewSize: CGSize, isBeyondWindow: Bool) -> Double? {
        let columns = cameraTransform.columns
        let camera = SIMD3(columns.3.x, columns.3.y, columns.3.z)
        let forward = SIMD3(-columns.2.x, -columns.2.y, -columns.2.z)
        let toTarget = world - camera
        guard simd_dot(toTarget, forward) > 0, let projected else {
            return behindAngle(toTarget: toTarget, forward: forward)
        }
        let visible = CGRect(origin: .zero, size: viewSize).insetBy(dx: margin, dy: margin)
        if visible.contains(projected) && !isBeyondWindow { return nil }
        let (dx, dy) = (projected.x - viewSize.width / 2, projected.y - viewSize.height / 2)
        return hypot(dx, dy) < margin ? 0 : Double(atan2(dx, -dy))
    }

    /// A point behind the camera maps to the left or right edge, on the side the passenger turns to.
    private static func behindAngle(toTarget: SIMD3<Float>, forward: SIMD3<Float>) -> Double {
        let right = SIMD3<Float>(-forward.z, 0, forward.x)
        return simd_dot(toTarget, right) >= 0 ? .pi / 2 : -.pi / 2
    }
}
