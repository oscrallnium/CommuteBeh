//
//  CommuteLegList.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/9/26.
//

import SwiftUI
import CoreLocation

/// Where a leg sits relative to live progress — drives the badge, the dimming, and
/// which subtitle line the row shows (planned distance for everything but the leg
/// actually underway, which shows the live figure instead).
enum CommuteLegState: Equatable {
    case past
    case now(metersRemaining: CLLocationDistance)
    case next
    case upcoming
}

/// The full leg breakdown shown once "See route" expands the compact commute card.
/// Unlike `RouteLegList` (the static post-search breakdown, capped at three rows with
/// scroll-snap paging), every leg is shown at once here — this is a status view read in
/// one glance while walking, not something paged through.
struct CommuteLegList: View {
    let legRows: [RouteCardSummary.LegRow]
    let currentLegIndex: Int
    let metersRemainingOnCurrentLeg: CLLocationDistance

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(legRows.enumerated()), id: \.element.id) { index, row in
                legRow(row, state: state(for: index))
                if index < legRows.count - 1 {
                    Divider().padding(.leading, 44)
                }
            }
        }
    }

    private func state(for index: Int) -> CommuteLegState {
        if index < currentLegIndex { return .past }
        if index == currentLegIndex { return .now(metersRemaining: metersRemainingOnCurrentLeg) }
        if index == currentLegIndex + 1 { return .next }
        return .upcoming
    }

    private func legRow(_ row: RouteCardSummary.LegRow, state: CommuteLegState) -> some View {
        HStack(alignment: .top, spacing: 12) {
            legIcon(row, isPast: state == .past)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(2)
                    if case .now = state {
                        CommuteLegBadge(text: "NOW", color: DesignTokens.Colors.success)
                    } else if state == .next {
                        CommuteLegBadge(text: "NEXT", color: Color.charcoal)
                    }
                }
                Text(subtitle(for: row, state: state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.minutesText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.vertical, 10)
        .opacity(state == .past ? 0.45 : 1)
    }

    /// Live remaining distance replaces the planned subtitle only for the leg actually
    /// underway — every other row shows the same planned text `RouteLegList` would.
    private func subtitle(for row: RouteCardSummary.LegRow, state: CommuteLegState) -> String {
        guard case .now(let metersRemaining) = state else { return row.subtitle }
        return "\(RouteCardSummary.distanceLabel(metersRemaining / 1000)) left"
    }

    @ViewBuilder
    private func legIcon(_ row: RouteCardSummary.LegRow, isPast: Bool) -> some View {
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

/// A small "NOW"/"NEXT" pill — deliberately its own tiny view rather than reusing
/// `LabelBadge`, which is hardcoded to the FASTEST/CHEAPEST option-label enum and two
/// specific colors; this one just needs a string and a color.
private struct CommuteLegBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.heavy))
            .kerning(0.5)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color))
            .fixedSize()
    }
}
