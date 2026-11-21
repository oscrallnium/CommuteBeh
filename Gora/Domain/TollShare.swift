//
//  TollShare.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/20/26.
//

import Foundation

/// The rider's share of the expressway toll on one ride leg.
nonisolated enum TollShare {
    /// The toll share rounds to the nearest ₱0.25.
    static let roundingStep: Double = 0.25

    /// Sums the toll of each closed segment, divides it by the load factor, and rounds it.
    /// A missing load factor, a missing fare pair, or an open segment at the end adds nothing.
    static func amount(edges: [TransitEdge], tollFares: [String: [String: Double]],
                       loadFactor: Int?) -> Double {
        guard let loadFactor, loadFactor > 0 else { return 0 }
        let toll = segments(in: edges).reduce(0.0) { sum, pair in
            sum + (tollFares[pair.entry]?[pair.exit] ?? 0)
        }
        guard toll > 0 else { return 0 }
        return (toll / Double(loadFactor) / roundingStep).rounded() * roundingStep
    }

    /// Closed segments in edge order. An edge with both plazas closes the open segment first.
    /// With no open segment, it opens and closes one segment on the same edge.
    private static func segments(in edges: [TransitEdge]) -> [(entry: String, exit: String)] {
        var closed: [(entry: String, exit: String)] = []
        var openEntry: String?
        for edge in edges {
            let entry = edge.tollEntryPlaza
            if let exit = edge.tollExitPlaza {
                if let open = openEntry {
                    closed.append((open, exit))
                    openEntry = nil
                } else if let entry {
                    closed.append((entry, exit))
                    continue
                }
            }
            if let entry { openEntry = entry }
        }
        return closed
    }
}
