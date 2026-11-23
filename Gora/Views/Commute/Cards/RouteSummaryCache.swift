//
//  RouteSummaryCache.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/24/26.
//

import SwiftUI

// MARK: - Summary cache

/// Holds the summary of the shown option. The sheet body runs on every map-panel frame, and
/// building a summary scans every raw step of every leg. It rebuilds only when its inputs change.
final class SummaryCache {
    private struct Key: Equatable {
        let optionID: RouteOption.ID
        let legIDs: [UUID]
        let totalMinutes: Double
        let uses24HourTime: Bool
        let includesOtherModes: Bool
        let graphVersion: String?
    }

    private var entry: (key: Key, summary: RouteCardSummary)?

    func summary(for option: RouteOption, uses24HourTime: Bool, includesOtherModes: Bool,
                 graphVersion: String?, build: () -> RouteCardSummary) -> RouteCardSummary {
        let key = Key(optionID: option.id, legIDs: option.result.legs.map(\.id),
                      totalMinutes: option.result.totalTimeMinutes, uses24HourTime: uses24HourTime,
                      includesOtherModes: includesOtherModes, graphVersion: graphVersion)
        if let entry, entry.key == key { return entry.summary }
        let summary = build()
        entry = (key, summary)
        return summary
    }
}
