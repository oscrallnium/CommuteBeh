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

    private enum Layout {
        static let bannerGap = DesignTokens.Space.s
        static let bannerSubtitleRoute = "The map can’t show where you are."
        static let bannerSubtitleCommute = "Tap each step as you go."
    }

    /// The search panel before a commute. In Commute Mode the map reads as full-bleed with the
    /// bottom card, plus the Location-off banner while Location is off.
    @ViewBuilder
    var searchPanel: some View {
        if isCommuting {
            commuteLocationBanner
        } else {
            CommuteSearchPanel(
                routeStore: routeStore,
                focusedField: $focusedField,
                namespace: searchNS,
                showSearchProgress: showSearchProgress,
                onBack: closeRouteResults,
                onSearch: search
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

    /// The banner under the status bar. It stays while Location is off, and hides once the commute ends.
    private var commuteLocationBanner: some View {
        let isShown = routeStore.locationAccess == .off && arrivedAt == nil
        return Group {
            if isShown {
                LocationOffBanner(subtitle: Layout.bannerSubtitleCommute, onDismiss: nil)
                    .padding(.horizontal, DesignTokens.Space.l)
                    .padding(.top, Layout.bannerGap)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { visibleTop = $0 }
                    .onDisappear { if isCommuting { visibleTop = 0 } }
                    .transition(DesignTokens.Motion.locationBanner(from: .top, reduceMotion: reduceMotion))
            }
        }
        .animation(DesignTokens.Motion.locationState, value: isShown)
    }

    private var showsRouteBanner: Bool {
        routeStore.locationAccess == .off && !isRouteBannerDismissed
    }

    @ViewBuilder
    var routeChoicePanel: some View {
        if !routeStore.routeOptions.isEmpty {
            VStack(spacing: Layout.bannerGap) {
                if showsRouteBanner {
                    LocationOffBanner(subtitle: Layout.bannerSubtitleRoute,
                                      onDismiss: { isRouteBannerDismissed = true })
                        .transition(DesignTokens.Motion.locationBanner(from: .bottom, reduceMotion: reduceMotion))
                }
                RouteChoiceSheet(
                    options: routeStore.routeOptions,
                    selectedID: $routeChoice.selectedID,
                    isDetailExpanded: $routeChoice.isDetailExpanded,
                    canStartCommute: canStartCommute,
                    onUse: { startCommute(with: $0) }, legColor: routeStore.legColor
                )
            }
            .animation(DesignTokens.Motion.locationState, value: showsRouteBanner)
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
