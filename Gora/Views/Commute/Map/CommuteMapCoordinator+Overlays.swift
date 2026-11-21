//
//  CommuteMapCoordinator+Overlays.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/3/26.
//

import SwiftUI
import MapKit

// MARK: - Overlay diff
// Overlays keep the scene order: the list in `MKMapView.overlays` matches `scene.lines`,
// then the accuracy circle. A changed geometry swaps its overlay in place, so the order holds.

extension CommuteMapCoordinator {

    func applyOverlays(_ scene: CommuteMapScene, in mapView: MKMapView) {
        if isSwitchingGuidance { finishFadeOut(in: mapView) }
        var next: [String: RouteLineOverlay] = [:]
        let lines: [MKOverlay] = scene.lines.map { descriptor in
            let overlay = overlay(for: descriptor, in: mapView)
            next[descriptor.id] = overlay
            return overlay
        }
        let leaving = lineOverlays.filter { next[$0.key] == nil }.map(\.value)
        var stale: [MKOverlay] = isSwitchingGuidance ? [] : leaving
        lineOverlays = next
        if isSwitchingGuidance { startFadeOut(leaving, in: mapView) }
        var desired: [MKOverlay] = fadingOutOverlays + lines

        if let circle = circleOverlay(for: scene.circle, in: mapView) {
            desired.append(circle)
        } else if let old = circleOverlay {
            stale.append(old)
            circleOverlay = nil
        }
        discard(stale, in: mapView)
        reconcileOrder(desired, in: mapView)
        restyleOverlays(in: mapView)
        isSwitchingGuidance = false
    }

    // MARK: Guidance switch

    /// Keeps the lines that leave on the map under the new lines and fades them out.
    /// They leave the map after `locationStateDuration`.
    private func startFadeOut(_ leaving: [RouteLineOverlay], in mapView: MKMapView) {
        fadingOutOverlays = leaving
        let traits = mapView.traitCollection
        for overlay in leaving {
            guard let renderer = renderers[ObjectIdentifier(overlay)] else { continue }
            _ = renderer.apply(ResolvedStroke(overlay.stroke, traits: traits).withAlpha(0),
                               tweenDuration: DesignTokens.Motion.locationStateDuration)
        }
        guard !leaving.isEmpty else { return }
        Task { [weak self, weak mapView] in
            try? await Task.sleep(for: .seconds(DesignTokens.Motion.locationStateDuration))
            guard let self, let mapView, self.fadingOutOverlays.elementsEqual(leaving, by: ===) else { return }
            self.finishFadeOut(in: mapView)
        }
    }

    /// Removes the faded lines from the map.
    private func finishFadeOut(in mapView: MKMapView) {
        let done = fadingOutOverlays
        fadingOutOverlays = []
        discard(done, in: mapView)
    }

    /// The overlay for `descriptor`. Reuses the current one while its geometry holds.
    private func overlay(for descriptor: RouteLineDescriptor, in mapView: MKMapView) -> RouteLineOverlay {
        guard let current = lineOverlays[descriptor.id] else { return newOverlay(descriptor) }
        guard current.signature != descriptor.signature else {
            current.stroke = descriptor.stroke
            current.reveal = descriptor.reveal
            return current
        }
        let replacement = newOverlay(descriptor)
        replaceOverlay(current, with: replacement, in: mapView)
        renderers[ObjectIdentifier(current)] = nil
        return replacement
    }

    /// A new overlay. It fades in while the guidance switches.
    private func newOverlay(_ descriptor: RouteLineDescriptor) -> RouteLineOverlay {
        let overlay = RouteLineOverlay.make(descriptor)
        if isSwitchingGuidance { fadingInOverlays.insert(ObjectIdentifier(overlay)) }
        return overlay
    }

    /// The circle for `descriptor`. Returns nil when there is none.
    private func circleOverlay(for descriptor: AccuracyCircleDescriptor?, in mapView: MKMapView) -> MKCircle? {
        circleStyle = descriptor
        guard let descriptor else { return nil }
        if let current = circleOverlay,
           current.coordinate.latitude == descriptor.center.latitude,
           current.coordinate.longitude == descriptor.center.longitude,
           current.radius == descriptor.radius {
            return current
        }
        let replacement = MKCircle(center: descriptor.center, radius: descriptor.radius)
        if let current = circleOverlay { replaceOverlay(current, with: replacement, in: mapView) }
        circleOverlay = replacement
        return replacement
    }

