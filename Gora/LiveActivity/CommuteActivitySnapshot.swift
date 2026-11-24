//
//  CommuteActivitySnapshot.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import Foundation
import SwiftUI
import UIKit

/// Builds the Live Activity data from a route and the progress engine. Pure functions, no ActivityKit calls.
/// `lineName` maps a line key to its display name from the transit graph.
enum CommuteActivitySnapshot {
    typealias Attributes = CommuteActivityAttributes
    typealias State = CommuteActivityAttributes.ContentState

    /// Seconds without a GPS fix before the system marks the activity stale.
    static let staleAfterSeconds: TimeInterval = 180
    /// Shortest gap between two updates that only change progress or ETA.
    private static let minUpdateGap: TimeInterval = 15
    private static let maxUpdateGap: TimeInterval = 60
    private static let progressStep = 0.01
    private static let etaStepSeconds: TimeInterval = 60

    /// The start label shows `originName`, or the first station's full name when `originName` is empty.
    static func attributes(result: RouteResult, originName: String, destinationName: String,
                           legColor: (RouteLeg) -> Color) -> Attributes {
        let weights = result.legs.map { max($0.effectiveTravelMinutes, 0) }
        let startName = originName.isEmpty ? (result.legs.first?.fromStation.name ?? "") : originName
        return Attributes(
            segments: zip(result.legs, weights).map { leg, weight in
                let color = legColor(leg)
                let dark = rgb(color, style: .dark)
                return .init(isWalk: isWalkLike(leg), weight: weight,
                             colorLight: rgb(color, style: .light), colorDark: dark,
                             markerInkDark: markerInk(onFill: dark))
            },
            boundaryLabels: [.init(position: 0, text: startName), .init(position: 1, text: destinationName)],
            destinationName: destinationName)
    }

    /// 0xFFFFFF or 0x000000, whichever has the higher WCAG contrast on the 0xRRGGBB fill.
    private static func markerInk(onFill fill: UInt32) -> UInt32 {
        func channel(_ shift: UInt32) -> Double { Double((fill >> shift) & 0xFF) / 255 }
        let luminance = Color.relativeLuminance(red: channel(16), green: channel(8), blue: channel(0))
        return Color.inkLuminance(onFillLuminance: luminance) == .white ? 0xFFFFFF : 0x000000
    }

    static func state(result: RouteResult, engine: CommuteProgressEngine, destinationName: String,
                      lastFixAt: Date, now: Date, lineName: (String) -> String) -> State {
        let legs = result.legs
        let index = min(engine.currentLegIndex, max(legs.count - 1, 0))
        let leg = legs[index]
        let isWaiting = isTransferWait(legs: legs, index: index)
        let nextRide = legs.dropFirst(index + 1).first { !isWalkLike($0) }
        return State(
            phase: isWaiting ? .waiting : .live,
            progress: engine.progressFraction,
            eta: now.addingTimeInterval(engine.plannedSecondsRemaining),
            lastFixAt: lastFixAt,
            actionText: leg.instruction,
            legLabel: isWaiting ? "Transfer" : (isWalkLike(leg) ? "Walk" : lineName(leg.line)),
            stopsLeft: stopsLeft(legs: legs, index: index, fraction: engine.fractionAlongCurrentLeg),
            nextLineName: nextRide.map { lineName($0.line) },
            legIndex: index)
    }

    static func arrivedState(from last: State, destinationName: String, now: Date) -> State {
        var state = last
        state.phase = .arrived
        state.progress = 1
        state.eta = now
        state.actionText = "Arrived at \(destinationName)"
        state.stopsLeft = 0
        return state
    }

    /// True when `new` differs from `last` enough to justify an update at `now`.
    static func shouldSend(_ new: State, last: State?, lastSentAt: Date?, now: Date) -> Bool {
        guard let last, let lastSentAt else { return true }
        if new.legIndex != last.legIndex || new.actionText != last.actionText || new.phase != last.phase {
            return true
        }
        let gap = now.timeIntervalSince(lastSentAt)
        guard gap >= minUpdateGap else { return false }
        return abs(new.progress - last.progress) >= progressStep
            || abs(new.eta.timeIntervalSince(last.eta)) >= etaStepSeconds
            || gap >= maxUpdateGap
    }

    /// The 0xRRGGBB value of `color` when resolved in the given interface style.
    private static func rgb(_ color: Color, style: UIUserInterfaceStyle) -> UInt32 {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: nil)
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }

    private static func isWalkLike(_ leg: RouteLeg) -> Bool {
        leg.mode == .walk || leg.line == "INTERCHANGE"
    }

    private static func isTransferWait(legs: [RouteLeg], index: Int) -> Bool {
        guard isWalkLike(legs[index]), index > 0, index < legs.count - 1 else { return false }
        return !isWalkLike(legs[index - 1]) && !isWalkLike(legs[index + 1])
    }

    private static func stopsLeft(legs: [RouteLeg], index: Int, fraction: Double) -> Int {
        let later = legs.dropFirst(index + 1).filter { !isWalkLike($0) }.reduce(0) { $0 + $1.stopCount }
        guard !isWalkLike(legs[index]) else { return later }
        return later + Int(((1 - fraction) * Double(legs[index].stopCount)).rounded(.up))
    }
}
