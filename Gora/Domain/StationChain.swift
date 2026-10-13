//
//  StationChain.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/9/26.
//

import Foundation

/// Reads the stop chain and stop order of a station.
///
/// An id ends in `_STOP<n>` (legacy) or `_S<n>` (new). The part before the suffix is the chain.
/// Order comes from `Station.sequence`, and only a legacy id number stands in when it is absent.
nonisolated enum StationChain {

    private static let suffixPattern = #"_(?:STOP|S)(\d+)$"#
    private static let newSuffixPattern = #"_S(\d+)$"#
    private static let legacySuffixPattern = #"_STOP(\d+)$"#

    /// `"JEEP_NB_S4"` and `"JEEP_NB_STOP4"` both give `"JEEP_NB"`. Nil for a hand-authored id.
    static func prefix(of id: String) -> String? {
        guard let range = id.range(of: suffixPattern, options: .regularExpression) else { return nil }
        return String(id[..<range.lowerBound])
    }

    /// The chain key of a station: its id prefix, or its line for a hand-authored id.
    static func key(of station: Station) -> String {
        prefix(of: station.id) ?? station.line
    }

    /// The number in either suffix form. A name, not a position, in a new id.
    static func number(in id: String) -> Int? {
        number(in: id, pattern: suffixPattern)
    }

    /// Stations in travel order: `sequence`, then the legacy `_STOP<n>` number, then input order.
    /// A station with neither value sorts last.
    static func ordered(_ stations: [Station]) -> [Station] {
        stations.enumerated()
            .sorted { a, b in
                let ka = position(of: a.element)
                let kb = position(of: b.element)
                return ka == kb ? a.offset < b.offset : ka < kb
            }
            .map(\.element)
    }

    /// The stations grouped by chain key, sorted by key, each group in travel order.
    static func groups(of stations: [Station]) -> [(prefix: String, stations: [Station])] {
        Dictionary(grouping: stations, by: key(of:))
            .map { (prefix: $0.key, stations: ordered($0.value)) }
            .sorted { $0.prefix < $1.prefix }
    }

    /// `<chain>_S<n>`. `n` is one above the larger of `lastStopNumber` and the highest `_S<n>`
    /// among all station ids of the line, so numbers stay unique across the chains of a line.
    static func nextStopID(chain: String, lineStationIDs: [String], lastStopNumber: Int?) -> String {
        let highestExisting = lineStationIDs
            .compactMap { number(in: $0, pattern: newSuffixPattern) }
            .max() ?? 0
        return "\(chain)_S\(max(lastStopNumber ?? 0, highestExisting) + 1)"
    }

    private static func position(of station: Station) -> Int {
        station.sequence ?? number(in: station.id, pattern: legacySuffixPattern) ?? .max
    }

    private static func number(in id: String, pattern: String) -> Int? {
        guard let range = id.range(of: pattern, options: .regularExpression) else { return nil }
        return Int(id[range].drop { !$0.isNumber })
    }
}
