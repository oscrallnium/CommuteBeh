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
        isWalk = Self.isWalkStep(leg)
        title = isWalk ? "Walk" : lineName(leg.line)
        if isWalk {
            subtitle = "\(RouteCardSummary.distanceLabel(leg.distanceKm)) to \(leg.toStation.name)"
        } else {
            let path = "\(leg.fromStation.name) → \(leg.toStation.name)"
            subtitle = leg.stopCount > 1 ? "\(path) · \(leg.stopCount) stops" : path
        }
        fareText = leg.fare > 0 ? FareText.pesos(leg.fare) : "–"
        durationText = Self.durationText(for: leg)
    }

    /// True for a walk and for an interchange transfer.
    static func isWalkStep(_ leg: RouteLeg) -> Bool {
        leg.mode == .walk || leg.line == "INTERCHANGE"
    }

    /// The leg time as "1 min" or "12 mins".
    static func durationText(for leg: RouteLeg) -> String {
        let minutes = Int(leg.effectiveTravelMinutes.rounded())
        return "\(minutes) \(minutes == 1 ? "min" : "mins")"
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
/// joins one node per leg. A non-nil `onSelectStep` is the manual mode for Location off:
/// every row is a button that makes its step current.
struct CommuteLegList: View {
    let rows: [CommuteLegRowModel]
    let currentLegIndex: Int
    var onSelectStep: ((Int) -> Void)?

    @ScaledMetric(relativeTo: .body) private var listHeight: CGFloat = 212
    /// The step at the top of the list. The list snaps so one step always starts at the top.
    @State private var topRowID: UUID?
    /// True only while the passenger drags or flicks the list, so automatic scrolls stay silent.
    @State private var isUserScrolling = false

    private let rowHeight: CGFloat = 68
    private let topInset: CGFloat = 4
    private let nodeY: CGFloat = 23
    private let nodeSize: CGFloat = 14
    private let checkmarkSize: CGFloat = 8
    private let currentFillInset = DesignTokens.Space.xs

    private var isManual: Bool { onSelectStep != nil }
    /// Changes with the current step in manual mode only, so the live list keeps its own animation.
    private var manualStateKey: Int { isManual ? currentLegIndex : -1 }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    legRow(row, index: index)
                }
            }
            .scrollTargetLayout()
            .animation(DesignTokens.Motion.locationState, value: manualStateKey)
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
        return Group {
            if let onSelectStep {
                Button { onSelectStep(index) } label: { rowBody(row, index: index, state: state) }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel(row, index: index, state: state))
                    .accessibilityHint("Makes this the current step.")
            } else {
                rowBody(row, index: index, state: state)
            }
        }
        .id(row.id)
    }

    private func accessibilityLabel(_ row: CommuteLegRowModel, index: Int, state: RowState) -> String {
        var parts = ["Step \(index + 1) of \(rows.count)", row.mode.displayName, row.title, row.subtitle,
                     row.fareText, row.durationText]
        switch state {
        case .completed: parts.append("done")
        case .current: parts.append("current step")
        case .ahead: break
        }
        return parts.joined(separator: ", ")
    }

    private func rowBody(_ row: CommuteLegRowModel, index: Int, state: RowState) -> some View {
        HStack(spacing: DesignTokens.Space.ml) {
            Color.clear.frame(width: nodeSize)
            VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
                HStack(spacing: DesignTokens.Space.xs) {
                    Text(row.title)
                        .typeScale(state == .current ? .rowTitleLargeCurrent : .rowTitleLarge)
                        .foregroundStyle(state.titleColor)
                        .lineLimit(1)
                    if isManual, state == .current { nowTag }
                }
                Text(row.subtitle)
                    .typeScale(.body).monospacedDigit()
                    .foregroundStyle(state.subtitleColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: DesignTokens.Space.xxs) {
                Text(row.fareText)
                    .typeScale(.rowTitleLarge).monospacedDigit()
                    .foregroundStyle(state.titleColor)
                Text(row.durationText)
                    .typeScale(.body)
                    .foregroundStyle(state.subtitleColor)
            }
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.horizontal, DesignTokens.Space.l)
        .frame(minHeight: rowHeight)
        .background(alignment: .leading) {
            rail(row, state: state, isFirst: index == 0, isLast: index == rows.count - 1)
                .padding(.leading, DesignTokens.Space.l)
        }
        .background {
            if isManual, state == .current {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                    .fill(Color.haze)
                    .padding(.horizontal, currentFillInset)
            }
        }
        .contentShape(.rect)
    }

    /// Names the current step in text, so the state never depends on color alone.
    private var nowTag: some View {
        Text("Now")
            .typeScale(.subtitleEmphasis)
            .foregroundStyle(.primary)
            .padding(.horizontal, DesignTokens.Space.xs)
            .background(Color.tangerine.opacity(0.18), in: .capsule)
    }

    /// A bar in the leg color through a node whose top edge is at `nodeY`. A walk bar is
    /// 4 pt wide, a ride bar 6 pt. The rail sits in the row background and fills the row height.
    /// The first bar starts at the node centre, and the last bar ends there.
    private func rail(_ row: CommuteLegRowModel, state: RowState, isFirst: Bool, isLast: Bool) -> some View {
        let nodeCenter = nodeY + nodeSize / 2
        let top = isFirst ? nodeCenter : 0
        let barMaxHeight = isLast ? nodeCenter - top : CGFloat.infinity
        let color = state == .completed ? Color.faint : row.color
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(color)
                .frame(width: row.isWalk ? 4 : 6)
                .frame(maxHeight: barMaxHeight)
                .padding(.top, top)
                .padding(.leading, row.isWalk ? 5 : 4)
            Circle()
                .fill(state == .current ? Color.tangerine : Color.graphite)
                .overlay(Circle().strokeBorder(row.isWalk && state != .completed ? Color.onyx : color,
                                               lineWidth: 3))
                .overlay {
                    if isManual, state == .completed {
                        Image(systemName: "checkmark")
                            .font(.system(size: checkmarkSize, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: nodeSize, height: nodeSize)
                .padding(.top, nodeY)
        }
        .frame(width: nodeSize, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}
