//
//  CommuteStatusViews.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import SwiftUI

typealias CommuteState = CommuteActivityAttributes.ContentState

extension CommuteState {
    var stopsLeftText: String {
        stopsLeft == 1 ? "1 stop left" : "\(stopsLeft) stops left"
    }
}

/// Time left to the arrival date. The system updates the text on its own.
struct CommuteETATimer: View {
    let eta: Date
    var isStale = false

    var body: some View {
        let now = Date.now
        Text(timerInterval: now...max(now, eta), pauseTime: nil, countsDown: true, showsHours: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 80, alignment: .trailing)
            .opacity(isStale ? 0.4 : 1)
            .contentTransition(.numericText())
    }
}

/// Footer line: Live dot and update time on the left, trip summary on the right.
struct CommuteStatusLine: View {
    struct Style {
        var text: Color
        var strong: Color

        static let lockScreen = Style(text: LiveActivityPalette.tertiary, strong: LiveActivityPalette.primary)
        static let island = Style(text: LiveActivityPalette.islandTertiary, strong: LiveActivityPalette.islandText)
    }

    let state: CommuteState
    let isStale: Bool
    let style: Style
    var showsSummary = true

    var body: some View {
        HStack(spacing: 8) {
            status
            if showsSummary {
                Spacer(minLength: 8)
                summary.opacity(isStale ? 0.4 : 1)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(style.text)
        .lineLimit(1)
    }

    @ViewBuilder
    private var status: some View {
        if state.phase == .arrived {
            Text("Trip ended")
        } else if isStale {
            Text("Last known location · \(Text(state.lastFixAt, style: .relative)) ago")
        } else {
            HStack(spacing: 6) {
                Circle().fill(style.strong).frame(width: 6, height: 6)
                Text("Live").fontWeight(.semibold).foregroundStyle(style.strong)
                Text("·")
                Text("Updated \(Text(state.lastFixAt, style: .relative)) ago")
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        switch state.phase {
        case .arrived:
            Text("Arrived \(Text(state.eta, style: .time))")
        case .waiting:
            if let next = state.nextLineName {
                Text("\(next) next")
            } else {
                Text(state.stopsLeftText)
            }
        case .live:
            Text("\(state.stopsLeftText) · Arrive \(Text(state.eta, style: .time))")
        }
    }
}
