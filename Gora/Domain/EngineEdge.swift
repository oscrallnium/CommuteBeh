//
//  EngineEdge.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/15/26.
//

import Foundation
import os

/// An edge plus the values the A* loop would otherwise recompute on every relaxation.
nonisolated struct EngineEdge {
    let edge: TransitEdge
    let payments: Set<String>
    let mode: TransportMode?
    /// Index into the engine's mode list, used to read the per-request peak multiplier.
    let modeSlot: Int
    let isAlwaysAllowed: Bool
    let isAccessWalk: Bool
    let isFareFree: Bool
    let isWalkLike: Bool
    let isTrain: Bool

    init(_ edge: TransitEdge, modeSlot: Int, alwaysAllowedModes: Set<String>) {
        self.edge = edge
        self.modeSlot = modeSlot
        payments = Set(edge.acceptedPayments)
        mode = TransportMode(rawValue: edge.mode)
        isAlwaysAllowed = alwaysAllowedModes.contains(edge.mode)
        isAccessWalk = edge.line == "ACCESS_WALK"
        isFareFree = edge.line == "INTERCHANGE" || isAccessWalk
        isWalkLike = isAlwaysAllowed || isFareFree
        isTrain = mode == .train
    }
}

/// The peak windows of a graph with their times parsed once.
nonisolated struct PeakHourTable {
    private struct Window {
        let start: Int
        let end: Int
        let multiplier: Double
        let modes: Set<String>

        init(_ peak: PeakHourMultiplier) {
            start = Self.minutes(peak.timeRange.start)
            end = Self.minutes(peak.timeRange.close)
            multiplier = peak.travelTimeMultiplier
            modes = Set(peak.modes)
        }

        private static func minutes(_ text: String) -> Int {
            let parts = text.split(separator: ":").compactMap { Int($0) }
            return (parts.first ?? 0) * 60 + (parts.last ?? 0)
        }
    }

    private let windows: [Window]

    init(_ peaks: TransitGraph.PeakHours) {
        windows = [peaks.morningPeak, peaks.eveningPeak, peaks.trainPeak].map(Window.init)
    }

    /// The largest multiplier of a window that holds `minutes` and lists `mode`, or 1.
    func multiplier(forMode mode: String, atMinutes minutes: Int) -> Double {
        var result = 1.0
        for window in windows where minutes >= window.start && minutes <= window.end {
            if window.modes.contains(mode) { result = max(result, window.multiplier) }
        }
        return result
    }
}

/// A station's operating window in minutes since midnight.
nonisolated struct OpenWindow {
    let open: Int
    let close: Int

    init(_ hours: Station.OperatingHours) {
        open = Self.minutes(hours.open)
        close = Self.minutes(hours.close)
    }

    /// A window with `close <= open` spans midnight and is always open.
    func contains(arrivalMinutes: Int) -> Bool {
        if close <= open { return true }
        return arrivalMinutes >= open && arrivalMinutes < close
    }

    private static func minutes(_ hhmm: String) -> Int {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return 0 }
        return parts[0] * 60 + parts[1]
    }
}

/// Signpost intervals that Instruments shows under the "Engine" category.
nonisolated enum EngineSignpost {
    static let signposter = OSSignposter(subsystem: "com.banaueinc.gora", category: "Engine")
}
