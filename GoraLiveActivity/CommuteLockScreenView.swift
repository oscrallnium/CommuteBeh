//
//  CommuteLockScreenView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import SwiftUI

/// Lock Screen and banner card of the commute Live Activity.
struct CommuteLockScreenView: View {
    private enum Layout {
        static let labelWidthShare: CGFloat = 0.4
    }

    let attributes: CommuteActivityAttributes
    let state: CommuteState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headline
            SegmentedRouteBar(segments: attributes.segments, progress: state.progress,
                              legIndex: state.legIndex, isStale: isStale, style: .lockScreen)
                .padding(.top, 2)
            stationLabels
            CommuteStatusLine(state: state, isStale: isStale, style: .lockScreen)
        }
        .padding(.top, 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .foregroundStyle(LiveActivityPalette.primary)
    }

    /// The top-right area stays empty. A hidden placeholder keeps the width that the ETA timer used.
    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(state.actionText)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: "00:00")
                .font(.system(size: 17, weight: .semibold))
                .hidden()
                .accessibilityHidden(true)
        }
    }

    /// The start label sits at the left edge and the destination label at the right edge.
    private var stationLabels: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                ForEach(Array(endLabels.enumerated()), id: \.offset) { _, label in
                    labelView(label, width: width)
                }
            }
        }
        .frame(height: 14)
        .font(.system(size: 11))
        .foregroundStyle(LiveActivityPalette.tertiary)
    }

    /// Only the start and destination labels draw. Interior labels from an older activity are skipped.
    private var endLabels: [CommuteActivityAttributes.BoundaryLabel] {
        attributes.boundaryLabels.filter { $0.position <= 0 || $0.position >= 1 }
    }

    @ViewBuilder
    private func labelView(_ label: CommuteActivityAttributes.BoundaryLabel, width: CGFloat) -> some View {
        let isStart = label.position <= 0
        let boxWidth = width * Layout.labelWidthShare
        Text(label.text)
            .lineLimit(1)
            .frame(width: boxWidth, alignment: isStart ? .leading : .trailing)
            .offset(x: isStart ? 0 : width - boxWidth)
    }
}
