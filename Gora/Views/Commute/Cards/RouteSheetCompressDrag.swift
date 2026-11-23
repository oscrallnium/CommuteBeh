//
//  RouteSheetCompressDrag.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/24/26.
//

import SwiftUI

/// Drag that moves the route sheet between its previous state (progress 0) and the compressed
/// state (progress 1). `rawProgress` holds the live value during the drag and is nil at rest.
struct RouteSheetCompressDrag: ViewModifier {
    @Binding var isCompressed: Bool
    @Binding var rawProgress: CGFloat?
    /// Height in points that the drag moves from progress 0 to progress 1.
    let range: CGFloat
    /// False turns the gesture off, so the header and the whole sheet never both handle a drag.
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var isDragging = false

    private enum Layout {
        static let minimumDistance: CGFloat = 8
        static let commitFraction: CGFloat = 0.5
    }

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(drag, including: isActive ? .all : .subviews)
            .onChange(of: isDragging) { _, dragging in
                guard !dragging, rawProgress != nil else { return }
                withAnimation(DesignTokens.Motion.routeDetail(reduceMotion: reduceMotion)) { rawProgress = nil }
            }
    }

    private var restProgress: CGFloat { isCompressed ? 1 : 0 }

    /// A cancelled drag skips `onEnded`; the `onChange` in `body` then restores the rest state.
    /// Uses the global space: the sheet resizes under the finger, so a local translation shrinks as it moves.
    private var drag: some Gesture {
        DragGesture(minimumDistance: Layout.minimumDistance, coordinateSpace: .global)
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                guard range > 0 else { return }
                let isVertical = abs(value.translation.height) > abs(value.translation.width)
                guard rawProgress != nil || isVertical else { return }
                rawProgress = restProgress + value.translation.height / range
            }
            .onEnded { value in
                guard rawProgress != nil else { return }
                withAnimation(DesignTokens.Motion.routeDetail(reduceMotion: reduceMotion)) {
                    if commits(value) { isCompressed.toggle() }
                    rawProgress = nil
                }
            }
    }

    /// The drag commits when the finger or the predicted end passes half of the range in the toggle direction.
    private func commits(_ value: DragGesture.Value) -> Bool {
        let direction: CGFloat = isCompressed ? -1 : 1
        let reach = max(direction * value.translation.height,
                        direction * value.predictedEndTranslation.height)
        return reach >= range * Layout.commitFraction
    }
}

/// Maps the raw drag progress to the progress the sheet shows and to the rubber-band offset.
enum RouteSheetCompressMath {
    private enum Layout {
        static let resistance: CGFloat = 0.2
        static let maxOvershoot: CGFloat = 24
    }

    static func clamped(_ raw: CGFloat) -> CGFloat { min(1, max(0, raw)) }

    /// Points to move the sheet when the raw progress passes 0 or 1. The offset grows slowly and stops at a limit.
    static func overshoot(raw: CGFloat, range: CGFloat) -> CGFloat {
        let excess = (raw - clamped(raw)) * range
        return min(abs(excess) * Layout.resistance, Layout.maxOvershoot) * (excess < 0 ? -1 : 1)
    }
}
