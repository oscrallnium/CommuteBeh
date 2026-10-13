//
//  WalkARSurvey.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import ARKit
import Observation
import simd

/// A saved AR survey that the walk session loads. It holds the metadata, the world map, and
/// the text that the HUD shows about relocalization.
@Observable
final class WalkARSurvey {
    enum Phase: Equatable {
        case loading
        case ready
        case failed
    }

    let id: UUID
    private(set) var phase = Phase.loading
    private(set) var metadata: ARSurveyMetadata?
    private(set) var signsShown: Int?

    // Read once when the session starts, so it stays outside observation.
    @ObservationIgnored private(set) var worldMap: ARWorldMap?
    @ObservationIgnored private(set) var referenceImages: Set<ARReferenceImage> = []
    /// Image poses in the survey frame, keyed by the image anchor id string.
    @ObservationIgnored private var imagePoses: [String: simd_float4x4] = [:]
    /// Sign poses in the survey frame, keyed by anchor name. They come from the world map.
    @ObservationIgnored private(set) var signPoses: [String: simd_float4x4] = [:]
    @ObservationIgnored private let store = ARSurveyStore()

    init(id: UUID) {
        self.id = id
    }

    func load() async {
        guard phase == .loading else { return }
        let store = store
        let id = id
        do {
            let (loaded, map, images, poses) = try await Task.detached(priority: .userInitiated) {
                let loaded = try store.loadMetadata(id: id)
                let map = try store.loadWorldMap(id: id)
                return (loaded, map, Self.loadReferenceImages(of: loaded, surveyID: id, store: store),
                        Self.loadSignPoses(in: map))
            }.value
            metadata = loaded
            worldMap = map
            referenceImages = Set(images.map(\.image))
            imagePoses = Dictionary(uniqueKeysWithValues: images.map { ($0.name, $0.pose) })
            signPoses = poses
            phase = .ready
        } catch {
            phase = .failed
        }
    }

    func node(anchorName: String) -> ARSurveyNode? {
        metadata?.nodes.first { $0.anchorIdentifier == anchorName }
    }

    func markRelocalized(signsShown: Int) {
        self.signsShown = signsShown
    }

    func markPlacedByL2(signsShown: Int) {
        self.signsShown = signsShown
    }

    /// The image pose in the survey frame for a detected reference image name.
    func imagePose(named name: String) -> simd_float4x4? {
        imagePoses[name]
    }

    private nonisolated struct LoadedImage {
        let name: String
        let pose: simd_float4x4
        let image: ARReferenceImage
    }

    /// Skips an anchor that has no file, no valid pose or an unreadable image.
    private nonisolated static func loadReferenceImages(of metadata: ARSurveyMetadata, surveyID: UUID,
                                                        store: ARSurveyStore) -> [LoadedImage] {
        metadata.imageAnchors.compactMap { anchor in
            guard !anchor.fileName.isEmpty, anchor.physicalWidth > 0, let pose = anchor.poseTransform,
                  let cgImage = try? store.loadImage(surveyID: surveyID, fileName: anchor.fileName) else { return nil }
            let image = ARReferenceImage(cgImage, orientation: .up, physicalWidth: CGFloat(anchor.physicalWidth))
            image.name = anchor.id.uuidString
            return LoadedImage(name: anchor.id.uuidString, pose: pose, image: image)
        }
    }

    private nonisolated static func loadSignPoses(in map: ARWorldMap) -> [String: simd_float4x4] {
        var poses: [String: simd_float4x4] = [:]
        for anchor in map.anchors {
            if let name = anchor.name, name.hasPrefix(ARSurveyNode.anchorPrefix) { poses[name] = anchor.transform }
        }
        return poses
    }

    var statusLine: String? {
        switch phase {
        case .loading: nil
        case .failed: "The survey could not be loaded"
        case .ready:
            "Survey: \(metadata?.name ?? "") · "
                + (signsShown.map { "\($0) signs shown" } ?? "Point your iPhone at the scanned area to show its signs")
        }
    }
}
