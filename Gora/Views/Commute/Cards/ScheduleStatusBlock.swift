//
//  ScheduleStatusBlock.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/16/26.
//

import SwiftUI

// MARK: - Schedule Ticker

/// Passes the schedule status of `result` to `content` and refreshes it every minute.
/// A route with no timetable leg gets nil and no timeline.
struct ScheduleTicker<Content: View>: View {
    let result: RouteResult
    @ViewBuilder let content: (ScheduleStatus?) -> Content
    @Environment(RouteStore.self) private var routeStore

    var body: some View {
        if result.hasScheduledLeg {
            TimelineView(.everyMinute) { context in
                content(routeStore.scheduleStatus(for: result, at: context.date))
            }
        } else {
            content(nil)
        }
    }
}

// MARK: - Schedule Status Block

/// The status lines under the duration row. The second line is absent when its copy is nil.
/// Words and symbols carry the state, not color.
struct ScheduleStatusBlock: View {
    let status: ScheduleStatus
    @AppStorage(SettingsKey.use24HourTime) private var use24HourTime = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private enum Layout {
        static let rowSpacing = DesignTokens.Space.xs
        static let wrappedLines = 2
    }

    private enum Strings {
        static let separator = "· "
    }

    private var copy: ScheduleCopy {
        ScheduleCopy(status, uses24HourTime: use24HourTime)
    }

    var body: some View {
        let copy = copy
        VStack(alignment: .leading, spacing: 0) {
            if dynamicTypeSize.isAccessibilitySize {
                wrappedFirstLine(copy)
            } else {
                firstLine(copy)
            }
            if let line = copy.secondLine {
                secondLine(line)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(copy.spoken)
        .onChange(of: status.state) { oldState, newState in
            guard newState == .ready, oldState != .ready else { return }
            AccessibilityNotification.Announcement(copy.announcement).post()
        }
    }

    private func firstLine(_ copy: ScheduleCopy) -> some View {
        HStack(spacing: Layout.rowSpacing) {
            Image(systemName: copy.symbol)
            Text(copy.headline)
                .typeScale(.subtitleEmphasis)
            if let detail = copy.detail {
                Text("\(Strings.separator)\(detail)")
                    .typeScale(.subtitle)
                    .foregroundStyle(.secondary)
                    .numberTransition(value: detail, reduceMotion: reduceMotion)
            }
        }
        .lineLimit(1)
    }

    private func wrappedFirstLine(_ copy: ScheduleCopy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(copy.headline, systemImage: copy.symbol)
                .typeScale(.subtitleEmphasis)
                .lineLimit(1)
            Text(copy.detail ?? " ")
                .typeScale(.subtitle)
                .foregroundStyle(.secondary)
                .lineLimit(Layout.wrappedLines, reservesSpace: true)
                .numberTransition(value: copy.detail ?? "", reduceMotion: reduceMotion)
        }
    }

    private func secondLine(_ line: String) -> some View {
        Text(line)
            .typeScale(.subtitle)
            .foregroundStyle(.secondary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? Layout.wrappedLines : 1,
                       reservesSpace: dynamicTypeSize.isAccessibilitySize)
    }

}

private enum NumberMotion {
    static let animation: Animation = .easeInOut(duration: 0.2)
}

private extension View {
    /// Rolls changed digits in place. Reduce Motion swaps the text with no animation.
    func numberTransition(value: String, reduceMotion: Bool) -> some View {
        contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : NumberMotion.animation, value: value)
    }
}