    /// Puts `replacement` where `current` sits. Does nothing when `current` is not on the map.
    private func replaceOverlay(_ current: MKOverlay, with replacement: MKOverlay, in mapView: MKMapView) {
        guard mapView.overlays.contains(where: { $0 === current }) else { return }
        mapView.insertOverlay(replacement, above: current)
        mapView.removeOverlay(current)
    }

    private func discard(_ stale: [MKOverlay], in mapView: MKMapView) {
        guard !stale.isEmpty else { return }
        mapView.removeOverlays(stale)
        for overlay in stale { renderers[ObjectIdentifier(overlay)] = nil }
    }

    /// Removes every overlay from the first one that is out of place, then adds the rest in
    /// order. A renderer survives the move, so the draw state of a moved line holds.
    private func reconcileOrder(_ desired: [MKOverlay], in mapView: MKMapView) {
        let current = mapView.overlays
        var firstMismatch = 0
        while firstMismatch < min(current.count, desired.count),
              current[firstMismatch] === desired[firstMismatch] {
            firstMismatch += 1
        }
        if firstMismatch < current.count {
            mapView.removeOverlays(Array(current[firstMismatch...]))
        }
        if firstMismatch < desired.count {
            mapView.addOverlays(Array(desired[firstMismatch...]), level: .aboveRoads)
        }
    }

    // MARK: Renderers

    func renderer(for overlay: RouteLineOverlay, in mapView: MKMapView) -> RouteLineRenderer {
        let renderer = renderers[ObjectIdentifier(overlay)] ?? makeRenderer(for: overlay)
        renderers[ObjectIdentifier(overlay)] = renderer
        let resolved = ResolvedStroke(overlay.stroke, traits: mapView.traitCollection)
        if fadingInOverlays.remove(ObjectIdentifier(overlay)) != nil {
            renderer.fadeIn(resolved, duration: DesignTokens.Motion.locationStateDuration)
        } else {
            _ = renderer.apply(resolved, tweenDuration: tweenDuration(of: overlay))
        }
        _ = renderer.setReveal(overlay.reveal, at: drawAnimator.fraction)
        return renderer
    }

    private func tweenDuration(of overlay: RouteLineOverlay) -> TimeInterval? {
        overlay.stroke.animatesChange || isSwitchingGuidance ? DesignTokens.Motion.locationStateDuration : nil
    }

    /// A plain `MKPolylineRenderer` subclass with no drawing overrides draws as a GPU vector.
    /// Any drawing override makes MapKit draw tiles, which lag on zoom.
    private func makeRenderer(for overlay: RouteLineOverlay) -> RouteLineRenderer {
        RouteLineRenderer(polyline: overlay)
    }

    /// Applies the stroke and reveal of each overlay to its renderer. A renderer redraws only
    /// when a value changed.
    func restyleOverlays(in mapView: MKMapView) {
        let traits = mapView.traitCollection
        for overlay in lineOverlays.values {
            guard let renderer = renderers[ObjectIdentifier(overlay)] else { continue }
            let restyled = renderer.apply(ResolvedStroke(overlay.stroke, traits: traits),
                                          tweenDuration: tweenDuration(of: overlay))
            let revealed = renderer.setReveal(overlay.reveal, at: drawAnimator.fraction)
            if restyled || revealed { renderer.setNeedsDisplay() }
        }
        if let circleRenderer {
            styleCircle(circleRenderer, traits: traits)
            circleRenderer.setNeedsDisplay()
        }
    }

    func styleCircle(_ renderer: MKCircleRenderer, traits: UITraitCollection) {
        guard let style = circleStyle else { return }
        renderer.fillColor = ResolvedStroke.uiColor(style.fill, traits: traits)
        renderer.strokeColor = ResolvedStroke.uiColor(style.stroke, traits: traits)
        renderer.lineWidth = style.lineWidth
    }

    // MARK: Draw-on

    /// Sets the `strokeEnd` of every route line that has a reveal span. It builds no overlay.
    func applyReveal(_ fraction: Double) {
        for overlay in lineOverlays.values where overlay.reveal != nil {
            guard let renderer = renderers[ObjectIdentifier(overlay)] else { continue }
            if renderer.setReveal(overlay.reveal, at: fraction) { renderer.setNeedsDisplay() }
        }
        revealAnnotations(at: fraction)
    }
}
