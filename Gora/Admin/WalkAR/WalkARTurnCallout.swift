//
//  WalkARTurnCallout.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import RealityKit
import UIKit
import simd
import SwiftUI

/// A floor arrow at the next turn and a billboard label above it. The entity is a child of the
/// guidance root, so a realign moves it with the route.
final class WalkARTurnCallout {
    static let calloutMeters = 30.0
    static let textIntervalSeconds = 0.25
    static let labelHeightMeters: Float = 1.1
    static let exitLengthMeters: Float = 1.2
    static let barWidthMeters: Float = 0.14

    let entity = Entity()
    private let path: PolylinePath
    private let turns: [WalkTurn]
    private let routeAnchor: Coordinates
    private let label = Entity()
    private let plate = ModelEntity(mesh: .generatePlane(width: 1, height: 0.3),
                                    materials: [UnlitMaterial(color: UIColor(white: 0.08, alpha: 1))])
    private let text = ModelEntity(mesh: .generatePlane(width: 0.1, height: 0.1),
                                   materials: [UnlitMaterial(color: .white)])
    private let material = UnlitMaterial(color: UIColor(TransportMode.walk.color))
    private let barMesh = MeshResource.generateBox(size: SIMD3(barWidthMeters, 0.01, 1))
    private let headMesh = WalkARGuidanceScene.chevronMesh(scale: 1.6)
    private var arrow: Entity?
    private var activeIndex: Int?
    private var shownText = ""
    private var lastTextTime = -Double.infinity

    init(path: PolylinePath, turns: [WalkTurn], routeAnchor: Coordinates) {
        self.path = path
        self.turns = turns
        self.routeAnchor = routeAnchor
        label.addChild(plate)
        label.addChild(text)
        entity.addChild(label)
        entity.isEnabled = false
    }

    // MARK: Update

    /// Shows the callout for the next turn inside `calloutMeters`. Hides it after the passenger passes the turn.
    func update(progress: Double, cameraPosition: SIMD3<Float>, time: TimeInterval) {
        guard let index = turns.firstIndex(where: { $0.distanceAlong > progress }),
              turns[index].distanceAlong - progress <= Self.calloutMeters else {
            entity.isEnabled = false
            activeIndex = nil
            return
        }
        if index != activeIndex { activate(index) }
        entity.isEnabled = true
        refreshText(turn: turns[index], distance: turns[index].distanceAlong - progress, time: time)
        faceCamera(at: cameraPosition)
    }

    private func activate(_ index: Int) {
        activeIndex = index
        arrow?.removeFromParent()
        let turn = turns[index]
        let offset = GeoARTransform.enuOffset(of: turn.coordinate, from: routeAnchor)
        let base = SIMD3(Float(offset.x), 0.02, Float(-offset.y))
        let exit = path.sample(at: min(path.length, turn.distanceAlong + 1.5))?.direction ?? SIMD2(0, 1)
        let arrow = makeArrow(for: turn)
        arrow.position = base
        arrow.orientation = simd_quatf(angle: WalkARGuidanceScene.facingAngle(of: exit), axis: SIMD3(0, 1, 0))
        entity.addChild(arrow)
        self.arrow = arrow
        label.position = base + SIMD3(0, Self.labelHeightMeters, 0)
        shownText = ""
        lastTextTime = -.infinity
    }

    // MARK: Label

    private func refreshText(turn: WalkTurn, distance: Double, time: TimeInterval) {
        guard time - lastTextTime >= Self.textIntervalSeconds else { return }
        let next = "\(turn.actionTitle) · \(WalkARDecision.roundedText(distance))"
        lastTextTime = time
        guard next != shownText else { return }
        shownText = next
        let mesh = MeshResource.generateText(next, extrusionDepth: 0.005,
                                             font: .systemFont(ofSize: 0.14, weight: .semibold),
                                             containerFrame: .zero, alignment: .center,
                                             lineBreakMode: .byWordWrapping)
        let bounds = mesh.bounds
        text.model?.mesh = mesh
        text.position = SIMD3(-bounds.center.x, -bounds.center.y, 0.01)
        plate.model?.mesh = .generatePlane(width: bounds.extents.x + 0.14, height: bounds.extents.y + 0.12)
    }

    /// Turns the label about +Y toward the camera and grows it with distance so it stays readable.
    private func faceCamera(at camera: SIMD3<Float>) {
        let toCamera = camera - label.position(relativeTo: nil)
        let angle = atan2(toCamera.x, toCamera.z)
        label.setOrientation(simd_quatf(angle: angle, axis: SIMD3(0, 1, 0)), relativeTo: nil)
        label.scale = SIMD3(repeating: min(8, max(1, simd_length(toCamera) / 4)))
    }

    // MARK: Arrow

    /// A floor arrow with its tip at the turn point and its head along local -Z (the exit direction).
    /// The tail runs back along the incoming path. A U-turn draws two parallel legs.
    private func makeArrow(for turn: WalkTurn) -> Entity {
        let arrow = Entity()
        let length = Self.exitLengthMeters
        arrow.addChild(bar(from: .zero, to: SIMD3(0, 0, -length)))
        let head = WalkARGuidanceScene.makeChevron(scale: 1.6, mesh: headMesh, material: material)
        head.position = SIMD3(0, 0, -length)
        arrow.addChild(head)
        if turn.kind == .uTurn {
            let x: Float = turn.side == .right ? 0.5 : -0.5
            arrow.addChild(bar(from: .zero, to: SIMD3(x, 0, 0)))
            arrow.addChild(bar(from: SIMD3(x, 0, 0), to: SIMD3(x, 0, -length)))
        } else {
            let change = Float(turn.bearingChange * .pi / 180)
            arrow.addChild(bar(from: .zero, to: SIMD3(sin(change), 0, cos(change)) * 1.4))
        }
        return arrow
    }

    private func bar(from start: SIMD3<Float>, to end: SIMD3<Float>) -> ModelEntity {
        let delta = end - start
        let bar = ModelEntity(mesh: barMesh, materials: [material])
        bar.scale = SIMD3(1, 1, simd_length(delta))
        bar.position = (start + end) / 2
        bar.orientation = simd_quatf(angle: atan2(delta.x, delta.z), axis: SIMD3(0, 1, 0))
        return bar
    }
}
