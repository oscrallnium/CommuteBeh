//
//  RouteLegList.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/10/26.
//

import SwiftUI
import UIKit

// MARK: - Route Leg List

/// The leg-by-leg breakdown shown inside a card once "See route details" is open.
/// Reads straight from the same `RouteCardSummary` the card already has, so opening
/// details allocates nothing.
struct RouteLegList: View {
    let legRows: [RouteCardSummary.LegRow]

    /// Rows visible before the list has to be scrolled.
    private static let visibleLegLimit = 3
    /// Ceiling for the viewport when the first `visibleLegLimit` rows have not been
    /// measured yet, and a hard cap on tall rows — three rows of wrapped titles with
    /// "Show more" expanded must still leave the rest of the card on screen.
    private static let maxLegsHeight: CGFloat = UIScreen.main.bounds.height * 0.40

    /// Measured height per leg row. Rows size on width alone, so this is not a
    /// one-pass-behind loop — the viewport height derived from it never feeds back
    /// into what it measures.
    @State private var legRowHeights: [RouteCardSummary.LegRow.ID: CGFloat] = [:]
    /// Row currently aligned to the top of the viewport. Drives the snap haptic.
    @State private var topLegID: RouteCardSummary.LegRow.ID?

    /// Combined height of the first `visibleLegLimit` rows, or `nil` until every one of
    /// them has reported. Rows vary in height — titles wrap to as many lines as they
    /// need, subtitles are optional — so "three rows" is a sum, not a constant.
    private var legsViewportHeight: CGFloat? {
        let ids = legRows.prefix(Self.visibleLegLimit).map(\.id)
        guard !ids.isEmpty else { return nil }
        let heights = ids.compactMap { legRowHeights[$0] }
        guard heights.count == ids.count else { return nil }
        return min(heights.reduce(0, +), Self.maxLegsHeight)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(legRows) { row in
                    legRow(row)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(key: LegRowHeightsKey.self,
                                                       value: [row.id: geo.size.height])
                            }
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Makes each row a snap target for `.viewAligned` below, and gives
            // `scrollPosition` the ids it reports.
            .scrollTargetLayout()
        }
        // Snaps row to row. A half-cut step at the viewport edge reads as clipping rather
        // than as more content.
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $topLegID)
        // A tick on each snap, matching the picker-style selection it now behaves
        // like. `old != nil` suppresses the one that would otherwise fire as the
        // list appears and the position binding takes its initial value.
        .sensoryFeedback(trigger: topLegID) { old, new in
            old != nil && new != nil && old != new ? .selection : nil
        }
        // Seeded, not left nil. `scrollPosition` may not write the binding until the first
        // scroll, and the guard above would discard that nil-to-row change and eat its haptic.
        .onAppear { topLegID = legRows.first?.id }
        .onPreferenceChange(LegRowHeightsKey.self) { heights in
            legRowHeights = heights
        }
        // Self-sizing to min(content, cap), with `fixedSize` outermost. The cap is the first
        // three measured rows, so a longer route shows three and scrolls for the rest.
        .frame(maxHeight: legsViewportHeight ?? Self.maxLegsHeight)
        .fixedSize(horizontal: false, vertical: true)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func legRow(_ row: RouteCardSummary.LegRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            legIcon(row)
            VStack(alignment: .leading, spacing: 2) {
                JustifiedLabel(text: row.title,
                               textStyle: .subheadline,
                               weight: .bold,
                               lineLimit: 0)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !row.subtitle.isEmpty {
                    Text(row.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The row's only flexible child, which pushes the minutes to the trailing edge
            // without a Spacer. A second greedy sibling would split the slack and wrap early.
            .frame(maxWidth: .infinity, alignment: .leading)
            // Justified text stretches a wrapped line flush to the column's trailing edge and
            // has no ragged gap of its own, so the title would otherwise touch the minutes.
            .padding(.trailing, 8)
            Text(row.minutesText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // Fixed, so the row has exactly one flexible child and the arithmetic
                // is decided rather than arbitrated.
                .fixedSize()
        }
        // No horizontal padding: this list sits inside the card's own `.padding(18)`.
        .padding(.vertical, 10)
    }

    /// Walk legs get a dashed ring to echo the dashed walk polyline on the map;
    /// ride legs get a solid tint in their mode color.
    @ViewBuilder
    private func legIcon(_ row: RouteCardSummary.LegRow) -> some View {
        ZStack {
            if row.isWalk {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.45),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                Image(systemName: TransportMode.walk.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Circle().fill(row.mode.color.opacity(0.15))
                Image(systemName: row.mode.icon)
                    .font(.caption)
                    .foregroundStyle(row.mode.color)
            }
        }
        .frame(width: 32, height: 32)
    }
}
