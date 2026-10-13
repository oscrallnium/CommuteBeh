//
//  CommuteActivityAttributes.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import ActivityKit
import Foundation

/// Data of the commute Live Activity. The app and the GoraLiveActivity extension both compile this file.
/// Static values stay fixed for the whole commute. `ContentState` changes on each update.
nonisolated struct CommuteActivityAttributes: ActivityAttributes {

    /// One leg of the route. `weight` is the planned minutes of the leg and sets its width on the bar.
    nonisolated struct Segment: Codable, Hashable {
        var isWalk: Bool
        var weight: Double
    }

    /// A station name under the bar. `position` runs from 0 (start) to 1 (end) along the bar.
    nonisolated struct BoundaryLabel: Codable, Hashable {
        var position: Double
        var text: String
    }

    nonisolated enum Phase: String, Codable, Hashable {
        case live
        case waiting
        case arrived
    }

    nonisolated struct ContentState: Codable, Hashable {
        var phase: Phase
        /// Route progress from 0 to 1, weighted by planned minutes.
        var progress: Double
        var eta: Date
        var lastFixAt: Date
        var actionText: String
        /// Line name for a ride leg, or the transfer label while the passenger waits.
        var legLabel: String
        var stopsLeft: Int
        var nextLineName: String?
        var legIndex: Int
    }

    var segments: [Segment]
    var boundaryLabels: [BoundaryLabel]
    var destinationName: String
}
