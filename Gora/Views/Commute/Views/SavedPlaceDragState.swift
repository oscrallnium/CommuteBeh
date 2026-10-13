//
//  SavedPlaceDragState.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import SwiftUI

/// The state of one saved-place chip drag. The row writes the finger position, and the screen
/// overlay reads it to draw the moving chip and the delete target. All frames use the global space.
@Observable
@MainActor
final class SavedPlaceDragState {
    enum Phase { case idle, dragging, deleting, returning }

    static let holdDuration: TimeInterval = 0.3
    static let hoverRadius: CGFloat = 56
    static let deleteDuration: TimeInterval = 0.25
    static let returnDuration: TimeInterval = 0.5
    private static let rowExitSlop: CGFloat = 20
    private static let tapGuardInterval: TimeInterval = 0.3

    private(set) var phase: Phase = .idle
    private(set) var isHolding = false
    private(set) var place: SavedPlace?
    private(set) var isSelected = false
    private(set) var isHovering = false
    private(set) var isOutsideRow = false
    private(set) var chipFrame: CGRect = .zero
    private(set) var dragCenter: CGPoint = .zero
    /// Where the returning chip lands: the center of its row slot, updated while the slot reopens.
    private(set) var returnCenter: CGPoint = .zero
    /// The place whose row slot is closed. It changes only inside `withAnimation`, so the whole
    /// row slides with the slot.
    private(set) var collapsedPlaceID: SavedPlace.ID?

    /// Set by the row and the overlay. Layout writes them, so views do not observe them.
    @ObservationIgnored var rowFrame: CGRect = .zero
    @ObservationIgnored var targetCenter: CGPoint = .zero
    @ObservationIgnored var reducesMotion = false
    /// Global frame of each chip in the row. The pan recognizer reads it to find the touched chip.
    @ObservationIgnored var chipFrames: [SavedPlace.ID: CGRect] = [:]

    @ObservationIgnored private var grabOffset: CGSize = .zero
    @ObservationIgnored private var hasGrab = false
    @ObservationIgnored private var lastDragEnd: Date = .distantPast

    /// The animation of the slot, the row and the returning chip. The spring matches
    /// `DesignTokens.Motion.cardEnter` so they all land together.
    var slotAnimation: Animation {
        reducesMotion ? .easeOut(duration: 0.15) : DesignTokens.Motion.cardEnter
    }

    var showsTarget: Bool {
        (phase == .dragging && isOutsideRow) || phase == .deleting
    }

    /// The chip center for the current phase: the finger, the target, or the reopened slot.
    var displayCenter: CGPoint {
        switch phase {
        case .idle, .dragging: dragCenter
        case .deleting: targetCenter
        case .returning: returnCenter
        }
    }

    /// True during a hold or drag and just after it, so the release does not also select the chip.
    var swallowsTap: Bool {
        phase != .idle || isHolding || Date().timeIntervalSince(lastDragEnd) < Self.tapGuardInterval
    }

    func chipID(at point: CGPoint) -> SavedPlace.ID? {
        chipFrames.first { $0.value.contains(point) }?.key
    }

    func holdStarted() { isHolding = true }

    func holdEnded() {
        isHolding = false
        lastDragEnd = Date()
    }

    func begin(place: SavedPlace, isSelected: Bool, chipFrame: CGRect) {
        guard phase == .idle else { return }
        self.place = place
        self.isSelected = isSelected
        self.chipFrame = chipFrame
        dragCenter = CGPoint(x: chipFrame.midX, y: chipFrame.midY)
        returnCenter = dragCenter
        grabOffset = .zero
        hasGrab = false
        phase = .dragging
    }

    func updateReturnCenter(_ center: CGPoint) {
        returnCenter = center
    }

    /// Moves the chip so the point first touched stays under the finger.
    func move(to location: CGPoint) {
        guard phase == .dragging else { return }
        if !hasGrab {
            grabOffset = CGSize(width: location.x - chipFrame.midX, height: location.y - chipFrame.midY)
            hasGrab = true
        }
        dragCenter = CGPoint(x: location.x - grabOffset.width, y: location.y - grabOffset.height)
        isOutsideRow = !rowFrame.insetBy(dx: 0, dy: -Self.rowExitSlop).contains(dragCenter)
        isHovering = isOutsideRow
            && hypot(dragCenter.x - targetCenter.x, dragCenter.y - targetCenter.y) <= Self.hoverRadius
        setCollapsed(isOutsideRow)
    }

    private static var instantTransaction: Transaction {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        return transaction
    }

    /// Ends the drag. Over the target, `onDelete` runs after the chip reaches it, without
    /// animation, because the chip is hidden and its slot is closed.
    func release(onDelete: @escaping () -> Void) {
        guard phase == .dragging else { return }
        lastDragEnd = Date()
        if isHovering {
            phase = .deleting
            Task {
                try? await Task.sleep(for: .seconds(Self.deleteDuration))
                withTransaction(Self.instantTransaction) { onDelete() }
                reset()
            }
        } else {
            isHovering = false
            withAnimation(slotAnimation) {
                phase = .returning
                collapsedPlaceID = nil
            }
            Task {
                try? await Task.sleep(for: .seconds(Self.returnDuration))
                reset()
            }
        }
    }

    private func setCollapsed(_ isCollapsed: Bool) {
        let id = isCollapsed ? place?.id : nil
        guard id != collapsedPlaceID else { return }
        withAnimation(slotAnimation) { collapsedPlaceID = id }
    }

    private func reset() {
        phase = .idle
        collapsedPlaceID = nil
        place = nil
        isHovering = false
        isOutsideRow = false
    }
}
