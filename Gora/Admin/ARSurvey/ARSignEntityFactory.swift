//
//  ARSignEntityFactory.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import RealityKit
import UIKit
import SwiftUI

/// Builds the sign that stands on an anchor: a pole, a panel that faces the camera, and a
/// level arrow. The arrow entity always exists and is enabled only when the sign has a heading.
enum ARSignEntityFactory {
    private static let poleHeight: Float = 0.3
    private static let panelHeight: Float = 0.08
    private static let panelPadding: Float = 0.04
    private static let textFontSize: CGFloat = 0.035

    static let signName = "sign"
    static let arrowName = "arrow"
    private static let arrowLift: Float = 0.01

    static func makeSign(label: String, kind: ARSignKind, arrowHeadingDegrees: Double? = nil,
                         anchorRotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)) -> Entity {
        let root = Entity()
        root.name = signName
        let color = UIColor(kind.color)
        root.addChild(makePole(color: color))
        let panel = makePanel(label: label, color: color)
        panel.position = [0, poleHeight + panelHeight / 2, 0]
        root.addChild(panel)
        root.addChild(makeArrow(color: color))
        applyArrow(to: root, headingDegrees: arrowHeadingDegrees, anchorRotation: anchorRotation)
        return root
    }

    /// Shows, hides, or turns the arrow of a sign built by `makeSign`.
    static func applyArrow(to sign: Entity, headingDegrees: Double?, anchorRotation: simd_quatf) {
        guard let arrow = sign.findEntity(named: arrowName) else { return }
        arrow.isEnabled = headingDegrees != nil
        guard let headingDegrees else { return }
        arrow.orientation = arrowOrientation(headingDegrees: headingDegrees, anchorRotation: anchorRotation)
    }

    // The anchor turns the parent chain, so the local rotation is the inverse anchor rotation
    // times the world yaw. The product leaves the arrow level, whatever the anchor tilt.
    private static func arrowOrientation(headingDegrees: Double, anchorRotation: simd_quatf) -> simd_quatf {
        let yaw = simd_quatf(angle: Float(-headingDegrees * .pi / 180), axis: [0, 1, 0])
        return anchorRotation.inverse * yaw
    }

    // At heading 0 the arrow points along -Z. The shaft and the head together are 0.35 m long.
    private static func makeArrow(color: UIColor) -> Entity {
        let material = UnlitMaterial(color: color)
        let arrow = Entity()
        arrow.name = arrowName
        arrow.position = [0, arrowLift, 0]
        let shaft = ModelEntity(mesh: .generateBox(size: [0.02, 0.004, 0.25]), materials: [material])
        shaft.position = [0, 0, -0.125]
        arrow.addChild(shaft)
        arrow.addChild(makeArrowHead(material: material))
        return arrow
    }

    // Two triangles with opposite winding make the flat head visible from above and below.
    private static func makeArrowHead(material: UnlitMaterial) -> ModelEntity {
        var descriptor = MeshDescriptor(name: "arrowHead")
        descriptor.positions = MeshBuffers.Positions([[0, 0, -0.35], [-0.045, 0, -0.25], [0.045, 0, -0.25]])
        descriptor.primitives = .triangles([0, 1, 2, 0, 2, 1])
        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return ModelEntity() }
        return ModelEntity(mesh: mesh, materials: [material])
    }

    private static func makePole(color: UIColor) -> ModelEntity {
        let mesh = MeshResource.generateBox(size: [0.008, poleHeight, 0.008])
        let pole = ModelEntity(mesh: mesh, materials: [SimpleMaterial(color: color, isMetallic: false)])
        pole.position = [0, poleHeight / 2, 0]
        return pole
    }

    // The panel carries the billboard component, so the whole panel turns to face the camera.
    private static func makePanel(label: String, color: UIColor) -> Entity {
        let panel = Entity()
        panel.components.set(BillboardComponent())

        let text = MeshResource.generateText(
            label, extrusionDepth: 0.002, font: .boldSystemFont(ofSize: textFontSize),
            containerFrame: .zero, alignment: .center, lineBreakMode: .byTruncatingTail)
        let bounds = text.bounds
        let width = max(bounds.extents.x + panelPadding, 0.12)

        let background = ModelEntity(
            mesh: .generateBox(size: [width, panelHeight, 0.006], cornerRadius: 0.01),
            materials: [SimpleMaterial(color: color, isMetallic: false)])
        let textEntity = ModelEntity(
            mesh: text, materials: [UnlitMaterial(color: .white)])
        textEntity.position = [-bounds.center.x, -bounds.center.y, 0.004]

        panel.addChild(background)
        panel.addChild(textEntity)
        return panel
    }
}
