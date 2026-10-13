//
//  RouteChoiceLegList.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import SwiftUI

// MARK: - Route Choice Leg List

/// The leg-by-leg timeline in the route choice sheet. A ride leg fills its 30 pt icon circle and
/// its connector with the leg color. A walk leg uses a haze circle and a dotted connector.
struct RouteChoiceLegList: View {
    let legRows: [RouteCardSummary.LegRow]
    @Environment(\.self) private var environment

    private let walkDotSize: CGFloat = 3
    private let walkDotPitch: CGFloat = 6

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(legRows.enumerated()), id: \.element.id) { index, row in
                    legRow(row, isLast: index == legRows.count - 1)
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: 184)
    }

    private func legRow(_ row: RouteCardSummary.LegRow, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Space.m) {
            timelineColumn(row, isLast: isLast)
            VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
                Text(row.title)
                    .font(DesignTokens.TypeScale.rowTitle)
                Text(row.subtitle)
                    .font(DesignTokens.TypeScale.subtitle)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, DesignTokens.Space.xxs)
            .padding(.bottom, DesignTokens.Space.legRow)
            Spacer(minLength: DesignTokens.Space.s)
            Text(row.minutesText)
                .font(DesignTokens.TypeScale.subtitle.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.top, DesignTokens.Space.xs)
        }
    }

    private func timelineColumn(_ row: RouteCardSummary.LegRow, isLast: Bool) -> some View {
        VStack(spacing: DesignTokens.Space.xxs) {
            Image(systemName: row.isWalk ? TransportMode.walk.icon : row.mode.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(row.isWalk ? AnyShapeStyle(.primary) : AnyShapeStyle(row.color.contrastingInk(in: environment)))
                .frame(width: 30, height: 30)
                .background(row.isWalk ? Color.haze : row.color, in: Circle())
            if !isLast {
                connector(row)
                    .frame(maxHeight: .infinity)
                    .padding(.bottom, DesignTokens.Space.xxs)
            }
        }
    }

    @ViewBuilder
    private func connector(_ row: RouteCardSummary.LegRow) -> some View {
        if row.isWalk {
            VerticalLine()
                .stroke(Color.smoke, style: StrokeStyle(lineWidth: walkDotSize, lineCap: .round,
                                                        dash: [0, walkDotPitch]))
                .frame(width: walkDotSize)
        } else {
            Capsule()
                .fill(row.color)
                .frame(width: 2)
        }
    }
}

/// A vertical line through the middle of its frame.
private struct VerticalLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}
