//
//  ARSurveyViewModel.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import ARKit
import Observation
import UIKit

enum ARSurveyRoute: Hashable {
    case new(ARSurveyMetadata)
    case replay(UUID)
}

/// A validated sign image that waits for a name.
struct ARPendingSignImage: Identifiable {
    let id = UUID()
    let image: CGImage
    let pngData: Data
    let physicalWidth: Double
    let transform: simd_float4x4
}

/// A tap at the reticle and waits for the label and the kind.
struct ARPendingSign: Identifiable {
    let id = UUID()
    let transform: simd_float4x4
    /// The camera heading at the moment of the tap, in whole 5 degree steps.
    let arrowHeadingDegrees: Double
}

@MainActor
@Observable
final class ARSurveyViewModel: ARSurveySceneEvents {
    enum Mode { case new, replay }

    let mode: Mode
    private(set) var metadata: ARSurveyMetadata
    private(set) var mappingStatus: ARFrame.WorldMappingStatus = .notAvailable
    private(set) var trackingState: ARCamera.TrackingState = .notAvailable
    private(set) var isLoading = false
    private(set) var isRelocalized = false
    private(set) var relocalizationSeconds: Double?
    private(set) var isSaving = false
    private(set) var placementQuality: ARPlacementQuality = .none
    private(set) var isFramingSignImage = false
    private(set) var isCapturingImage = false
    var pendingSign: ARPendingSign?
    var pendingSignImage: ARPendingSignImage?
    var message: String?
    var selectedAnchorName: String?
    var isEditingSelection = false

    @ObservationIgnored weak var scene: ARSurveyScene?
    @ObservationIgnored private let store = ARSurveyStore()
    @ObservationIgnored private var initialWorldMap: ARWorldMap?
    @ObservationIgnored private var sessionStart: ContinuousClock.Instant?
    @ObservationIgnored private var arrivedAnchors: Set<String> = []
    @ObservationIgnored private var rotationBase: Double?
    @ObservationIgnored private var unsavedImages: [String: Data] = [:]

    init(route: ARSurveyRoute) {
        switch route {
        case .new(let draft):
            mode = .new
            metadata = draft
        case .replay(let id):
            mode = .replay
            metadata = ARSurveyMetadata.new(
                name: "", zoneName: "", light: .day, deviceModel: "", iosVersion: "")
            replayID = id
            isLoading = true
        }
    }

    @ObservationIgnored private var replayID: UUID?

    var isReady: Bool { !isLoading && (mode == .new || initialWorldMap != nil) }
    var signCount: Int { metadata.nodes.count }
    var imageAnchors: [ARSurveyImageAnchor] { metadata.imageAnchors }
    var isSceneInteractive: Bool { mode == .new || isRelocalized }
    var canSave: Bool { mappingStatus == .mapped && isSceneInteractive && !isSaving }
    var showsCoaching: Bool { mode == .replay && !isRelocalized }
    var selectedNode: ARSurveyNode? { metadata.nodes.first { $0.anchorIdentifier == selectedAnchorName } }

    // MARK: Session setup

    func load() async {
        guard mode == .replay, let id = replayID, initialWorldMap == nil else { return }
        do {
            let store = store
            let (loaded, map) = try await Task.detached(priority: .userInitiated) {
                (try store.loadMetadata(id: id), try store.loadWorldMap(id: id))
            }.value
            metadata = loaded
            initialWorldMap = map
        } catch {
            message = "This survey could not be opened."
        }
        isLoading = false
    }

