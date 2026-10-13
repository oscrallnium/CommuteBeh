//
//  SegmentedRouteBar.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import SwiftUI

/// Route bar: ride segments as capsules, walk segments as dotted lines, a progress fill and a marker.
struct SegmentedRouteBar: View {
    struct Style {
        var height: CGFloat
        var trackHeight: CGFloat
        var markerSize: CGFloat
        var markerBorder: CGFloat
        var track: Color
        var walk: Color
        var done: Color
        var markerFill: Color

        static let lockScreen = Style(
            height: 18, trackHeight: 6, markerSize: 18, markerBorder: 4,
            track: LiveActivityPalette.track, walk: LiveActivityPalette.tertiary,
            done: LiveActivityPalette.done, markerFill: LiveActivityPalette.background)

        static let island = Style(
            height: 16, trackHeight: 4, markerSize: 16, markerBorder: 3,
            track: LiveActivityPalette.islandTrack, walk: LiveActivityPalette.islandWalk,
            done: LiveActivityPalette.islandDone, markerFill: .black)
    }

    let segments: [CommuteActivityAttributes.Segment]
    let progress: Double
    let isStale: Bool
    let style: Style

    /// Gap between a ride segment and a walk segment, as a share of the bar width.
    private static let gapShare: CGFloat = 0.01
    private static let progressAnimation = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.8)

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let x = min(max(progress, 0), 1) * width
            ZStack(alignment: .topLeading) {
                ForEach(Array(spans(width: width).enumerated()), id: \.offset) { _, span in
                    segmentShape(span)
                }
                fill(width: x)
                marker(x: x, width: width)
            }
            .animation(Self.progressAnimation, value: progress)
        }
        .frame(height: style.height)
    }

    private struct Span {
        var isWalk: Bool
        var start: CGFloat
        var end: CGFloat
    }

    private func spans(width: CGFloat) -> [Span] {
        let total = segments.reduce(0) { $0 + max($1.weight, 0) }
        guard total > 0 else { return [] }
        let gap = width * Self.gapShare
        var cursor = 0.0
        return segments.enumerated().map { index, segment in
            let start = CGFloat(cursor / total) * width
            cursor += max(segment.weight, 0)
            let end = CGFloat(cursor / total) * width
            let startsAfterOther = index > 0 && segments[index - 1].isWalk != segment.isWalk
            let endsBeforeOther = index < segments.count - 1 && segments[index + 1].isWalk != segment.isWalk
            return Span(isWalk: segment.isWalk,
                        start: start + (startsAfterOther ? gap : 0),
                        end: end - (endsBeforeOther ? gap : 0))
        }
    }

    @ViewBuilder
    private func segmentShape(_ span: Span) -> some View {
        let length = max(span.end - span.start, 0)
        if span.isWalk {
            Path { path in
                path.move(to: CGPoint(x: span.start, y: style.height / 2))
                path.addLine(to: CGPoint(x: span.end, y: style.height / 2))
            }
            .stroke(style.walk, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 4]))
        } else {
            Capsule()
                .fill(style.track)
                .frame(width: length, height: style.trackHeight)
                .offset(x: span.start, y: (style.height - style.trackHeight) / 2)
        }
    }

    private func fill(width: CGFloat) -> some View {
        Capsule()
            .fill(style.done)
            .frame(width: max(width, style.trackHeight), height: style.trackHeight)
            .offset(y: (style.height - style.trackHeight) / 2)
            .opacity(isStale ? 0.5 : 1)
    }

    private func marker(x: CGFloat, width: CGFloat) -> some View {
        let center = min(max(x, style.markerSize / 2), width - style.markerSize / 2)
        return Circle()
            .fill(style.markerFill)
            .overlay {
                Circle().strokeBorder(
                    style.done,
                    style: StrokeStyle(lineWidth: style.markerBorder, dash: isStale ? [3, 2] : []))
            }
            .frame(width: style.markerSize, height: style.markerSize)
            .offset(x: center - style.markerSize / 2)
            .opacity(isStale ? 0.55 : 1)
    }
}
