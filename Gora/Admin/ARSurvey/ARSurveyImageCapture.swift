//
//  ARSurveyImageCapture.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import ARKit
import CoreImage
import RealityKit

/// The framing rectangle of the sign image capture. The guide view and the crop use the same rectangle.
enum ARSignFraming {
    static let widthFraction: CGFloat = 0.8
    static let aspectRatio: CGFloat = 0.6

    /// The rectangle, centred in a view of the given size.
    static func rect(in size: CGSize) -> CGRect {
        let width = size.width * widthFraction
        let height = width * aspectRatio
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}

/// An upright crop of the camera image with the measured width and pose of the sign.
struct ARSignImageCapture {
    let image: CGImage
    let physicalWidth: Double
    let transform: simd_float4x4
}

enum ARSignImageCaptureError: LocalizedError {
    case noFrame, notFlatSurface, cropFailed

    var errorDescription: String? {
        switch self {
        case .noFrame: "The camera is not ready."
        case .notFlatSurface: "Point at a flat sign on a wall"
        case .cropFailed: "The image could not be cropped."
        }
    }
}

extension ARSurveySceneView.Coordinator {
    private static let raycastStrategies: [ARRaycastQuery.Target] = [.existingPlaneGeometry, .estimatedPlane]

    /// Crops the current camera image to the framing rectangle and measures the sign on a wall.
    func captureSignImage() throws -> ARSignImageCapture {
        guard let arView, let frame = arView.session.currentFrame else { throw ARSignImageCaptureError.noFrame }
        let viewSize = arView.bounds.size
        let framing = ARSignFraming.rect(in: viewSize)
        let (center, left, right) = try raycastHits(in: arView, framing: framing)
        let image = try croppedImage(from: frame, framing: framing, viewSize: viewSize, in: arView)
        let cameraPosition = frame.camera.transform.columns.3.xyz
        let pose = Self.pose(center: center, left: left.xyz, right: right.xyz, cameraPosition: cameraPosition)
        return ARSignImageCapture(image: image, physicalWidth: Double(simd_distance(left.xyz, right.xyz)),
                                  transform: pose)
    }

    // MARK: Raycast

    /// The world transforms at the centre and the left and right edge midpoints.
    /// All three hits come from the same raycast strategy so they share one plane.
    private func raycastHits(in arView: ARView, framing: CGRect)
        throws -> (center: simd_float4x4, left: simd_float4, right: simd_float4) {
        let points = [CGPoint(x: framing.midX, y: framing.midY),
                      CGPoint(x: framing.minX, y: framing.midY),
                      CGPoint(x: framing.maxX, y: framing.midY)]
        for target in Self.raycastStrategies {
            let hits = points.compactMap { arView.raycast(from: $0, allowing: target, alignment: .vertical).first }
            guard hits.count == points.count else { continue }
            let width = simd_distance(hits[1].worldTransform.columns.3.xyz, hits[2].worldTransform.columns.3.xyz)
            guard width > 0 else { continue }
            return (hits[0].worldTransform, hits[1].worldTransform.columns.3, hits[2].worldTransform.columns.3)
        }
        throw ARSignImageCaptureError.notFlatSurface
    }

    /// +Y is the plane normal facing the camera, +X runs from the left hit to the right hit,
    /// and +Z points down the sign, as ARKit defines an image anchor.
    private static func pose(center: simd_float4x4, left: SIMD3<Float>, right: SIMD3<Float>,
                             cameraPosition: SIMD3<Float>) -> simd_float4x4 {
        let origin = center.columns.3.xyz
        var normal = simd_normalize(center.columns.1.xyz)
        if simd_dot(normal, cameraPosition - origin) < 0 { normal = -normal }
        let along = right - left
        let xAxis = simd_normalize(along - simd_dot(along, normal) * normal)
        let zAxis = simd_cross(xAxis, normal)
        return simd_float4x4(columns: (
            SIMD4(xAxis, 0), SIMD4(normal, 0), SIMD4(zAxis, 0), SIMD4(origin, 1)))
    }

    // MARK: Crop

    /// Maps the framing rectangle to camera image coordinates, crops, and rotates the crop upright.
    private func croppedImage(from frame: ARFrame, framing: CGRect, viewSize: CGSize, in arView: ARView) throws -> CGImage {
        let interface = arView.window?.windowScene?.interfaceOrientation ?? .portrait
        let toImage = frame.displayTransform(for: interface, viewportSize: viewSize).inverted()
        let normalized = CGRect(x: framing.minX / viewSize.width, y: framing.minY / viewSize.height,
                                width: framing.width / viewSize.width, height: framing.height / viewSize.height)
        let imageRect = normalized.applying(toImage)

        let source = CIImage(cvPixelBuffer: frame.capturedImage)
        let size = source.extent.size
        let pixelRect = CGRect(x: imageRect.minX * size.width, y: imageRect.minY * size.height,
                               width: imageRect.width * size.width, height: imageRect.height * size.height)
        let flipped = CGRect(x: pixelRect.minX, y: size.height - pixelRect.maxY,
                             width: pixelRect.width, height: pixelRect.height).intersection(source.extent)
        guard !flipped.isNull, flipped.width > 1, flipped.height > 1 else { throw ARSignImageCaptureError.cropFailed }

        let upright = source.cropped(to: flipped).oriented(Self.uprightOrientation(for: interface))
        guard let image = CIContext().createCGImage(upright, from: upright.extent) else {
            throw ARSignImageCaptureError.cropFailed
        }
        return image
    }

    /// The rotation that turns the sensor-oriented camera image upright for an interface orientation.
    private static func uprightOrientation(for interface: UIInterfaceOrientation) -> CGImagePropertyOrientation {
        switch interface {
        case .portrait: .right
        case .portraitUpsideDown: .left
        case .landscapeLeft: .down
        default: .up
        }
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
