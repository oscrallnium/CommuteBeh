//
//  SearchSuggestionDropdown.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/8/26.
//

import CoreLocation
import MapKit
import SwiftUI

/// The search results under the search card, in a Liquid Glass list that grows from the card.
/// Each row shows a category symbol in a colored circle, the name with the typed letters in
/// semibold, and the distance and area. A tap plays a light haptic.
struct SearchSuggestionDropdown: View {
    let suggestions: [LocationSuggestion]
    /// The field text. A station name shows these letters in semibold.
    let query: String
    let userLocation: Coordinates?
    let lineName: (String) -> String
    let onSelect: (LocationSuggestion) -> Void

    @State private var tapCount = 0

    var body: some View {
        let rows = Array(suggestions.prefix(Layout.rowLimit))
        // The list scrolls only when the rows do not fit above the keyboard.
        ViewThatFits(in: .vertical) {
            list(rows)
            ScrollView { list(rows) }
                .scrollBounceBehavior(.basedOnSize)
        }
        .resultsSurface()
        .sensoryFeedback(.impact(weight: .light), trigger: tapCount)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.resultsLabel(rows.count))
    }

    private func list(_ rows: [LocationSuggestion]) -> some View {
        VStack(spacing: 0) {
            // Identity must be content-based, never positional. The completer re-merges results
            // mid-interaction, so a tap resolved by screen slot can confirm the wrong suggestion.
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, suggestion in
                Button {
                    tapCount += 1
                    onSelect(suggestion)
                } label: {
                    SearchResultRow(
                        content: content(for: suggestion),
                        showsSeparator: index > 0
                    )
                }
                .buttonStyle(SearchResultButtonStyle())
            }
        }
        .padding(.vertical, Layout.listVerticalPadding)
    }

    private func content(for suggestion: LocationSuggestion) -> SearchResultRow.Content {
        switch suggestion {
        case .station(let station):
            let mode = TransportMode(rawValue: station.type)
            let range = query.isEmpty ? nil : station.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
            let details = [distanceText(to: station.coordinates), lineLabel(for: station, mode: mode)].compactMap { $0 }
            return .init(
                icon: (mode ?? .walk).iconImage,
                title: Self.highlighted(station.name, ranges: range.map { [$0] } ?? []),
                subtitle: details.joined(separator: " · ")
            )
        case .address(let completion):
            let ranges = completion.titleHighlightRanges.compactMap { Range($0.rangeValue, in: completion.title) }
            return .init(
                icon: Image(systemName: Symbol.place),
                title: Self.highlighted(completion.title, ranges: ranges),
                subtitle: completion.subtitle
            )
        }
    }

    /// The distance from the passenger, or nil when the location is unknown.
    private func distanceText(to coordinates: Coordinates) -> String? {
        guard let userLocation else { return nil }
        let meters = CLLocation(latitude: userLocation.lat, longitude: userLocation.lng)
            .distance(from: CLLocation(latitude: coordinates.lat, longitude: coordinates.lng))
        return Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    /// The graph display name of the line. Without one, a key that has no underscore passes
    /// through, and an internal key shows the mode name.
    private func lineLabel(for station: Station, mode: TransportMode?) -> String {
        let name = lineName(station.line)
        guard name == station.line else { return name }
        guard station.line.contains("_") else { return station.line }
        return mode?.rawValue.capitalized ?? station.line
    }

    /// The typed letters show in semibold, as in Apple Maps. The size comes from the outer font.
    static func highlighted(_ title: String, ranges: [Range<String.Index>]) -> Text {
        var result = Text(verbatim: "")
        var cursor = title.startIndex
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.lowerBound >= cursor {
            let plain = Text(verbatim: String(title[cursor..<range.lowerBound]))
            let match = Text(verbatim: String(title[range])).fontWeight(.semibold)
            result = Text("\(result)\(plain)\(match)")
            cursor = range.upperBound
        }
        let tail = Text(verbatim: String(title[cursor...]))
        return Text("\(result)\(tail)")
    }

    /// The list fades in and settles from above at 97 % scale. Reduce Motion fades only.
    static func transition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity
            .combined(with: .scale(scale: Layout.enterScale, anchor: .top))
            .combined(with: .offset(y: Layout.enterOffset))
    }

    /// Shown when the typed text matches nothing. The text states the fix and does not blame.
    static var noResults: some View {
        VStack(spacing: Layout.emptySpacing) {
            Image(systemName: Symbol.noResults)
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.bottom, Layout.emptyIconGap)
                .accessibilityHidden(true)
            Text(Strings.noResultsTitle)
                .typeScale(.rowTitleLarge)
            Text(Strings.noResultsMessage)
                .typeScale(.subtitle)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Layout.emptyHorizontalPadding)
        .padding(.vertical, Layout.emptyVerticalPadding)
        .resultsSurface()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Row

