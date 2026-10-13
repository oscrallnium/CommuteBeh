//
//  SavedPlaceDragSource.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import SwiftUI

extension View {
    /// Makes a saved-place chip a row slot. A hold opens the edit sheet through `onEdit`.
    /// The row's pan recognizer lifts the chip, and the slot hides the chip while it is lifted.
    func savedPlaceDragSource(place: SavedPlace, onEdit: @escaping () -> Void) -> some View {
        modifier(SavedPlaceDragSource(place: place, onEdit: onEdit))
    }
}

private struct SavedPlaceDragSource: ViewModifier {
    let place: SavedPlace
    let onEdit: () -> Void

    @Environment(SavedPlaceDragState.self) private var drag
    @State private var slotWidth: CGFloat?
    @State private var feedbackCount = 0

    /// Finger travel that cancels a hold.
    private static let holdTolerance: CGFloat = 10

    private var isDragged: Bool { drag.place?.id == place.id }
    private var isSlotCollapsed: Bool { drag.collapsedPlaceID == place.id }

    /// The slot is the chip plus the gap on its left. It collapses to zero width while the
    /// chip is outside the row, and it reopens when the chip returns.
    func body(content: Content) -> some View {
        content
            .opacity(isDragged ? 0 : 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drag.chipFrames[place.id] = $0 }
            .onDisappear { drag.chipFrames[place.id] = nil }
            .simultaneousGesture(hold)
            .padding(.leading, DesignTokens.Space.xs)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { setSlotWidth($0) }
            .frame(width: isSlotCollapsed ? 0 : slotWidth, alignment: .trailing)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { updateReturnCenter($0) }
            .sensoryFeedback(.impact(weight: .light), trigger: feedbackCount)
    }

    /// The first measure sets the width directly. Later changes, such as an edited name, animate.
    private func setSlotWidth(_ width: CGFloat) {
        guard slotWidth != nil else {
            slotWidth = width
            return
        }
        withAnimation(drag.slotAnimation) { slotWidth = width }
    }

    /// A hold fails when the finger moves. It tracks no press state, so it stays inactive until
    /// it succeeds and does not stop the row's scroll pan or the pull pan.
    private var hold: some Gesture {
        LongPressGesture(minimumDuration: SavedPlaceDragState.holdDuration,
                         maximumDistance: Self.holdTolerance)
            .onEnded { _ in
                drag.holdStarted()
                feedbackCount += 1
                onEdit()
            }
    }

    /// Aims the returning chip at the chip position inside this slot once the slot is open.
    private func updateReturnCenter(_ slot: CGRect) {
        guard isDragged else { return }
        let chipWidth = (slotWidth ?? slot.width) - DesignTokens.Space.xs
        drag.updateReturnCenter(CGPoint(x: slot.minX + DesignTokens.Space.xs + chipWidth / 2,
                                        y: slot.midY))
    }
}
