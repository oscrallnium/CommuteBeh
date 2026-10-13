//
//  ContentView+CommuteSheet.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import SwiftUI

// MARK: - Commute sheet

extension ContentView {
    /// The commute card. Reads only `commuteEngine`, and hands the engine to `CommuteModeView`,
    /// which reads its values in its own body.
    @ViewBuilder
    func commuteCard(cardState: Binding<CommuteCardState>, showEndAlert: Binding<Bool>) -> some View {
        if let engine = commuteEngine, let result = routeStore.routeResult {
            CommuteModeView(
                result: result,
                engine: engine,
                routeStore: routeStore,
                destinationText: destinationText,
                arrivedAt: arrivedAt,
                cardState: cardState,
                showEndAlert: showEndAlert,
                onEndCommute: { endCommute(reason: .user) }
            )
        }
    }

    /// Feeds the card's top edge to the camera as the bottom of the visible map strip.
    func followSheetTop(_ top: CGFloat) {
        visibleBottom = top
        commuteStripBottom = top
    }

    /// Stops following the passenger and frames the whole route above the sheet.
    func showRouteOverview() {
        guard let result = routeStore.routeResult else { return }
        isFollowingPassenger = false
        fitMap(to: result)
    }
}
