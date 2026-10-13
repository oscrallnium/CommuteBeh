//
//  CommuteLockScreenView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import SwiftUI

/// Lock Screen and banner card of the commute Live Activity.
struct CommuteLockScreenView: View {
    let attributes: CommuteActivityAttributes
    let state: CommuteState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headline
            SegmentedRouteBar(segments: attributes.segments, progress: state.progress,
                              isStale: isStale, style: .lockScreen)
                .padding(.top, 2)
            stationLabels
            CommuteStatusLine(state: state, isStale: isStale, style: .lockScreen)
        }
        .padding(.top, 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .foregroundStyle(LiveActivityPalette.primary)
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(state.actionText)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if state.phase != .arrived {
                CommuteETATimer(eta: state.eta, isStale: isStale)
                    .font(.system(size: 17, weight: .semibold))
            }
        }
    }

    /// First label at the left edge, last at the right edge, transfer labels centered on their boundary.
    private var stationLabels: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                ForEach(Array(visibleLabels.enumerated()), id: \.offset) { _, label in
                    labelView(label, width: width)
                }
            }
        }
        .frame(height: 14)
        .font(.system(size: 11))
        .foregroundStyle(LiveActivityPalette.tertiary)
    }

    /// Interior labels near an end label are hidden so the text never overlaps.
    private var visibleLabels: [CommuteActivityAttributes.BoundaryLabel] {
        attributes.boundaryLabels.filter { $0.position <= 0 || $0.position >= 1 || (0.3...0.7).contains($0.position) }
    }

    @ViewBuilder
    private func labelView(_ label: CommuteActivityAttributes.BoundaryLabel, width: CGFloat) -> some View {
        let boxWidth = width * (label.position <= 0 || label.position >= 1 ? 0.4 : 0.3)
        let alignment: Alignment = label.position <= 0 ? .leading : (label.position >= 1 ? .trailing : .center)
        let originX = label.position <= 0 ? 0 : (label.position >= 1 ? width - boxWidth : label.position * width - boxWidth / 2)
        Text(label.text)
            .lineLimit(1)
            .frame(width: boxWidth, alignment: alignment)
            .offset(x: originX)
    }
}
