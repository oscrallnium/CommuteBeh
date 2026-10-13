//
//  CommuteSheetPresentation.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import SwiftUI
import UIKit

// MARK: - Card state

/// The two heights of the commute card. The collapsed card shows the header. The expanded card
/// adds the hairline and the leg list.
enum CommuteCardState {
    case collapsed
    case expanded

    var height: CGFloat { self == .collapsed ? CommuteSheetHeight.collapsed : CommuteSheetHeight.expanded }
}

/// Commute card heights, scaled with Dynamic Type.
enum CommuteSheetHeight {
    /// Height of the header alone.
    static var collapsed: CGFloat { scaled(76) }
    /// Height of the header, the hairline and the leg list.
    static var expanded: CGFloat { scaled(276.5) }
    /// Halfway between the two states. A taller card shows its leg list fully during a drag.
    static var midpoint: CGFloat { (collapsed + expanded) / 2 }

    private static func scaled(_ value: CGFloat) -> CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: value)
    }
}

extension View {
    /// Floats the commute card over the map while `isActive` is true, and floats the map controls above it.
    /// `onSheetTopChange` receives the card's settled top edge in window coordinates, and 0 when it hides.
    func commuteSheet<Card: View>(
        isActive: Bool,
        cameraMode: Binding<CommuteCameraMode>,
        isFollowing: Binding<Bool>,
        onRouteOverview: @escaping () -> Void,
        onSheetTopChange: @escaping (CGFloat) -> Void,
        @ViewBuilder card: @escaping (Binding<CommuteCardState>, Binding<Bool>) -> Card
    ) -> some View {
        modifier(CommuteSheetPresentation(
            isActive: isActive, cameraMode: cameraMode, isFollowing: isFollowing,
            onRouteOverview: onRouteOverview, onSheetTopChange: onSheetTopChange, card: card))
    }
}

// MARK: - Presentation

/// Owns the card state, its measured top edge and the End Commute alert flag. The control
/// column lives outside the card because the card clips its content.
struct CommuteSheetPresentation<Card: View>: ViewModifier {
    let isActive: Bool
    @Binding var cameraMode: CommuteCameraMode
    @Binding var isFollowing: Bool
    let onRouteOverview: () -> Void
    let onSheetTopChange: (CGFloat) -> Void
    @ViewBuilder let card: (Binding<CommuteCardState>, Binding<Bool>) -> Card

    @State private var cardState: CommuteCardState = .collapsed
    @State private var sheetTop: CGFloat = 0
    @State private var isMerged = false
    /// The settled card top in the collapsed state. `nil` until the first measure.
    @State private var collapsedTop: CGFloat?
    @State private var showEndAlert = false
    @State private var settleTask: Task<Void, Never>?

    /// Gap between the control column and the sheet's top edge.
    private let columnGap: CGFloat = DesignTokens.Space.ml
    /// Time the sheet top must stay unchanged before the camera receives it.
    private let settleDelay: Duration = .milliseconds(120)
    /// Gap between the control column and the trailing screen edge.
    private let columnInset: CGFloat = DesignTokens.Space.l
    /// Distance the sheet top must rise above `collapsedTop` before the column merges.
    private let mergeStartOffset: CGFloat = 4
    /// A larger change of the card top between two measures is a state animation, not a drag.
    private let jumpThreshold: CGFloat = 24
    /// Moves the column to a jumped card top in step with the card's own snap animation.
    private let sheetJumpAnimation: Animation = DesignTokens.Motion.cardEnter

    func body(content: Content) -> some View {
        content
            .overlay { controlColumn }
            .overlay { cardLayer }
            .onChange(of: isActive) { _, active in
                if active {
                    cardState = .collapsed
                    isMerged = false
                } else {
                    settleTask?.cancel()
                    sheetTop = 0
                    collapsedTop = nil
                    onSheetTopChange(0)
                }
            }
    }

    /// The card sits 16 pt from the left, right and bottom screen edges. The layer ignores the
    /// safe area so the bottom gap is measured from the physical edge.
    private var cardLayer: some View {
        ZStack(alignment: .bottom) {
            if isActive {
                card($cardState, $showEndAlert)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top in
                        let isFirstMeasure = sheetTop == 0
                        if isFirstMeasure { collapsedTop = top }
                        moveColumn(toTop: top, isFirstMeasure: isFirstMeasure)
                        updateMerge(forTop: top)
                        reportSettledTop(top, immediately: isFirstMeasure)
                    }
                    .padding(.horizontal, DesignTokens.Space.l)
                    .padding(.bottom, DesignTokens.Space.l)
                    .transition(.move(edge: .bottom))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea()
        .animation(DesignTokens.Motion.cardEnter, value: isActive)
    }

    @ViewBuilder
    private var controlColumn: some View {
        if isActive, sheetTop > 0 {
            GeometryReader { geo in
                CommuteControlColumn(
                    cameraMode: $cameraMode, isFollowing: $isFollowing, isMerged: isMerged,
                    onRouteOverview: onRouteOverview, onTripDetails: showTripDetails,
                    onEndCommute: { showEndAlert = true })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, columnInset)
                    .padding(.bottom, max(0, geo.size.height - sheetTop) + columnGap)
            }
            .ignoresSafeArea()
        }
    }

    /// Reports the top once it stops changing for `settleDelay`, so the camera and the map do
    /// not update on every frame of a state animation.
    private func reportSettledTop(_ top: CGFloat, immediately: Bool) {
        settleTask?.cancel()
        if immediately {
            onSheetTopChange(top)
            return
        }
        settleTask = Task {
            try? await Task.sleep(for: settleDelay)
            guard !Task.isCancelled else { return }
            if cardState == .collapsed { collapsedTop = top }
            onSheetTopChange(top)
        }
    }

    /// Follows a drag frame by frame. A jump animates in a later main-actor task, because the
    /// card reports its final top at the start of a snap and the transaction has no animation.
    private func moveColumn(toTop top: CGFloat, isFirstMeasure: Bool) {
        guard !isFirstMeasure, abs(top - sheetTop) > jumpThreshold else {
            sheetTop = top
            return
        }
        Task { @MainActor in
            withAnimation(sheetJumpAnimation) { sheetTop = top }
        }
    }

    /// Merges the column as soon as the card top leaves `collapsedTop`, and splits it on return.
    /// The change runs in a later main-actor task, because the drag's transaction turns off
    /// animations and `withAnimation` inside it does not animate.
    private func updateMerge(forTop top: CGFloat) {
        guard let collapsedTop else { return }
        let shouldMerge = top < collapsedTop - mergeStartOffset
        guard shouldMerge != isMerged else { return }
        Task { @MainActor in
            withAnimation(DesignTokens.Motion.controlMorph) { isMerged = shouldMerge }
        }
    }

    private func showTripDetails() {
        withAnimation(DesignTokens.Motion.cardEnter) { cardState = .expanded }
    }
}
