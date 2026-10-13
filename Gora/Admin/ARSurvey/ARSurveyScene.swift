//
//  ARSurveyScene.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import ARKit

/// How well the reticle surface is known: none, an estimated plane, or a detected plane.
enum ARPlacementQuality {
    case none, estimated, detected
}

/// The narrow interface that the view model uses to drive the AR scene.
@MainActor
protocol ARSurveyScene: AnyObject {
    func placementTransform() -> simd_float4x4?
    func addAnchor(named name: String, transform: simd_float4x4)
    func removeAnchor(named name: String)
    func showSign(anchorName: String, label: String, kind: ARSignKind, arrowHeadingDegrees: Double?)
    func setArrow(anchorName: String, headingDegrees: Double?)
    func setSelected(anchorName: String?)
    func cameraHeadingDegrees() -> Double?
    func captureWorldMap() async throws -> ARWorldMap
    func captureSignImage() throws -> ARSignImageCapture
    func pause()
}

/// The events that the scene reports to the view model.
@MainActor
protocol ARSurveySceneEvents: AnyObject {
    func sceneDidAddAnchors(named names: [String])
    func sceneDidUpdate(mapping: ARFrame.WorldMappingStatus, tracking: ARCamera.TrackingState)
    func sceneDidChangePlacement(quality: ARPlacementQuality)
    func sceneDidFail(message: String)
    func sceneDidSelectSign(anchorName: String)
    func sceneDidRotate(byDegrees degrees: Double, isFinished: Bool)
}
