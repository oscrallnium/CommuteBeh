//
//  RouteChoiceLegList.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import SwiftUI

// MARK: - Route Choice Leg List

/// The leg-by-leg timeline in the route choice sheet. Each leg fills its 30 pt icon circle and its
/// connector with the leg color, the walk color for a walk leg. The icon uses the contrasting ink.
struct RouteChoiceLegList: View {
    private enum Layout {
        static let chevronSymbol = "chevron.down"
        static let openChevronDegrees = 180.0
        static let minTapHeight: CGFloat = 44
        static let chevronWidth: CGFloat = 12
        static let fadeLength: CGFloat = 28
    }

    private enum Strings {
        static let expanded = "Expanded"
        static let collapsed = "Collapsed"
        static let hint = "Shows each line of this leg"
        static let separator = ", "
        static let detailSeparator = " · "
    }


    let legRows: [RouteCardSummary.LegRow]
    /// Adds the schedule lines to the timetable leg. Nil for a route with no timetable leg.
    var schedule: ScheduleStatus?
    @Environment(\.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var disclosure: LegDisclosure = .closed
    @ScaledMetric(relativeTo: .caption) private var chevronWidth = Layout.chevronWidth

    /// Which leg shows its lines. One leg is open at most.
    private enum LegDisclosure {
        case closed
        case open(legID: RouteCardSummary.LegRow.ID)

        func isOpen(_ id: RouteCardSummary.LegRow.ID) -> Bool {
            switch self {
            case .closed: false
            case .open(let openID): openID == id
            }
        }

        mutating func toggle(_ id: RouteCardSummary.LegRow.ID) {
            self = isOpen(id) ? .closed : .open(legID: id)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(legRows.enumerated()), id: \.element.id) { index, row in
                    legRow(row, isLast: index == legRows.count - 1)
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollEdgeFade(.bottom, length: Layout.fadeLength)
        .frame(maxHeight: 184)
    }

    private func legRow(_ row: RouteCardSummary.LegRow, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Space.m) {
            timelineColumn(row, isLast: isLast)
            VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
                if row.isGrouped {
                    groupedHeadline(row)
                } else {
                    HStack(alignment: .top, spacing: DesignTokens.Space.s) {
                        headline(row)
                        Color.clear.frame(width: chevronWidth, height: 0)
                    }
                }
                if let schedule, schedule.legID == row.id {
                    ScheduleLegLines(status: schedule)
                }
                if row.isGrouped, disclosure.isOpen(row.id) {
                    RouteChoiceLineRows(lines: row.lines, sections: row.otherModeSections)
                }
            }
            .padding(.bottom, DesignTokens.Space.legRow)
        }
    }

    private func headline(_ row: RouteCardSummary.LegRow) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
            Text(row.title)
                .typeScale(.rowTitle)
            Text(detailText(row))
                .typeScale(.subtitle)
                .foregroundStyle(.secondary)
            if !row.otherModeSections.isEmpty {
                otherModesLine(row)
            }
        }
        .padding(.top, DesignTokens.Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The leg time first, then the leg facts, so the title can use the full row width.
    private func detailText(_ row: RouteCardSummary.LegRow) -> String {
        row.subtitle.isEmpty ? row.minutesText : "\(row.minutesText)\(Strings.detailSeparator)\(row.subtitle)"
    }

    private func otherModesLine(_ row: RouteCardSummary.LegRow) -> some View {
        let counts = row.otherModeSections.map { section in
            let icon = Text(section.mode.iconImage).foregroundStyle(section.mode.color)
            return Text("\(icon) \(section.countText)")
        }
        let joined = counts.dropFirst().reduce(counts.first ?? Text("")) { Text("\($0)\(Strings.separator)\($1)") }
        return Text("\(joined) \(RouteCardSummary.alsoStopHere)")
            .typeScale(.subtitle)
            .foregroundStyle(.secondary)
            .accessibilityLabel(row.otherModesSpoken ?? "")
    }

    private func groupedHeadline(_ row: RouteCardSummary.LegRow) -> some View {
        let isOpen = disclosure.isOpen(row.id)
        return Button {
            withAnimation(reduceMotion ? nil : DesignTokens.Motion.disclose) { disclosure.toggle(row.id) }
        } label: {
            HStack(alignment: .top, spacing: DesignTokens.Space.s) {
                headline(row)
                Image(systemName: Layout.chevronSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? Layout.openChevronDegrees : 0))
                    .frame(width: chevronWidth)
                    .padding(.top, DesignTokens.Space.s)
            }
            .frame(minHeight: Layout.minTapHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOpen ? Strings.expanded : Strings.collapsed)
        .accessibilityHint(Strings.hint)
    }

    private func timelineColumn(_ row: RouteCardSummary.LegRow, isLast: Bool) -> some View {
        VStack(spacing: DesignTokens.Space.xxs) {
            (row.isWalk ? TransportMode.walk : row.mode).iconImage
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(row.color.iconInk(in: environment))
                .frame(width: 30, height: 30)
                .background(row.color, in: Circle())
            if !isLast {
                connector(row)
                    .frame(maxHeight: .infinity)
                    .padding(.bottom, DesignTokens.Space.xxs)
            }
        }
    }

    private func connector(_ row: RouteCardSummary.LegRow) -> some View {
        Capsule()
            .fill(row.color)
            .frame(width: 2)
    }
}
