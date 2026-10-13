//
//  WalkARSceneView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import ARKit
import RealityKit
import SwiftUI
import simd

/// Hosts an `ARView` and feeds its frames to the view model.
struct WalkARSceneView: UIViewRepresentable {
    let viewModel: WalkARViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.renderOptions.formUnion([.disableMotionBlur, .disableDepthOfField, .disableHDR,
                                      .disablePersonOcclusion, .disableGroundingShadows, .disableCameraGrain])
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.tearDown(view: uiView)
    }

    /// ARKit calls the delegate on the main queue because `delegateQueue` stays `nil`.
    /// The class is main actor isolated, so frame handling touches the view model directly.
    final class Coordinator: NSObject, @preconcurrency ARSessionDelegate {
        static let planeRadiusMeters: Float = 15
        static let signRadiusMeters: Float = 40
        static let floorQueryInterval: TimeInterval = 0.1
        static let signCheckInterval: TimeInterval = 1
        static let positioningInterval: TimeInterval = 0.1
        static let l2RefreshInterval: TimeInterval = 1

        private let viewModel: WalkARViewModel
        private let scene: WalkARGuidanceScene
        private weak var arView: ARView?
        private var planes: [UUID: FloorPlane] = [:]
        private let power = WalkARPowerPolicy()
        private var configuration: ARWorldTrackingConfiguration?
        private var isSessionPaused = false
        private var floorPlaneHeight: Float?
        private var lastFloorQuery: TimeInterval = 0
        private var lastSignCheck: TimeInterval = 0
        private var lastPositioningTime: TimeInterval = 0
        private var lastPose: (position: SIMD3<Float>, pitch: Double, isTrackingNormal: Bool)?
        private var areSignsAllowed = false
        private var surveyAnchors: [String: ARAnchor] = [:]
        private var signEntities: [String: AnchorEntity] = [:]
        private var l2Entities: [String: AnchorEntity] = [:]
        private var l2LastRefresh: [String: TimeInterval] = [:]
        private var isRelocalized = false
        private var cameraPosition = SIMD3<Float>.zero

        private struct FloorPlane {
            let x: Float
            let y: Float
            let z: Float
            let area: Float
        }

        init(viewModel: WalkARViewModel) {
            self.viewModel = viewModel
            scene = WalkARGuidanceScene(path: viewModel.path, turns: viewModel.turns)
        }

        func attach(to view: ARView) {
            arView = view
            view.scene.addAnchor(scene.worldAnchor)
            guard ARWorldTrackingConfiguration.isSupported else { return }
            let configuration = ARWorldTrackingConfiguration()
            configuration.worldAlignment = .gravity
            configuration.planeDetection = [.horizontal]
            configuration.initialWorldMap = viewModel.survey?.worldMap
            if let images = viewModel.survey?.referenceImages, !images.isEmpty {
                configuration.detectionImages = images
                configuration.maximumNumberOfTrackedImages = 1
            }
            if power.state >= .reduced, let format = WalkARPowerPolicy.thirtyFpsFormat() {
                configuration.videoFormat = format
            }
            self.configuration = configuration
            view.session.delegate = self
            power.onChange = { [weak self] in self?.apply(power: $0) }
            power.start()
            apply(power: power.state)
            UIDevice.current.isBatteryMonitoringEnabled = true
            viewModel.start()
            if viewModel.survey?.phase == .ready {
                viewModel.positioning.send(.surveyReady(time: ProcessInfo.processInfo.systemUptime))
            }
        }

        /// Reduced power halves the chevron count. Critical power pauses the session.
        private func apply(power state: WalkARPowerState) {
            scene.setReducedChevrons(state >= .reduced)
            sendPositioning(time: ProcessInfo.processInfo.systemUptime)
            if state == .critical, !isSessionPaused {
                isSessionPaused = true
                arView?.session.pause()
                scene.hide()
                viewModel.setPaused(true)
            } else if state < .critical, let configuration, let session = arView?.session,
                      isSessionPaused || session.currentFrame == nil {
                let wasPaused = isSessionPaused
                isSessionPaused = false
                session.run(configuration)
                viewModel.setPaused(false)
                if wasPaused { clearPlanes() }
            }
        }

        func tearDown(view: ARView) {
            power.stop()
            view.session.pause()
            view.session.delegate = nil
            view.scene.anchors.removeAll()
            signEntities.removeAll()
            l2Entities.removeAll()
            UIDevice.current.isBatteryMonitoringEnabled = false
            viewModel.stop()
        }

        // MARK: ARSessionDelegate

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let columns = frame.camera.transform.columns
            let position = SIMD3(columns.3.x, columns.3.y, columns.3.z)
            cameraPosition = position
            let tracking = Self.quality(of: frame.camera.trackingState)
            relocalizeIfReady(tracking: tracking)
            let forward = SIMD2(-columns.2.x, -columns.2.z)
            let horizontal = simd_length(forward) > 0.3 ? simd_normalize(forward) : nil
            viewModel.handleFrame(cameraPosition: position, forward: horizontal,
                                  tracking: tracking, time: frame.timestamp)
            let pitch = asin(Double(max(-1, min(1, -columns.2.y))))
            lastPose = (position, pitch, tracking == .normal)
            if frame.timestamp - lastPositioningTime >= Self.positioningInterval {
                lastPositioningTime = frame.timestamp
                sendPositioning(time: frame.timestamp)
            }
            refreshFloorPlane(time: frame.timestamp)
            refreshSignVisibility(time: frame.timestamp)
            scene.updateFloor(planeY: floorPlaneHeight, cameraY: position.y, time: frame.timestamp)
            if let transform = viewModel.transform {
                scene.update(transform: transform, progress: viewModel.progress, isVisible: viewModel.tier.showsWorldLockedRoute,
                             cameraPosition: position, time: frame.timestamp)
            } else {
                scene.hide()
            }
            viewModel.updateScreenGuide(edgeAngle: edgeAngle(in: frame), time: frame.timestamp)
        }

        func sessionWasInterrupted(_ session: ARSession) {
            scene.hide()
        }

        func sessionInterruptionEnded(_ session: ARSession) {
            clearPlanes()
            scene.resetFloor()
            viewModel.resetAlignmentAfterRelocalization()
        }

        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            record(anchors)
            placeByImage(anchors)
            for anchor in anchors {
                if let name = anchor.name, name.hasPrefix(ARSurveyNode.anchorPrefix) { surveyAnchors[name] = anchor }
            }
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            record(anchors)
            placeByImage(anchors)
        }

        func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
            anchors.forEach { planes[$0.identifier] = nil }
            for name in anchors.compactMap(\.name) {
                surveyAnchors[name] = nil
                signEntities.removeValue(forKey: name)?.removeFromParent()
            }
        }

        // MARK: Positioning

        /// Sends the last camera pose with the alignment and the device state to the coordinator.
        /// Battery level -1 means unknown and counts as full.
        private func sendPositioning(time: TimeInterval) {
            guard let pose = lastPose else { return }
            let battery = Double(UIDevice.current.batteryLevel)
            viewModel.positioning.send(.sample(PositioningSample(
                time: time, cameraPosition: pose.position, pitchRadians: pose.pitch,
                isTrackingNormal: pose.isTrackingNormal, alignment: viewModel.alignment, power: power.state,
                isThermalSerious: ProcessInfo.processInfo.thermalState == .serious,
                batteryFraction: battery < 0 ? 1 : battery)))
        }

        // MARK: Survey

        /// Runs once, when a survey sign anchor has arrived and tracking is normal.
        private func relocalizeIfReady(tracking: WalkARTrackingQuality) {
            guard let survey = viewModel.survey, survey.phase == .ready, !isRelocalized,
                  !surveyAnchors.isEmpty, tracking == .normal, let arView else { return }
            isRelocalized = true
            removeL2Signs()
            viewModel.positioning.send(.relocalized(time: ProcessInfo.processInfo.systemUptime))
            let shown = showSigns(of: survey, in: arView)
            clearPlanes()
            scene.resetFloor()
            viewModel.resetAlignmentAfterRelocalization()
            survey.markRelocalized(signsShown: shown)
        }

        /// Each sign stands on its own anchor entity, so realigning the route never moves it.
        private func showSigns(of survey: WalkARSurvey, in view: ARView) -> Int {
            for (name, anchor) in surveyAnchors {
                guard let node = survey.node(anchorName: name) else { continue }
                let entity = AnchorEntity(anchor: anchor)
                entity.addChild(ARSignEntityFactory.makeSign(
                    label: node.label, kind: node.kind,
                    arrowHeadingDegrees: node.arrowHeadingDegrees,
                    anchorRotation: simd_quatf(anchor.transform)))
                view.scene.addAnchor(entity)
                signEntities[name] = entity
            }
            return signEntities.count
        }

        // MARK: L2 sign images

        /// Places the survey signs from a tracked sign image, until L1 relocalizes. Each image
        /// refreshes the placement at most once per `l2RefreshInterval`.
        private func placeByImage(_ anchors: [ARAnchor]) {
            guard !isRelocalized, let survey = viewModel.survey, survey.phase == .ready, let arView else { return }
            let now = ProcessInfo.processInfo.systemUptime
            for case let image as ARImageAnchor in anchors where image.isTracked {
                guard let name = image.referenceImage.name, let imagePose = survey.imagePose(named: name),
                      now - (l2LastRefresh[name] ?? -.infinity) >= Self.l2RefreshInterval else { continue }
                l2LastRefresh[name] = now
                let sessionFromSurvey = SurveyFrameSolver.sessionFromSurvey(
                    imageInSession: image.transform, imageInSurvey: imagePose)
                placeL2Signs(of: survey, imageInSurvey: imagePose, sessionFromSurvey: sessionFromSurvey, in: arView)
                lastSignCheck = 0
                let origin = image.transform.columns.3
                viewModel.positioning.send(.placedByL2(time: now, imagePosition: SIMD3(origin.x, origin.y, origin.z)))
                survey.markPlacedByL2(signsShown: l2Entities.count)
            }
        }

        /// Keeps a sign only when it lies within `l2RadiusMeters` of the image in the survey frame.
        private func placeL2Signs(of survey: WalkARSurvey, imageInSurvey: simd_float4x4,
                                  sessionFromSurvey: simd_float4x4, in view: ARView) {
            let imageOrigin = Self.translation(of: imageInSurvey)
            for (name, signPose) in survey.signPoses {
                guard simd_distance(Self.translation(of: signPose), imageOrigin) <= Float(SurveyFrameSolver.l2RadiusMeters),
                      let node = survey.node(anchorName: name) else {
                    l2Entities.removeValue(forKey: name)?.removeFromParent()
                    continue
                }
                let world = SurveyFrameSolver.inSession(signPose, sessionFromSurvey: sessionFromSurvey)
                if let entity = l2Entities[name] {
                    entity.setTransformMatrix(world, relativeTo: nil)
                    continue
                }
                let entity = AnchorEntity(world: world)
                entity.isEnabled = false
                entity.addChild(ARSignEntityFactory.makeSign(
                    label: node.label, kind: node.kind, arrowHeadingDegrees: node.arrowHeadingDegrees,
                    anchorRotation: simd_quatf(signPose)))
                view.scene.addAnchor(entity)
                l2Entities[name] = entity
            }
        }

        private func removeL2Signs() {
            l2Entities.values.forEach { $0.removeFromParent() }
            l2Entities.removeAll()
        }

        private static func translation(of transform: simd_float4x4) -> SIMD3<Float> {
            SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        }

        // MARK: Helpers

        /// Screen direction toward the next decision, from `ARView.project`. `nil` when no pointer is needed.
        private func edgeAngle(in frame: ARFrame) -> Double? {
            guard let arView, let transform = viewModel.transform, let target = viewModel.edgeTarget() else { return nil }
            let world = transform.arPosition(of: target.decision.coordinate, groundY: scene.floorY)
            return WalkARScreenProjector.edgeAngle(
                toWorld: world, cameraTransform: frame.camera.transform, projected: arView.project(world),
                viewSize: arView.bounds.size,
                isBeyondWindow: target.distance > WalkARGuidanceScene.lookAheadMeters)
        }

        private func record(_ anchors: [ARAnchor]) {
            for case let plane as ARPlaneAnchor in anchors where plane.alignment == .horizontal {
                let extent = plane.planeExtent
                let center = plane.transform * SIMD4<Float>(plane.center, 1)
                let entry = FloorPlane(x: center.x, y: center.y, z: center.z, area: extent.width * extent.height)
                if isNearCamera(entry) { planes[plane.identifier] = entry } else { planes[plane.identifier] = nil }
            }
        }

        private func isNearCamera(_ plane: FloorPlane) -> Bool {
            simd_length(SIMD2(plane.x - cameraPosition.x, plane.z - cameraPosition.z)) <= Self.planeRadiusMeters
        }

        private func clearPlanes() {
            planes.removeAll()
            floorPlaneHeight = nil
            lastFloorQuery = 0
        }

        /// At 10 Hz, drops far planes and picks the largest plane 0.6 to 2.2 m below the camera.
        private func refreshFloorPlane(time: TimeInterval) {
            guard time - lastFloorQuery >= Self.floorQueryInterval else { return }
            lastFloorQuery = time
            planes = planes.filter { isNearCamera($0.value) }
            let cameraY = cameraPosition.y
            floorPlaneHeight = planes.values
                .filter { $0.y < cameraY - 0.6 && $0.y > cameraY - 2.2 }
                .max { $0.area < $1.area }?.y
        }

        /// Shows an L1 or L2 sign only while the tier allows survey signs and it is within 40 m of the camera.
        /// It runs at 1 Hz and at once when the tier changes the permission.
        private func refreshSignVisibility(time: TimeInterval) {
            let isAllowed = viewModel.showsSurveySigns
            let isChanged = isAllowed != areSignsAllowed
            guard !(signEntities.isEmpty && l2Entities.isEmpty), isChanged || time - lastSignCheck >= Self.signCheckInterval else { return }
            areSignsAllowed = isAllowed
            lastSignCheck = time
            for (name, entity) in signEntities {
                guard let columns = surveyAnchors[name]?.transform.columns else { continue }
                setSign(entity, enabledAt: SIMD3(columns.3.x, columns.3.y, columns.3.z), isAllowed: isAllowed)
            }
            for entity in l2Entities.values {
                setSign(entity, enabledAt: entity.position(relativeTo: nil), isAllowed: isAllowed)
            }
        }

        private func setSign(_ entity: AnchorEntity, enabledAt position: SIMD3<Float>, isAllowed: Bool) {
            let isShown = isAllowed && simd_distance(position, cameraPosition) <= Self.signRadiusMeters
            if entity.isEnabled != isShown { entity.isEnabled = isShown }
        }

        private static func quality(of state: ARCamera.TrackingState) -> WalkARTrackingQuality {
            switch state {
            case .normal: .normal
            case .limited: .limited
            case .notAvailable: .unavailable
            }
        }
    }
}