/// One result: a 28 pt symbol circle, the name in type-scale Body, and the details in Subtitle.
/// The circle uses the destination marker colors: an Onyx fill and a Canvas symbol.
/// The separator starts at the text, like an inset list row.
private struct SearchResultRow: View {
    struct Content {
        let icon: Image
        let title: Text
        let subtitle: String
    }

    let content: Content
    let showsSeparator: Bool

    @ScaledMetric(relativeTo: .subheadline) private var circleSize: CGFloat = Layout.circleSize
    @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = Layout.iconSize

    var body: some View {
        HStack(alignment: .center, spacing: Layout.rowSpacing) {
            content.icon
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(Color.canvas)
                .frame(width: circleSize, height: circleSize)
                .background(Color.onyx, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Layout.textSpacing) {
                content.title
                    .typeScale(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(Layout.titleLines)
                if !content.subtitle.isEmpty {
                    Text(content.subtitle)
                        .typeScale(.subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(Layout.subtitleLines)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Layout.rowMinHeight, alignment: .leading)
            .padding(.vertical, Layout.textVerticalPadding)
            .padding(.trailing, Layout.rowHorizontalPadding)
            .overlay(alignment: .top) {
                if showsSeparator {
                    Rectangle()
                        .fill(Color.primary.opacity(Layout.separatorOpacity))
                        .frame(height: Layout.separatorWidth)
                }
            }
        }
        .padding(.leading, Layout.rowHorizontalPadding)
        .contentShape(.rect)
    }
}

/// A pressed row shows a light fill, like a list row.
private struct SearchResultButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? Layout.pressedOpacity : 0))
    }
}

private extension View {
    /// The glass container of the results, with the same material as the search card.
    func resultsSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
        return self
            .clipShape(shape)
            .goraGlass(DesignTokens.Materials.cardGlass, in: shape)
    }
}

// MARK: - Constants

private enum Layout {
    static let rowLimit = 8
    static let cornerRadius: CGFloat = 24
    static let listVerticalPadding: CGFloat = 4
    static let circleSize: CGFloat = 28
    static let iconSize: CGFloat = 14
    static let rowSpacing: CGFloat = 12
    static let rowHorizontalPadding: CGFloat = 16
    static let rowMinHeight: CGFloat = 34
    static let textSpacing: CGFloat = 2
    static let textVerticalPadding: CGFloat = 10
    static let titleLines = 2
    static let subtitleLines = 2
    static let separatorOpacity: Double = 0.12
    static let separatorWidth: CGFloat = 0.5
    static let pressedOpacity: Double = 0.07
    static let enterScale: CGFloat = 0.97
    static let enterOffset: CGFloat = -10
    static let emptySpacing: CGFloat = 4
    static let emptyIconGap: CGFloat = 8
    static let emptyHorizontalPadding: CGFloat = 24
    static let emptyVerticalPadding: CGFloat = 32
}

private enum Symbol {
    static let place = "mappin"
    static let noResults = "magnifyingglass"
}

private enum Strings {
    static let noResultsTitle: LocalizedStringKey = "No Results"
    static let noResultsMessage: LocalizedStringKey = "Check the spelling or try a new search."

    static func resultsLabel(_ count: Int) -> String {
        String(localized: "\(count) results")
    }
}
