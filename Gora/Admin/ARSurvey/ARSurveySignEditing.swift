//
//  ARSurveySignEditing.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import ARKit
import RealityKit

/// Sign selection, arrow updates, and the two-finger rotation gesture of the survey scene.
extension ARSurveySceneView.Coordinator {
    private static let selectedScale: Float = 1.2

    func installRotationGesture(on arView: ARView) {
        let rotation = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        arView.addGestureRecognizer(rotation)
    }

    /// The anchor name of the sign under the point, or `nil` when the point hits no sign.
    func signAnchorName(at point: CGPoint) -> String? {
        guard var entity = arView?.entity(at: point) else { return nil }
        while true {
            if let match = signEntities.first(where: { $0.value === entity }) { return match.key }
            guard let parent = entity.parent else { return nil }
            entity = parent
        }
    }

    @objc private func handleRotation(_ gesture: UIRotationGestureRecognizer) {
        guard selectedAnchorName != nil else { return }
        let degrees = Double(gesture.rotation) * 180 / .pi
        switch gesture.state {
        case .began, .changed: events?.sceneDidRotate(byDegrees: degrees, isFinished: false)
        case .ended, .cancelled: events?.sceneDidRotate(byDegrees: degrees, isFinished: true)
        default: break
        }
    }

    // MARK: ARSurveyScene

    func setSelected(anchorName: String?) {
        if let old = selectedAnchorName, old != anchorName {
            signEntities[old]?.findEntity(named: ARSignEntityFactory.signName)?.scale = .one
        }
        selectedAnchorName = anchorName
        guard let anchorName else { return }
        signEntities[anchorName]?.findEntity(named: ARSignEntityFactory.signName)?.scale =
            SIMD3(repeating: Self.selectedScale)
    }

    func setArrow(anchorName: String, headingDegrees: Double?) {
        guard let sign = signEntities[anchorName]?.findEntity(named: ARSignEntityFactory.signName),
              let anchor = anchors[anchorName] else { return }
        ARSignEntityFactory.applyArrow(
            to: sign, headingDegrees: headingDegrees, anchorRotation: simd_quatf(anchor.transform))
    }

    /// The camera's horizontal forward direction, clockwise from above, 0 = world -Z.
    func cameraHeadingDegrees() -> Double? {
        guard let transform = arView?.session.currentFrame?.camera.transform else { return nil }
        var forward = -transform.columns.2
        if hypot(forward.x, forward.z) < 0.1 { forward = -transform.columns.0 }
        let degrees = Double(atan2(forward.x, -forward.z)) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }
}
