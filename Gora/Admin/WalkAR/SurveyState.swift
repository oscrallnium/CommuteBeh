//
//  SurveyState.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import Foundation

/// How the survey frame is placed. L1 replaces L2 when both are available.
nonisolated enum SurveyState: Sendable {
    case waiting
    case relocalizedL1
    case placedByL2
    case timedOut

    static let relocalizationTimeoutSeconds = 15.0

    /// The state after `elapsed` seconds with no L1 or L2 placement.
    static func whileUnplaced(elapsed: TimeInterval) -> SurveyState {
        elapsed >= relocalizationTimeoutSeconds ? .timedOut : .waiting
    }
}
