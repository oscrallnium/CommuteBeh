//
//  RouteChoiceRideList.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/13/26.
//

import SwiftUI

// MARK: - Route Choice Columns

/// The leading icon column that every row of the route lists shares, so titles start on one edge.
/// `iconSize` is the column width; the icon height follows the row text.
enum RouteChoiceColumns {
    static let iconSize: CGFloat = 20
    static let iconSpacing = DesignTokens.Space.m
}

// MARK: - Route Choice Duration

/// The trailing leg time of a row in both route lists. The column width is fixed, so a long
/// time such as "1 hour 24 mins" shrinks to fit and never pushes the title.
struct RouteChoiceDuration: View {
    private enum Layout {
        static let width: CGFloat = 96
        /// 11 pt, the iOS minimum text size, divided by the 13 pt subtitle size and rounded up.
        static let minimumScale: CGFloat = 0.85
    }

    let text: String
    @ScaledMetric(relativeTo: .footnote) private var width = Layout.width

    var body: some View {
        Text(text)
            .typeScale(.subtitle).monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(Layout.minimumScale)
            .frame(width: width, alignment: .trailing)
    }
}

// MARK: - Route Choice Ride List

/// The collapsed route list: one row per ride, a "more rides" row past the limit, the total
/// walk time, and the payment line. The "more rides" row opens the route details.
struct RouteChoiceRideList: View {
    let summary: RouteCardSummary
    @Binding var isDetailExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var iconSize = RouteChoiceColumns.iconSize

    private enum Layout {
        static let radius: CGFloat = 12
        static let padding = DesignTokens.Space.m
        static let rowSpacing = DesignTokens.Space.m
        static let tapOutset: CGFloat = 12
        static let maxRows = 3
        static let maxGlyphs = 4
        static let titleLines = 2
    }

    private enum Strings {
        static let walkTotal = "Walk in total"
        static let moreRides = "more rides"
        static let moreRidesHint = "Shows the route details"
    }

    /// A row of the list. A closed set, so a new kind of row fails to compile in `row(_:)`.
    private enum Item: Identifiable {
        case ride(RouteCardSummary.RideRow)
        case more([RouteCardSummary.RideRow])

        var id: String {
            switch self {
            case .ride(let ride): ride.id.uuidString
            case .more: "more"
            }
        }
    }

    private var items: [Item] {
        let rides = summary.rideRows
        guard rides.count > Layout.maxRows else { return rides.map(Item.ride) }
        let shown = rides.prefix(Layout.maxRows - 1).map(Item.ride)
        return shown + [.more(Array(rides.dropFirst(Layout.maxRows - 1)))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            ForEach(items) { row($0) }
            walkRow
            if !summary.paymentsFull.isEmpty || !summary.paymentsPartial.isEmpty {
                Divider()
                PaymentFactRow(full: summary.paymentsFull, partial: summary.paymentsPartial)
            }
        }
        .padding(Layout.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.haze, in: RoundedRectangle(cornerRadius: Layout.radius, style: .continuous))
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        switch item {
        case .ride(let ride): rideRow(ride)
        case .more(let rest): moreRow(rest)
        }
    }

    private func rideRow(_ ride: RouteCardSummary.RideRow) -> some View {
        HStack(spacing: RouteChoiceColumns.iconSpacing) {
            iconView(ride.mode, color: ride.color)
                .frame(width: iconSize)
            Text(ride.title)
                .typeScale(.subtitle)
                .foregroundStyle(.primary)
                .lineLimit(Layout.titleLines)
                .frame(maxWidth: .infinity, alignment: .leading)
            RouteChoiceDuration(text: RouteCardSummary.legDuration(minutes: ride.minutes))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ride.title), \(RouteCardSummary.legDuration(minutes: ride.minutes))")
    }

    private func moreRow(_ rest: [RouteCardSummary.RideRow]) -> some View {
        let restMinutes = rest.reduce(0) { $0 + $1.minutes }
        return Button {
            withAnimation(DesignTokens.Motion.routeDetail(reduceMotion: reduceMotion)) {
                isDetailExpanded = true
            }
        } label: {
            HStack(spacing: RouteChoiceColumns.iconSpacing) {
                Image(systemName: "ellipsis.circle")
                    .typeScale(.subtitle)
                    .foregroundStyle(.secondary)
                    .frame(width: iconSize)
                HStack(spacing: DesignTokens.Space.xs) {
                    Text("\(rest.count) \(Strings.moreRides)")
                        .typeScale(.subtitleEmphasis)
                        .foregroundStyle(Color.lagoon)
                        .lineLimit(Layout.titleLines)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                moreGlyphs(rest)
                RouteChoiceDuration(text: RouteCardSummary.legDuration(minutes: restMinutes))
            }
            .padding(.vertical, Layout.tapOutset)
            .contentShape(.rect)
            .padding(.vertical, -Layout.tapOutset)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(rest.count) \(Strings.moreRides), \(RouteCardSummary.legDuration(minutes: restMinutes))")
        .accessibilityHint(Strings.moreRidesHint)
    }

    private func moreGlyphs(_ rest: [RouteCardSummary.RideRow]) -> some View {
        HStack(spacing: DesignTokens.Space.xxs) {
            ForEach(rest.prefix(Layout.maxGlyphs)) { iconView($0.mode, color: $0.color) }
            if rest.count > Layout.maxGlyphs {
                Text("+\(rest.count - Layout.maxGlyphs)").typeScale(.subtitle)
            }
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var walkRow: some View {
        if let walkMinutes = summary.walkMinutes {
            HStack(spacing: RouteChoiceColumns.iconSpacing) {
                iconView(.walk, color: Color.secondary)
                    .frame(width: iconSize)
                Text(Strings.walkTotal)
                    .typeScale(.subtitle)
                    .foregroundStyle(.primary)
                    .lineLimit(Layout.titleLines)
                    .frame(maxWidth: .infinity, alignment: .leading)
                RouteChoiceDuration(text: RouteCardSummary.legDuration(minutes: walkMinutes))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(Strings.walkTotal), \(RouteCardSummary.legDuration(minutes: walkMinutes))")
        }
    }

    // MARK: Parts

    private func iconView(_ mode: TransportMode, color: Color) -> some View {
        mode.iconImage
            .typeScale(.subtitle)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

}
