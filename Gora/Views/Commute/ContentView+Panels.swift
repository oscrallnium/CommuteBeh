//
//  ContentView+Panels.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/14/26.
//

import SwiftUI

// MARK: - Panels
// These members are internal because `ContentView.body` places them in its safe-area insets.

extension ContentView {

    /// Dropped entirely in Commute Mode — the map reads as full-bleed with
    /// just the bottom card, matching the reference UI.
    @ViewBuilder
    var searchPanel: some View {
        if !isCommuting {
            CommuteSearchPanel(
                routeStore: routeStore,
                originText: $originText,
                destinationText: $destinationText,
                focusedField: $focusedField,
                namespace: searchNS,
                showSearchProgress: showSearchProgress,
                onReset: resetAll,
                onSearch: search,
                onSwap: swapOriginDestination,
                onClearOrigin: clearOrigin,
                onClearDestination: clearDestination,
                onSelectOrigin: selectOrigin,
                onSelectDestination: selectDestination
            )
            .padding(CommuteSearchPanel.panelPadding)
                // The measurement is published from the card/pill itself, not from
                // here — see `measuresVisibleTop`. Reading the padded panel's own
                // frame would fold the suggestion list into it.
                .onPreferenceChange(VisibleTopKey.self) { newValue in
                    #if DEBUG
                    print("[CameraDebug] visibleTop \(visibleTop) -> \(newValue) t=\(Date().timeIntervalSince1970)")
                    #endif
                    visibleTop = newValue; placeRouteBubble()
                }
        }
    }

    @ViewBuilder
    var routeChoicePanel: some View {
        if !routeStore.routeOptions.isEmpty {
            RouteChoiceSheet(
                options: routeStore.routeOptions,
                selectedID: $routeChoice.selectedID,
                isDetailExpanded: $routeChoice.isDetailExpanded,
                canStartCommute: canStartCommute,
                onUse: { startCommute(with: $0) }, legColor: routeStore.legColor
            )
            .padding(.horizontal)
            .padding(.bottom)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: VisibleBottomKey.self,
                                           value: geo.frame(in: .global).minY)
                }
            )
            .onPreferenceChange(VisibleBottomKey.self) { newValue in
                #if DEBUG
                print("[CameraDebug] visibleBottom(routeResults) \(visibleBottom) -> \(newValue) t=\(Date().timeIntervalSince1970)")
                #endif
                visibleBottom = newValue; placeRouteBubble()
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