    func makeConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.initialWorldMap = initialWorldMap
        return configuration
    }

    var runOptions: ARSession.RunOptions {
        mode == .replay ? [.resetTracking, .removeExistingAnchors] : []
    }

    func sessionDidStart() {
        sessionStart = .now
    }

    func stop() {
        scene?.pause()
    }

    // MARK: Placing signs

    func handleTap() {
        guard isSceneInteractive, !isFramingSignImage, pendingSign == nil, let transform = scene?.placementTransform() else { return }
        message = nil
        select(nil)
        let heading = Self.snapped(scene?.cameraHeadingDegrees() ?? 0)
        pendingSign = ARPendingSign(transform: transform, arrowHeadingDegrees: heading)
    }

    func confirmSign(label: String, kind: ARSignKind, hasArrow: Bool) {
        guard let pending = pendingSign else { return }
        pendingSign = nil
        let node = ARSurveyNode(
            label: label, kind: kind, arrowHeadingDegrees: hasArrow ? pending.arrowHeadingDegrees : nil)
        metadata.nodes.append(node)
        scene?.addAnchor(named: node.anchorIdentifier, transform: pending.transform)
    }

    func cancelPendingSign() {
        pendingSign = nil
    }

    func undoLastSign() {
        guard let node = metadata.nodes.popLast() else { return }
        if node.anchorIdentifier == selectedAnchorName { select(nil) }
        scene?.removeAnchor(named: node.anchorIdentifier)
    }

    // MARK: Sign images

    func beginSignImageFraming() {
        guard isSceneInteractive, pendingSign == nil else { return }
        message = nil
        select(nil)
        isFramingSignImage = true
    }

    func cancelSignImageFraming() {
        isFramingSignImage = false
    }

    /// Crops and measures the framed sign, then checks that ARKit accepts the image.
    /// A failure shows its reason and keeps the framing guide open.
    func captureSignImage() async {
        guard isFramingSignImage, !isCapturingImage, let scene else { return }
        isCapturingImage = true
        defer { isCapturingImage = false }
        message = nil
        do {
            let capture = try scene.captureSignImage()
            let reference = ARReferenceImage(
                capture.image, orientation: .up, physicalWidth: CGFloat(capture.physicalWidth))
            if let error = await Self.validationError(of: reference) {
                let reason = (error as NSError).localizedFailureReason ?? error.localizedDescription
                message = "This image cannot be tracked. \(reason)"
                return
            }
            let png = try ARSurveyStore.pngData(for: capture.image)
            pendingSignImage = ARPendingSignImage(
                image: capture.image, pngData: png, physicalWidth: capture.physicalWidth,
                transform: capture.transform)
            isFramingSignImage = false
        } catch {
            message = error.localizedDescription
        }
    }

    func confirmSignImage(name: String) {
        guard let pending = pendingSignImage else { return }
        pendingSignImage = nil
        let fileName = "image_\(pending.id.uuidString).png"
        metadata.imageAnchors.append(ARSurveyImageAnchor(
            id: pending.id, name: name, physicalWidth: pending.physicalWidth,
            transform: pending.transform, fileName: fileName))
        unsavedImages[fileName] = pending.pngData
    }

    func cancelPendingSignImage() {
        pendingSignImage = nil
    }

    private static func validationError(of image: ARReferenceImage) async -> Error? {
        await withCheckedContinuation { continuation in
            image.validate { continuation.resume(returning: $0) }
        }
    }

    // MARK: Editing signs

    func sceneDidSelectSign(anchorName: String) {
        guard isSceneInteractive, pendingSign == nil else { return }
        select(anchorName)
    }

    func clearSelection() { select(nil) }

    func sceneDidRotate(byDegrees degrees: Double, isFinished: Bool) {
        guard let current = selectedNode?.arrowHeadingDegrees else { return }
        let base = rotationBase ?? current
        rotationBase = isFinished ? nil : base
        setHeading(isFinished ? Self.snapped(base + degrees) : base + degrees)
    }

    func rotateSelectedArrow(byDegrees degrees: Double) {
        guard let current = selectedNode?.arrowHeadingDegrees else { return }
        setHeading(current + degrees)
    }

    func toggleSelectedArrow() {
        guard let node = selectedNode else { return }
        if node.arrowHeadingDegrees == nil {
            setHeading(Self.snapped(scene?.cameraHeadingDegrees() ?? 0))
        } else {
            setHeading(nil)
        }
    }

    func confirmEdit(label: String, kind: ARSignKind) {
        isEditingSelection = false
        guard let index = selectedIndex else { return }
        metadata.nodes[index].label = label
        metadata.nodes[index].kind = kind
        let node = metadata.nodes[index]
        scene?.showSign(anchorName: node.anchorIdentifier, label: label, kind: kind,
                        arrowHeadingDegrees: node.arrowHeadingDegrees)
    }

    func deleteSelectedSign() {
        guard let index = selectedIndex else { return }
        let node = metadata.nodes.remove(at: index)
        select(nil)
        scene?.removeAnchor(named: node.anchorIdentifier)
    }

    private var selectedIndex: Int? {
        metadata.nodes.firstIndex { $0.anchorIdentifier == selectedAnchorName }
    }

    private func select(_ name: String?) {
        rotationBase = nil
        selectedAnchorName = name
        scene?.setSelected(anchorName: name)
    }

    private func setHeading(_ degrees: Double?) {
        guard let index = selectedIndex else { return }
        let heading = degrees.map(Self.normalized)
        metadata.nodes[index].arrowHeadingDegrees = heading
        scene?.setArrow(anchorName: metadata.nodes[index].anchorIdentifier, headingDegrees: heading)
    }

    private static func normalized(_ degrees: Double) -> Double {
        let remainder = degrees.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }

    private static func snapped(_ degrees: Double) -> Double {
        normalized((degrees / 5).rounded() * 5)
    }

    // MARK: Save

    func save() async {
        guard canSave, let scene else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let map = try await scene.captureWorldMap()
            let archive = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
            var draft = metadata
            draft.captureContext = captureContext(featurePointCount: map.rawFeaturePoints.points.count)
            let store = store
            let images = unsavedImages
            let saved = try await Task.detached(priority: .userInitiated) {
                try store.save(draft, worldMapArchive: archive, images: images)
            }.value
            metadata = saved
            unsavedImages.removeAll()
            message = saveMessage(for: await Task.detached { store.validate(saved) }.value)
        } catch {
            message = "The survey could not be saved. \(error.localizedDescription)"
        }
    }

    private func captureContext(featurePointCount: Int) -> ARCaptureContext {
        var context = metadata.captureContext
        context.deviceModel = Self.deviceModel
        context.iosVersion = UIDevice.current.systemVersion
        context.worldMappingQuality = mappingStatus.apiName
        context.featurePointCount = featurePointCount
        return context
    }

    private func saveMessage(for validation: ARSurveyValidation) -> String {
        let issues = validation.errors + validation.warnings
        return issues.isEmpty ? "Survey saved." : "Survey saved with warnings. " + issues.joined(separator: " ")
    }

    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: ARSurveySceneEvents

    func sceneDidAddAnchors(named names: [String]) {
        arrivedAnchors.formUnion(names)
        if mode == .new || isRelocalized {
            showSigns(named: names)
        } else {
            evaluateRelocalization()
        }
    }

    func sceneDidUpdate(mapping: ARFrame.WorldMappingStatus, tracking: ARCamera.TrackingState) {
        mappingStatus = mapping
        trackingState = tracking
        if mode == .replay, !isRelocalized {
            evaluateRelocalization()
        }
    }

    func sceneDidChangePlacement(quality: ARPlacementQuality) {
        placementQuality = quality
    }

    func sceneDidFail(message: String) {
        self.message = "The camera session stopped. \(message)"
    }

    // MARK: Relocalization

    private func evaluateRelocalization() {
        guard !isRelocalized, !arrivedAnchors.isEmpty, case .normal = trackingState else { return }
        isRelocalized = true
        if let start = sessionStart {
            let elapsed = start.duration(to: .now)
            relocalizationSeconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
        }
        showSigns(named: Array(arrivedAnchors))
    }

    private func showSigns(named names: [String]) {
        for name in names {
            guard let node = metadata.nodes.first(where: { $0.anchorIdentifier == name }) else { continue }
            scene?.showSign(anchorName: name, label: node.label, kind: node.kind,
                            arrowHeadingDegrees: node.arrowHeadingDegrees)
        }
    }
}
