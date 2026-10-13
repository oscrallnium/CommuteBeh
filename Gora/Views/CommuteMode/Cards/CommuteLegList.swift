//
//  CommuteLegList.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/9/26.
//

import SwiftUI

/// One leg as the commute sheet shows it. Every string comes from the route data.
struct CommuteLegRowModel: Identifiable {
    let id: UUID
    let mode: TransportMode
    let isWalk: Bool
    let title: String
    let subtitle: String
    let fareText: String
    let durationText: String
    let color: Color

    /// `lineName` maps a line key to its display name. `legColor` gives the rail color.
    init(leg: RouteLeg, lineName: (String) -> String, legColor: (RouteLeg) -> Color) {
        id = leg.id
        mode = leg.mode
        color = legColor(leg)
        isWalk = leg.mode == .walk || leg.line == "INTERCHANGE"
        title = isWalk ? "Walk" : lineName(leg.line)
        if isWalk {
            subtitle = "\(RouteCardSummary.distanceLabel(leg.distanceKm)) to \(leg.toStation.shortName)"
        } else {
            let path = "\(leg.fromStation.shortName) → \(leg.toStation.shortName)"
            subtitle = leg.stopCount > 1 ? "\(path) · \(leg.stopCount) stops" : path
        }
        fareText = leg.fare > 0 ? "₱\(Int(leg.fare))" : "–"
        let minutes = Int(leg.effectiveTravelMinutes.rounded())
        durationText = "\(minutes) \(minutes == 1 ? "min" : "mins")"
    }
}

/// Where a row sits relative to the leg the passenger rides now.
private enum RowState {
    case completed, current, ahead

    init(index: Int, currentLegIndex: Int) {
        if index < currentLegIndex {
            self = .completed
        } else if index == currentLegIndex {
            self = .current
        } else {
            self = .ahead
        }
    }

    var titleColor: AnyShapeStyle {
        self == .completed ? AnyShapeStyle(HierarchicalShapeStyle.tertiary) : AnyShapeStyle(HierarchicalShapeStyle.primary)
    }
    var subtitleColor: AnyShapeStyle {
        self == .completed ? AnyShapeStyle(HierarchicalShapeStyle.tertiary) : AnyShapeStyle(HierarchicalShapeStyle.secondary)
    }
}

/// The scrolling leg breakdown in the expanded commute sheet. A rail on the leading edge
/// joins one node per leg.
struct CommuteLegList: View {
    let rows: [CommuteLegRowModel]
    let currentLegIndex: Int

    @ScaledMetric(relativeTo: .body) private var listHeight: CGFloat = 200
    /// The step at the top of the list. The list snaps so one step always starts at the top.
    @State private var topRowID: UUID?
    /// True only while the passenger drags or flicks the list, so automatic scrolls stay silent.
    @State private var isUserScrolling = false

    private let rowHeight: CGFloat = 64
    private let topInset: CGFloat = 4
    private let nodeY: CGFloat = 22
    private let nodeSize: CGFloat = 14
    private let walkDotSize: CGFloat = 3
    private let walkDotPitch: CGFloat = 6
    /// Clear space between a walking dot and the node or the next leg's bar.
    private let walkDotGap: CGFloat = 3

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    legRow(row, index: index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $topRowID, anchor: .top)
        .onScrollPhaseChange { _, phase in
            isUserScrolling = phase == .interacting || phase == .decelerating
        }
        .sensoryFeedback(.selection, trigger: topRowID) { _, _ in isUserScrolling }
        .onAppear { topRowID = currentRowID }
        .onChange(of: currentLegIndex) {
            withAnimation(.smooth) { topRowID = currentRowID }
        }
        .frame(height: listHeight - topInset)
        .padding(.top, topInset)
        .mask(fadeMask)
    }

    private var currentRowID: UUID? {
        rows.indices.contains(currentLegIndex) ? rows[currentLegIndex].id : nil
    }

    private var fadeMask: some View {
        LinearGradient(stops: [.init(color: .black, location: 0),
                               .init(color: .black, location: 0.82),
                               .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }

    private func legRow(_ row: CommuteLegRowModel, index: Int) -> some View {
        let state = RowState(index: index, currentLegIndex: currentLegIndex)
        return HStack(spacing: DesignTokens.Space.ml) {
            rail(row, state: state, isFirst: index == 0, isLast: index == rows.count - 1)
            VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
                Text(row.title)
                    .font(state == .current ? DesignTokens.TypeScale.rowTitleCurrent
                                            : DesignTokens.TypeScale.rowTitle)
                    .foregroundStyle(state.titleColor)
                    .lineLimit(1)
                Text(row.subtitle)
                    .font(DesignTokens.TypeScale.subtitle.monospacedDigit())
                    .foregroundStyle(state.subtitleColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: DesignTokens.Space.xxs) {
                Text(row.fareText)
                    .font(DesignTokens.TypeScale.rowTitle.monospacedDigit())
                    .foregroundStyle(state.titleColor)
                Text(row.durationText)
                    .font(DesignTokens.TypeScale.subtitle)
                    .foregroundStyle(state.subtitleColor)
            }
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.horizontal, DesignTokens.Space.l)
        .frame(height: rowHeight)
        .id(row.id)
    }

    /// A bar in the leg color, or walking dots, through a node whose top edge is at
    /// `nodeY`. The first rail starts at the node centre, and the last rail ends there.
    private func rail(_ row: CommuteLegRowModel, state: RowState, isFirst: Bool, isLast: Bool) -> some View {
        let nodeCenter = nodeY + nodeSize / 2
        let top = isFirst ? nodeCenter : 0
        let bottom = isLast ? nodeCenter : rowHeight
        let color = state == .completed ? Color.faint : row.color
        return ZStack(alignment: .topLeading) {
            if row.isWalk {
                walkDots(isFirst: isFirst, isLast: isLast).fill(color)
            } else {
                Rectangle()
                    .fill(color)
                    .frame(width: 6, height: bottom - top)
                    .offset(x: 4, y: top)
            }
            Circle()
                .fill(state == .current ? Color.tangerine : Color.graphite)
                .overlay(Circle().strokeBorder(row.isWalk && state != .completed ? Color.onyx : color,
                                               lineWidth: 3))
                .frame(width: nodeSize, height: nodeSize)
                .offset(y: nodeY)
        }
        .frame(width: nodeSize, height: rowHeight, alignment: .topLeading)
    }

    /// Walking dots above and below the node, spread evenly with `walkDotGap` at each end.
    private func walkDots(isFirst: Bool, isLast: Bool) -> Path {
        var path = Path()
        if !isFirst { addWalkDots(to: &path, from: 0, to: nodeY) }
        if !isLast { addWalkDots(to: &path, from: nodeY + nodeSize, to: rowHeight) }
        return path
    }

    private func addWalkDots(to path: inout Path, from start: CGFloat, to end: CGFloat) {
        let first = start + walkDotGap + walkDotSize / 2
        let span = end - walkDotGap - walkDotSize / 2 - first
        guard span >= 0 else { return }
        let gaps = max(1, (span / walkDotPitch).rounded())
        for index in 0...Int(gaps) {
            let y = first + span * CGFloat(index) / gaps
            path.addEllipse(in: CGRect(x: (nodeSize - walkDotSize) / 2, y: y - walkDotSize / 2,
                                       width: walkDotSize, height: walkDotSize))
        }
    }
}
