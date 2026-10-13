//
//  CommuteIslandViews.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import SwiftUI

/// Mini progress bar in the compact leading region.
struct IslandCompactBar: View {
    let progress: Double
    let isStale: Bool

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let x = min(max(progress, 0), 1) * width
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0x555555)).frame(height: 3)
                Capsule().fill(.white).frame(width: max(x, 3), height: 3)
                Circle().fill(.white).frame(width: 8, height: 8)
                    .offset(x: min(max(x, 4), width - 4) - 4)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 34, height: 10)
        .opacity(isStale ? 0.45 : 1)
    }
}

/// Compact trailing region: time left, or "Done" after arrival.
struct IslandCompactTime: View {
    let state: CommuteState
    let isStale: Bool

    var body: some View {
        Group {
            if state.phase == .arrived {
                Text("Done")
            } else {
                CommuteETATimer(eta: state.eta)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 66, alignment: .trailing)
        .opacity(isStale ? 0.45 : 1)
    }
}

/// Minimal presentation: a progress ring.
struct IslandMinimalRing: View {
    let progress: Double
    let isStale: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Color(hex: 0x4A4A4A), lineWidth: 4)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .butt))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 21, height: 21)
        .padding(2)
        .opacity(isStale ? 0.45 : 1)
    }
}

/// Top line of the expanded presentation: leg label and stops left.
struct IslandExpandedLeading: View {
    let state: CommuteState

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(LiveActivityPalette.islandSecondary)
            .lineLimit(1)
    }

    private var text: String {
        switch state.phase {
        case .live: "\(state.legLabel) · \(state.stopsLeftText)"
        case .waiting: state.legLabel
        case .arrived: ""
        }
    }
}

/// Body of the expanded presentation: action text, route bar and status line.
struct IslandExpandedBody: View {
    let attributes: CommuteActivityAttributes
    let state: CommuteState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.actionText)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LiveActivityPalette.islandText)
                .lineLimit(1)
            SegmentedRouteBar(segments: attributes.segments, progress: state.progress,
                              isStale: isStale, style: .island)
            CommuteStatusLine(state: state, isStale: isStale, style: .island, showsSummary: false)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }
}
