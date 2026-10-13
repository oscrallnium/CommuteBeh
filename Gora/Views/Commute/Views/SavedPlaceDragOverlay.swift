//
//  SavedPlaceDragOverlay.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import SwiftUI

extension View {
    /// Shares one `SavedPlaceDragState` with the content and draws the drag overlay above it.
    func savedPlaceDragHost() -> some View {
        modifier(SavedPlaceDragHost())
    }
}

private struct SavedPlaceDragHost: ViewModifier {
    @State private var drag = SavedPlaceDragState()

    func body(content: Content) -> some View {
        content
            .overlay { SavedPlaceDragOverlay() }
            .environment(drag)
    }
}

/// The moving chip and the delete target. It never takes touches, so the map keeps its gestures.
struct SavedPlaceDragOverlay: View {
    @Environment(SavedPlaceDragState.self) private var drag
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let targetSize: CGFloat = 64
    private static let targetBottomInset: CGFloat = 24
    private static let targetHoverScale: CGFloat = 1.15
    private static let chipLiftScale: CGFloat = 1.08
    private static let chipHoverScale: CGFloat = 0.92
    private static let chipDeleteScale: CGFloat = 0.2
    private static let enterOffset: CGFloat = 24

    private static let hoverAnimation: Animation = .spring(response: 0.25, dampingFraction: 0.7)
    private static let deleteAnimation: Animation = .easeIn(duration: SavedPlaceDragState.deleteDuration)
    private static let fadeAnimation: Animation = .easeOut(duration: 0.15)

    var body: some View {
        ZStack {
            deleteTarget
            movingChip
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: reduceMotion, initial: true) { _, new in drag.reducesMotion = new }
        .sensoryFeedback(.impact(weight: .medium), trigger: drag.isHovering) { _, new in new }
    }

    // MARK: Delete target

    private var deleteTarget: some View {
        ZStack {
            targetAnchor
            if drag.showsTarget {
                targetCircle
                    .transition(reduceMotion ? .opacity : targetTransition)
            }
        }
        .padding(.bottom, Self.targetBottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(reduceMotion ? Self.fadeAnimation : DesignTokens.Motion.cardEnter,
                   value: drag.showsTarget)
    }

    /// An invisible, fixed copy of the target. The drag measures the hover distance from it.
    private var targetAnchor: some View {
        Color.clear
            .frame(width: Self.targetSize, height: Self.targetSize)
            .onGeometryChange(for: CGPoint.self) { proxy in
                let frame = proxy.frame(in: .global)
                return CGPoint(x: frame.midX, y: frame.midY)
            } action: { drag.targetCenter = $0 }
    }

    private var targetCircle: some View {
        Image(systemName: "trash")
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(drag.isHovering ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.primary))
            .frame(width: Self.targetSize, height: Self.targetSize)
            .glassEffect(.regular.tint(drag.isHovering ? Color.vermilion : nil), in: .circle)
            .scaleEffect(drag.isHovering ? Self.targetHoverScale : 1)
            .animation(Self.hoverAnimation, value: drag.isHovering)
    }

    private var targetTransition: AnyTransition {
        .scale(scale: 0.6)
            .combined(with: .opacity)
            .combined(with: .offset(y: Self.enterOffset))
    }

    // MARK: Moving chip

    private var movingChip: some View {
        GeometryReader { proxy in
            if let place = drag.place {
                let origin = proxy.frame(in: .global).origin
                let center = chipCenter
                SavedPlaceChipLabel(icon: place.icon.systemImage, iconSize: 17,
                                    title: place.name, isSelected: drag.isSelected)
                    .glassEffect(.clear, in: .capsule)
                    .cardShadow(y: 6)
                    .scaleEffect(chipScale)
                    .opacity(chipOpacity)
                    .animation(Self.hoverAnimation, value: drag.isHovering)
                    .animation(travelAnimation, value: drag.phase)
                    .position(x: center.x - origin.x, y: center.y - origin.y)
                    .animation(positionAnimation, value: center)
            }
        }
        .ignoresSafeArea()
    }

    /// With Reduce Motion the chip stays under the finger and fades, so it does not travel.
    private var chipCenter: CGPoint {
        reduceMotion ? drag.dragCenter : drag.displayCenter
    }

    private var chipScale: CGFloat {
        switch drag.phase {
        case .idle, .returning: 1
        case .dragging: drag.isHovering ? Self.chipHoverScale : Self.chipLiftScale
        case .deleting: reduceMotion ? Self.chipHoverScale : Self.chipDeleteScale
        }
    }

    private var chipOpacity: Double {
        switch drag.phase {
        case .idle, .dragging: 1
        case .deleting: 0
        case .returning: reduceMotion ? 0 : 1
        }
    }

    /// The chip follows the finger without animation. After the release it travels with the
    /// slot animation, and a moving target retargets the animation each frame.
    private var positionAnimation: Animation? {
        drag.phase == .dragging || drag.phase == .idle ? nil : travelAnimation
    }

    private var travelAnimation: Animation {
        if reduceMotion { return Self.fadeAnimation }
        return drag.phase == .deleting ? Self.deleteAnimation : DesignTokens.Motion.cardEnter
    }
}
