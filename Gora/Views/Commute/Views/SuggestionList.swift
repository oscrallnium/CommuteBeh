//
//  SuggestionList.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/10/26.
//

import SwiftUI
import MapKit

// MARK: - Suggestion List

struct SuggestionList: View {
    let suggestions: [LocationSuggestion]
    let lineName: (String) -> String
    let lineColor: (String) -> Color?
    let onSelect: (LocationSuggestion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Identity must be content-based, never positional. The completer re-merges results
            // mid-interaction, so a tap resolved by screen slot can confirm the wrong suggestion.
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button { onSelect(suggestion) } label: {
                    row(for: suggestion)
                }
                .buttonStyle(.plain)
                if index < suggestions.count - 1 {
                    Divider().padding(.leading, 48)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for suggestion: LocationSuggestion) -> some View {
        switch suggestion {
        case .station(let station):
            HStack(spacing: 12) {
                Image(systemName: mode(of: station)?.icon ?? "figure.walk")
                    .foregroundStyle(lineColor(station.line) ?? mode(of: station)?.color ?? Color(.systemGray))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name)
                        .font(DesignTokens.TypeScale.body)
                        .foregroundStyle(.primary)
                    Text(lineLabel(for: station))
                        .font(DesignTokens.TypeScale.meta)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        case .address(let completion):
            HStack(spacing: 12) {
                Image(systemName: "mappin.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(completion.title)
                        .font(DesignTokens.TypeScale.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !completion.subtitle.isEmpty {
                        Text(completion.subtitle)
                            .font(DesignTokens.TypeScale.meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func mode(of station: Station) -> TransportMode? {
        TransportMode(rawValue: station.type)
    }

    // Uses the graph display name of the line. Without one, a key that has no underscore
    // passes through, and an internal key shows the mode name.
    private func lineLabel(for station: Station) -> String {
        let name = lineName(station.line)
        guard name == station.line else { return name }
        guard station.line.contains("_") else { return station.line }
        return mode(of: station)?.rawValue.capitalized ?? station.line
    }
}
