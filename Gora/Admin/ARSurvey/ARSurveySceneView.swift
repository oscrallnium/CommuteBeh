//
//  ARSurveySceneView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import SwiftUI
import ARKit
import RealityKit

/// Hosts the RealityKit `ARView` and runs the session with the view model's configuration.
struct ARSurveySceneView: UIViewRepresentable {
    let vm: ARSurveyViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(events: vm, onTap: { [vm] in vm.handleTap() })
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        context.coordinator.attach(to: arView)
        vm.scene = context.coordinator
        arView.session.run(vm.makeConfiguration(), options: vm.runOptions)
        vm.sessionDidStart()
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.configurePlacement(
            enabled: vm.isSceneInteractive && !vm.isFramingSignImage, frozen: vm.pendingSign != nil)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.tearDown()
    }
}

// MARK: - Coordinator

extension ARSurveySceneView {
    /// ARKit calls the delegate on the main queue because `delegateQueue` is nil.
    /// The `@preconcurrency` conformance lets the MainActor class adopt the delegate and
    /// checks the queue at run time.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency ARSessionDelegate, ARSurveyScene {
        weak var events: ARSurveySceneEvents?
        weak var arView: ARView?
        var anchors: [String: ARAnchor] = [:]
        var signEntities: [String: AnchorEntity] = [:]
        var selectedAnchorName: String?
        private var lastMapping: ARFrame.WorldMappingStatus?
        private var lastTracking: ARCamera.TrackingState?

        private let onTap: () -> Void
        private let reticle = ARSurveyReticle()
        private var placementEnabled = false
        private var placementFrozen = false
        private var lastQuality: ARPlacementQuality = .none

        init(events: ARSurveySceneEvents, onTap: @escaping () -> Void) {
            self.events = events
            self.onTap = onTap
        }

        func attach(to arView: ARView) {
            self.arView = arView
            arView.scene.addAnchor(reticle.anchor)
            arView.session.delegate = self
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            arView.addGestureRecognizer(tap)
            installRotationGesture(on: arView)
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let arView, let name = signAnchorName(at: gesture.location(in: arView)) else { return onTap() }
            events?.sceneDidSelectSign(anchorName: name)
        }

        func tearDown() {
            arView?.session.pause()
            arView?.session.delegate = nil
            arView?.scene.anchors.removeAll()
            signEntities.removeAll()
            anchors.removeAll()
        }

        // MARK: ARSurveyScene

        func placementTransform() -> simd_float4x4? {
            placementEnabled ? reticle.transform : nil
        }

        func configurePlacement(enabled: Bool, frozen: Bool) {
            placementFrozen = frozen
            guard enabled != placementEnabled else { return }
            placementEnabled = enabled
            if !enabled { reticle.hide(); reportPlacement(.none) }
        }

        private func reportPlacement(_ quality: ARPlacementQuality) {
            guard quality != lastQuality else { return }
            lastQuality = quality
            events?.sceneDidChangePlacement(quality: quality)
        }

        func addAnchor(named name: String, transform: simd_float4x4) {
            arView?.session.add(anchor: ARAnchor(name: name, transform: transform))
        }

        func removeAnchor(named name: String) {
            if let entity = signEntities.removeValue(forKey: name) {
                entity.removeFromParent()
            }
            if let anchor = anchors.removeValue(forKey: name) {
                arView?.session.remove(anchor: anchor)
            }
        }

        func showSign(anchorName: String, label: String, kind: ARSignKind, arrowHeadingDegrees: Double?) {
            guard let arView, let anchor = anchors[anchorName] else { return }
            signEntities.removeValue(forKey: anchorName)?.removeFromParent()
            let entity = AnchorEntity(anchor: anchor)
            let sign = ARSignEntityFactory.makeSign(
                label: label, kind: kind, arrowHeadingDegrees: arrowHeadingDegrees,
                anchorRotation: simd_quatf(anchor.transform))
            sign.generateCollisionShapes(recursive: true)
            entity.addChild(sign)
            arView.scene.addAnchor(entity)
            signEntities[anchorName] = entity
            if anchorName == selectedAnchorName { setSelected(anchorName: anchorName) }
        }

        func captureWorldMap() async throws -> ARWorldMap {
            guard let session = arView?.session else { throw CocoaError(.userCancelled) }
            return try await withCheckedThrowingContinuation { continuation in
                session.getCurrentWorldMap { map, error in
                    if let map {
                        continuation.resume(returning: map)
                    } else {
                        continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    }
                }
            }
        }

        func pause() {
            arView?.session.pause()
        }

        // MARK: ARSessionDelegate

        func session(_ session: ARSession, didAdd added: [ARAnchor]) {
            let signs = added.filter { $0.name?.hasPrefix(ARSurveyNode.anchorPrefix) == true }
            for anchor in signs {
                if let name = anchor.name { anchors[name] = anchor }
            }
            guard !signs.isEmpty else { return }
            events?.sceneDidAddAnchors(named: signs.compactMap(\.name))
        }

        func session(_ session: ARSession, didRemove removed: [ARAnchor]) {
            for name in removed.compactMap(\.name) {
                anchors.removeValue(forKey: name)
                signEntities.removeValue(forKey: name)?.removeFromParent()
            }
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            if placementEnabled, !placementFrozen, let arView {
                reportPlacement(reticle.update(frame: frame, in: arView))
            }
            let mapping = frame.worldMappingStatus
            let tracking = frame.camera.trackingState
            guard mapping != lastMapping || tracking != lastTracking else { return }
            lastMapping = mapping
            lastTracking = tracking
            events?.sceneDidUpdate(mapping: mapping, tracking: tracking)
        }

        func session(_ session: ARSession, didFailWithError error: Error) {
            events?.sceneDidFail(message: error.localizedDescription)
        }
    }
}
