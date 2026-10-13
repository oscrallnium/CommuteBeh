//
//  WalkARScreenGuide.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import Foundation

/// What the screen-space chevron shows: a direction and a line of text.
struct WalkARScreenGuide: Equatable {
    enum Placement: Equatable {
        /// Large, at the screen centre. Shown while the world-locked guidance is hidden.
        case center
        /// Small, pinned to the screen edge. Shown while the target is out of view or far away.
        case edge
    }

    var placement: Placement
    /// Radians, clockwise from the top of the screen.
    var angle: Double
    var title: String
}

/// Low-pass filter for an angle. It follows the shortest way around the circle.
/// The output stays continuous and is not wrapped, so an animation never spins the long way.
struct WalkARAngleSmoother {
    static let timeConstantSeconds = 0.25
    private var value: Double?

    mutating func add(_ target: Double, dt: Double) -> Double {
        guard let current = value else {
            value = target
            return target
        }
        let gain = 1 - exp(-max(0, dt) / Self.timeConstantSeconds)
        let next = current + GeoARTransform.normalized(target - current) * gain
        value = next
        return next
    }

    mutating func reset() {
        value = nil
    }
}

/// The next place where the passenger must act: the next turn, or the destination.
struct WalkARDecision: Equatable {
    let coordinate: Coordinates
    let distanceAlong: Double
    let turn: WalkTurn?

    /// The first turn after `progress`. Falls back to the end of the path.
    static func next(after progress: Double, turns: [WalkTurn], path: PolylinePath) -> WalkARDecision? {
        if let turn = turns.first(where: { $0.distanceAlong > progress }) {
            return WalkARDecision(coordinate: turn.coordinate, distanceAlong: turn.distanceAlong, turn: turn)
        }
        guard let end = path.coordinates.last else { return nil }
        return WalkARDecision(coordinate: end, distanceAlong: path.length, turn: nil)
    }

    /// Distance rounded to 5 m, such as "40 m".
    static func roundedText(_ distance: Double) -> String {
        WalkARHUD.format(meters: (max(0, distance) / 5).rounded() * 5)
    }

    /// "Turn right in 40 m" or "Straight ahead · 60 m". Under 5 m the distance drops out.
    func directionalText(distance: Double) -> String {
        let isNear = (distance / 5).rounded() < 1
        let amount = Self.roundedText(distance)
        guard let turn else { return isNear ? "Straight ahead" : "Straight ahead · \(amount)" }
        return isNear ? "\(turn.actionTitle) ahead" : "\(turn.actionTitle) in \(amount)"
    }
}

extension WalkTurn {
    /// "Turn left", "Bear right", or "Make a U-turn".
    var actionTitle: String {
        let phrase = WalkARViewModel.actionPhrase(for: self)
        return phrase.prefix(1).uppercased() + phrase.dropFirst()
    }
}
