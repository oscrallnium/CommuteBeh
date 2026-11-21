//
//  RouteLineOverlay.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/3/26.
//

import SwiftUI
import MapKit

// MARK: - Overlay

/// A route polyline that carries the stroke and reveal span of its descriptor. The
/// coordinates never change after creation, so a new geometry needs a new overlay.
final class RouteLineOverlay: MKPolyline {
    private(set) var lineID = ""
    private(set) var signature = CoordinateSignature([])
    var stroke = LineStroke(color: .clear, style: StrokeStyle())
    var reveal: RevealSpan?

    static func make(_ descriptor: RouteLineDescriptor) -> RouteLineOverlay {
        let overlay = RouteLineOverlay(coordinates: descriptor.coordinates, count: descriptor.coordinates.count)
        overlay.lineID = descriptor.id
        overlay.signature = descriptor.signature
        overlay.stroke = descriptor.stroke
        overlay.reveal = descriptor.reveal
        return overlay
    }
}

// MARK: - Resolved stroke

/// A stroke with its color resolved for one appearance. Equal values draw the same pixels.
struct ResolvedStroke: Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
    let width: CGFloat
    let dash: [CGFloat]
    let cap: CGLineCap
    let join: CGLineJoin

    init(_ stroke: LineStroke, traits: UITraitCollection) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        Self.uiColor(stroke.color, traits: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
        width = stroke.style.lineWidth
        dash = stroke.style.dash
        cap = stroke.style.lineCap
        join = stroke.style.lineJoin
    }

    func withAlpha(_ alpha: CGFloat) -> ResolvedStroke {
        ResolvedStroke(copying: self, alpha: alpha, width: width)
    }

    var color: UIColor { UIColor(red: red, green: green, blue: blue, alpha: alpha) }

    private init(copying other: ResolvedStroke, alpha: CGFloat, width: CGFloat) {
        red = other.red; green = other.green; blue = other.blue
        self.alpha = alpha
        self.width = width
        dash = other.dash; cap = other.cap; join = other.join
    }

    /// True when only the opacity and the width differ, which is the only change a tween covers.
    func isTweenable(to other: ResolvedStroke) -> Bool {
        red == other.red && green == other.green && blue == other.blue
            && dash == other.dash && cap == other.cap && join == other.join
    }

    /// The stroke `progress` of the way to `target`, from 0 to 1. Reduce Motion keeps the width of `target`.
    func blended(to target: ResolvedStroke, by progress: Double, snapsWidth: Bool) -> ResolvedStroke {
        let amount = CGFloat(progress)
        let blendedWidth = snapsWidth ? target.width : width + (target.width - width) * amount
        return ResolvedStroke(copying: target, alpha: alpha + (target.alpha - alpha) * amount, width: blendedWidth)
    }

    /// Resolves `color` for the appearance in `traits`, so dynamic colors follow the map's light or dark mode.
    static func uiColor(_ color: Color, traits: UITraitCollection) -> UIColor {
        var environment = EnvironmentValues()
        environment.colorScheme = traits.userInterfaceStyle == .dark ? .dark : .light
        let resolved = color.resolve(in: environment)
        return UIColor(red: CGFloat(resolved.red), green: CGFloat(resolved.green),
                       blue: CGFloat(resolved.blue), alpha: CGFloat(resolved.opacity))
    }
}

// MARK: - Renderer

/// A plain `MKPolylineRenderer` that MapKit draws as a GPU vector, so the width stays fixed in screen points.
/// Any drawing override makes MapKit draw tiles instead. The draw-on sets `strokeEnd` and never builds the overlay again.
final class RouteLineRenderer: MKPolylineRenderer {
    private enum Tween {
        static let frameInterval: Duration = .milliseconds(16)
    }

    /// The stroke the renderer aims at.
    private var applied: ResolvedStroke?
    /// The stroke on the renderer now. It trails `applied` while a tween runs.
    private var shown: ResolvedStroke?
    private var tweenTask: Task<Void, Never>?

    /// Applies `stroke`. A `tweenDuration` eases a change of opacity or width over that many seconds.
    /// Returns true when a value changed at once.
    func apply(_ stroke: ResolvedStroke, tweenDuration: TimeInterval? = nil) -> Bool {
        guard applied != stroke else { return false }
        applied = stroke
        tweenTask?.cancel()
        tweenTask = nil
        guard let tweenDuration, let from = shown, from.isTweenable(to: stroke) else {
            show(stroke)
            return true
        }
        tweenTask = Task { @MainActor [weak self] in
            let start = ContinuousClock.now
            while !Task.isCancelled {
                let progress = min(1, start.duration(to: .now) / .seconds(tweenDuration))
                let eased = progress * progress * (3 - 2 * progress)
                self?.show(from.blended(to: stroke, by: eased, snapsWidth: UIAccessibility.isReduceMotionEnabled))
                self?.setNeedsDisplay()
                if progress >= 1 { return }
                try? await Task.sleep(for: Tween.frameInterval)
            }
        }
        return false
    }

    /// Starts fully transparent and eases to `stroke` over `duration` seconds.
    func fadeIn(_ stroke: ResolvedStroke, duration: TimeInterval) {
        applied = nil
        show(stroke.withAlpha(0))
        _ = apply(stroke, tweenDuration: duration)
    }

    private func show(_ stroke: ResolvedStroke) {
        shown = stroke
        strokeColor = stroke.color
        lineWidth = stroke.width
        lineCap = stroke.cap
        lineJoin = stroke.join
        lineDashPattern = stroke.dash.isEmpty ? nil : stroke.dash.map { NSNumber(value: Double($0)) }
    }

    /// Draws the overlay up to the share of its path that `reveal` allows at `fraction`.
    /// A zero share hides the renderer, so the round cap of an undrawn line shows no dot.
    /// Returns true when a value changed.
    func setReveal(_ reveal: RevealSpan?, at fraction: Double) -> Bool {
        let end = CGFloat(reveal?.strokeEnd(at: fraction) ?? 1)
        let visibility: CGFloat = end > 0 ? 1 : 0
        guard strokeEnd != end || alpha != visibility else { return false }
        strokeEnd = end
        alpha = visibility
        return true
    }
}
