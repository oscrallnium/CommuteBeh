//
//  CommuteSearchPanel.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/10/26.
//

import SwiftUI

/// Which search field holds focus. Declared at file scope rather than inside a view so
/// `ContentView` and `CommuteSearchPanel` can share one `@FocusState`.
enum SearchField { case origin, destination }

// MARK: - Commute Search Panel

/// The origin and destination entry surface at the top of the Commute tab. Collapses to a
/// pill while a search runs or results show, and expands to the full card otherwise.
/// Field edits and selections call `RouteStore` directly. Only back and search, which move
/// the map camera, arrive from `ContentView` as closures.
struct CommuteSearchPanel: View {
    @Bindable var routeStore: RouteStore
    @FocusState.Binding var focusedField: SearchField?
    let namespace: Namespace.ID
    let showSearchProgress: Bool

    let onBack: () -> Void
    let onSearch: () -> Void

    // MARK: Design constants

    /// Inset the panel carries inside the top safe area. `measuresVisibleTop` adds it back
    /// so the published edge describes the panel's outer boundary, not the card within it.
    static let panelPadding: CGFloat = 16

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swapPhase: SwapPhase = .idle
    /// Counts the swaps. It turns the swap symbol and triggers the haptic.
    @State private var swapCount = 0
    /// Counts the Search Route taps. It triggers the heavy haptic.
    @State private var searchTapCount = 0
    /// The query whose empty result list has lasted `Motion.noResultsDelay`. "No Results" shows only
    /// then, so it does not flash while the address search is still running.
    @State private var settledEmptyQuery: String?
    @State private var rowDistance: CGFloat = 0
    /// Measured sizes of the card and the pill. The surface takes its frame from these, so the
    /// frame animates between them instead of following content that is fading in or out.
    @State private var cardHeight: CGFloat = Layout.initialCardHeight
    @State private var pillSize: CGSize = .zero
    /// Width the panel offers its row, and the one-line width of each pill text. They set how
    /// wide each pill text grows before it truncates. An unmeasured text counts as unbounded.
    @State private var rowWidth: CGFloat = 0
    @State private var originIdealWidth: CGFloat = .infinity
    @State private var destinationIdealWidth: CGFloat = .infinity
    /// Frames of the markers and texts in the card and in the pill, keyed by `SearchGeometryID`.
    /// The moving layer travels between the two sets.
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var pillFrames: [String: CGRect] = [:]
    /// The mode whose surface has stopped moving. It trails `mode` by `Motion.settleDuration`.
    @State private var settledMode: SearchPanelMode = .expanded

    private var mode: SearchPanelMode {
        routeStore.isLoading || !routeStore.routeOptions.isEmpty ? .collapsed : .expanded
    }

    /// Content fades out at once and fades in after the surface has grown, so it never shows
    /// on a surface that is still small.
    private var contentTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.animation(
                .easeOut(duration: Motion.fadeDuration).delay(Motion.revealDelay)
            ),
            removal: .opacity.animation(.easeOut(duration: Motion.fadeDuration))
        )
    }

    private var backTransition: AnyTransition {
        reduceMotion ? .opacity : .scale.combined(with: .opacity)
    }

    var body: some View {
        VStack(spacing: Layout.cardStackSpacing) {
            surfaceRow
            switch mode {
            case .expanded:
                expandedExtras
                    .transition(contentTransition)
            case .collapsed:
                EmptyView()
            }
        }
        .background(alignment: .topLeading) { pillSizer }
        .background(alignment: .topLeading) { idealTextSizer }
        .task(id: mode) {
            guard (try? await Task.sleep(for: .seconds(Motion.settleDuration))) != nil else { return }
            settledMode = mode
        }
        .animation(DesignTokens.Motion.suggestEnter, value: suggestionsVisible)
        .animation(editingMotion, value: isEditing)
        .task(id: pendingEmptyQuery) {
            guard let query = pendingEmptyQuery,
                  (try? await Task.sleep(for: .seconds(Motion.noResultsDelay))) != nil else { return }
            settledEmptyQuery = query
        }
        .animation(
            .spring(response: Motion.springResponse, dampingFraction: Motion.springDamping),
            value: mode
        )
    }

    // MARK: Surface (card and pill)

    private var surfaceRow: some View {
        HStack(spacing: DesignTokens.Space.sm) {
            switch mode {
            case .expanded:
                EmptyView()
            case .collapsed:
                backButton
                    .transition(backTransition)
            }
            surface
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
    }

    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: Symbol.back)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: Layout.controlSize, height: Layout.controlSize)
        }
        .buttonStyle(.plain)
        .goraGlass(.regular.interactive(), in: .circle)
        .accessibilityLabel(Strings.back)
    }

    /// One surface serves both states. Its frame comes from the measured card or pill size, and
    /// the content sits in an overlay, so a transition that keeps both contents cannot size it.
    /// Reduce Motion replaces it through `id`, which cross-fades. See `Commute-Views.md`.
    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: mode.surfaceRadius, style: .continuous)
        return Color.clear
            .frame(maxWidth: surfaceMaxWidth)
            .frame(height: surfaceHeight)
            .overlay(alignment: .topLeading) {
                surfaceContent
                    .clipShape(shape)
            }
            .overlay(alignment: .topLeading) {
                SearchMovingLayer(
                    mode: mode,
                    originText: routeStore.originText,
                    destinationText: routeStore.destinationText,
                    cardFrames: cardFrames,
                    pillFrames: pillFrames,
                    movesContent: movesContent,
                    collapsedTextWidths: pillTextWidths
                )
            }
            .goraGlass(DesignTokens.Materials.cardGlass, in: shape)
            .background(Color.charcoal.opacity(mode.tintOpacity), in: shape)
            .measuresVisibleTop(outerPadding: Self.panelPadding)
            .id(reduceMotion && mode == .collapsed)
            .transition(reduceMotion ? .opacity : .identity)
    }

    private var surfaceMaxWidth: CGFloat? {
        switch mode {
        case .expanded: .infinity
        case .collapsed: pillSize.width > 0 ? pillSize.width : nil
        }
    }

    private var surfaceHeight: CGFloat {
        switch mode {
        case .expanded: cardHeight
        case .collapsed: CommuteRoutePill.height
        }
    }

    @ViewBuilder
    private var surfaceContent: some View {
        switch mode {
        case .expanded:
            searchCard
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    withAnimation(editingMotion) { cardHeight = height }
                }
                .transition(contentTransition)
        case .collapsed:
            CommuteRoutePill(
                originText: routeStore.originText,
                destinationText: routeStore.destinationText,
                textWidths: pillTextWidths,
                hidesMovingContent: movesContent,
                frames: .constant([:])
            )
            .fixedSize()
            .transition(contentTransition)
        }
    }

    /// An invisible pill that measures the collapsed size before the first collapse.
    private var pillSizer: some View {
        CommuteRoutePill(
            originText: routeStore.originText,
            destinationText: routeStore.destinationText,
            textWidths: pillTextWidths,
            hidesMovingContent: false,
            frames: $pillFrames
        )
        .fixedSize()
        .hidden()
        .accessibilityHidden(true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { pillSize = $0 }
    }

    /// Invisible one-line texts that measure how wide each pill text wants to be.
    private var idealTextSizer: some View {
        HStack {
            CommuteRoutePill.label(routeStore.originText)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { originIdealWidth = $0 }
            CommuteRoutePill.label(routeStore.destinationText)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { destinationIdealWidth = $0 }
        }
        .hidden()
        .accessibilityHidden(true)
    }

    /// The row width minus the back button and its gap is all the pill can use.
    private var pillTextWidths: CommuteRoutePill.TextWidths {
        CommuteRoutePill.textWidths(
            availablePillWidth: rowWidth - Layout.controlSize - DesignTokens.Space.sm,
            originIdeal: originIdealWidth,
            destinationIdeal: destinationIdealWidth
        )
    }

    private var originMarker: some View {
        cardMarker(.origin, id: SearchGeometryID.originDot)
    }

    private var destinationMarker: some View {
        cardMarker(.destination, id: SearchGeometryID.destinationDot)
    }

    private func cardMarker(_ kind: SearchMarker.Kind, id: String) -> some View {
        SearchMarker(kind: kind)
            .reportsFrame(id, in: CoordinateSpaces.card, to: $cardFrames)
            .snapsOpacity(!movesContent)
    }

    /// True from the start of a mode change until the card settles. The layer draws the markers
    /// and texts then, and the card and the pill hide theirs. Reduce Motion keeps the cross-fade.
    private var movesContent: Bool {
        !reduceMotion && !(mode == .expanded && settledMode == .expanded)
    }

    // MARK: Expanded card (default search state)

    @ViewBuilder
    private var expandedExtras: some View {
        errorMessage
        savedPlaces
        suggestionLists
    }

    /// Search Route folds away while a field has focus. The results list takes its place.
    private var searchCard: some View {
        VStack(spacing: 0) {
            fieldsGroup
            if !isEditing {
                actionRow
                    .transition(.opacity)
            }
        }
        .padding(.top, Layout.cardTopPadding)
        .coordinateSpace(name: CoordinateSpaces.card)
    }

    /// The two rows share one trailing control. The swap button sits on the divider and acts on both rows.
    /// While a field has focus, the swap button hides and that field shows its clear button.
    private var fieldsGroup: some View {
        VStack(spacing: 0) {
            originRow
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    rowDistance = $0 + SearchFieldSeparator.height
                }

            SearchFieldSeparator()
                .padding(.leading, Layout.dividerLeadingInset)
                .padding(.trailing, Layout.dividerTrailingInset)

            destinationRow
        }
        .overlay(alignment: .leading) {
            SearchFieldRail(length: max(rowDistance - Layout.markerColumnWidth - 2 * Layout.railGap, 0))
                .padding(.leading, Layout.fieldHorizontalPadding + (Layout.markerColumnWidth - SearchFieldRail.width) / 2)
        }
        .overlay(alignment: .trailing) {
            swapButton
                .padding(.trailing, Layout.swapTrailingInset)
                .opacity(showsSwap ? 1 : 0)
                .allowsHitTesting(showsSwap)
                .accessibilityHidden(!showsSwap)
        }
        .animation(.easeOut(duration: Motion.fadeDuration), value: showsSwap)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.routeGroup)
    }

    /// Only one trailing control shows at a time: the swap button, a clear button, or a progress view.
    private var showsSwap: Bool {
        focusedField == nil && !routeStore.isResolvingOrigin && !routeStore.isResolvingDestination
    }

    private var originRow: some View {
        fieldRow(
            marker: originMarker,
            placeholder: Strings.originPlaceholder,
            text: $routeStore.originText,
            textID: SearchGeometryID.originText,
            field: .origin,
            contentOffset: swapPhase == .sliding ? rowDistance : 0,
            accessory: SearchFieldAccessory(
                isResolving: routeStore.isResolvingOrigin,
                hasText: focusedField == .origin && !routeStore.originText.isEmpty,
                onClear: { routeStore.clear(.origin) }
            ),
            onTextChange: { routeStore.updateOriginSuggestions($0) }
        )
    }

    private var destinationRow: some View {
        fieldRow(
            marker: destinationMarker,
            placeholder: Strings.destinationPlaceholder,
            text: $routeStore.destinationText,
            textID: SearchGeometryID.destinationText,
            field: .destination,
            contentOffset: swapPhase == .sliding ? -rowDistance : 0,
            accessory: SearchFieldAccessory(
                isResolving: routeStore.isResolvingDestination,
                hasText: focusedField == .destination && !routeStore.destinationText.isEmpty,
                onClear: { routeStore.clear(.destination) }
            ),
            onTextChange: { routeStore.updateDestSuggestions($0) }
        )
    }

    /// The field reports its frame under `textID`. While the moving layer draws the text, the
    /// field hides its text unless it is empty, so the placeholder stays.
    private func fieldRow(
        marker: some View,
        placeholder: LocalizedStringKey,
        text: Binding<String>,
        textID: String,
        field: SearchField,
        contentOffset: CGFloat,
        accessory: some View,
        onTextChange: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: Layout.fieldSpacing) {
            marker
                .frame(width: Layout.markerColumnWidth)
            TextField(placeholder, text: text)
                .font(.body)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(closeResults)
                .focused($focusedField, equals: field)
                .onChange(of: text.wrappedValue) { _, val in onTextChange(val) }
                .reportsFrame(textID, in: CoordinateSpaces.card, to: $cardFrames)
                .snapsOpacity(!movesContent || text.wrappedValue.isEmpty)
                .offset(y: contentOffset)
                .opacity(swapPhase == .fading ? 0 : 1)
            accessory
        }
        .padding(.horizontal, Layout.fieldHorizontalPadding)
        .padding(.vertical, Layout.fieldVerticalPadding)
    }

    private var actionRow: some View {
        searchButton
        .padding(.horizontal, Layout.actionRowHorizontalPadding)
        .padding(.top, Layout.actionRowTopPadding)
        .padding(.bottom, Layout.actionRowBottomPadding)
    }

    /// A heavy haptic confirms the main action.
    private var searchButton: some View {
        Button {
            searchTapCount += 1
            onSearch()
        } label: {
            Text(Strings.searchRoute)
                .typeScale(.controlLabel)
                .opacity(showSearchProgress ? 0 : 1)
                .overlay {
                    if showSearchProgress {
                        ProgressView().tint(Color.cocoa)
                    }
                }
            .foregroundStyle(DesignTokens.Colors.onAction)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Layout.searchButtonVerticalPadding)
//            .background(Capsule().fill(DesignTokens.Colors.action))
        }
        .buttonStyle(.glassProminent)
        .tint(DesignTokens.Colors.action)
        .disabled(!routeStore.canCalculate || routeStore.isLoading)
        .opacity(!routeStore.canCalculate ? Layout.disabledOpacity : 1)
        .animation(DesignTokens.Motion.disclose, value: routeStore.canCalculate)
        .sensoryFeedback(.impact(weight: .heavy, intensity: 1), trigger: searchTapCount)
    }

    /// A secondary control: a gray circle with a blue symbol, and a 44 pt touch target.
    /// The symbol turns 180 degrees on each swap. Reduce Motion keeps it still.
    private var swapButton: some View {
        Button(action: swap) {
            Image(systemName: Symbol.swap)
                .font(.system(size: Layout.swapIconSize, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.secondaryAction)
                .rotationEffect(.degrees(reduceMotion ? 0 : Double(swapCount) * 180))
                .frame(width: Layout.swapCircleSize, height: Layout.swapCircleSize)
                .background(DesignTokens.Colors.secondaryActionFill, in: .circle)
                .frame(width: Layout.controlSize, height: Layout.controlSize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!canSwap || swapPhase != .idle)
        .opacity(canSwap ? 1 : Layout.disabledOpacity)
        .sensoryFeedback(.impact(weight: .light), trigger: swapCount)
        .accessibilityLabel(Strings.swap)
    }

    private var canSwap: Bool {
        !routeStore.originText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !routeStore.destinationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Slides the two texts past each other, or fades them when Reduce Motion is on. The swap
    /// runs once the animation ends, and the reset runs without animation so no reverse plays.
    private func swap() {
        guard swapPhase == .idle else { return }
        // An unfocused field shows the start of a long text; a focused field scrolls to its end.
        focusedField = nil
        if reduceMotion {
            swapCount += 1
            withAnimation(.easeOut(duration: Motion.fadeDuration)) {
                swapPhase = .fading
            } completion: {
                routeStore.swapEndpoints()
                announceSwap()
                withAnimation(.easeIn(duration: Motion.fadeDuration)) { swapPhase = .idle }
            }
        } else {
            withAnimation(.snappy(duration: Motion.swapDuration)) {
                swapPhase = .sliding
                swapCount += 1
            } completion: {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    routeStore.swapEndpoints()
                    swapPhase = .idle
                }
                announceSwap()
            }
        }
    }

    /// VoiceOver confirms the swap, so the motion is not the only signal.
    private func announceSwap() {
        let message = String(localized: "Swapped. Start, \(routeStore.originText). Destination, \(routeStore.destinationText).")
        AccessibilityNotification.Announcement(message).post()
    }

    @ViewBuilder
    private var errorMessage: some View {
        if let error = routeStore.errorMessage {
            Text(error)
                .typeScale(.meta)
                .foregroundStyle(Color.vermilion)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Layout.errorHorizontalPadding)
        }
    }

    /// Saved places stay while a field has focus. They hide only while the results list or No Results shows.
    @ViewBuilder
    private var savedPlaces: some View {
        if !suggestionsVisible && !showsNoResults {
            SavedPlacesRow(
                routeStore: routeStore,
                focusedField: $focusedField
            )
            .padding(.top, Layout.savedPlacesTopPadding)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var suggestionLists: some View {
        if routeStore.showOriginSuggestions && !routeStore.originSuggestions.isEmpty {
            suggestionDropdown(routeStore.originSuggestions, query: routeStore.originText, field: .origin)
        } else if routeStore.showDestSuggestions && !routeStore.destSuggestions.isEmpty {
            suggestionDropdown(routeStore.destSuggestions, query: routeStore.destinationText, field: .destination)
        } else if showsNoResults {
            SearchSuggestionDropdown.noResults
                .transition(SearchSuggestionDropdown.transition(reduceMotion: reduceMotion))
        }
    }

    private func suggestionDropdown(
        _ suggestions: [LocationSuggestion],
        query: String,
        field: SearchField
    ) -> some View {
        SearchSuggestionDropdown(
            suggestions: suggestions,
            query: query,
            userLocation: routeStore.userLocation,
            lineName: routeStore.lineDisplayName
        ) { suggestion in
            select(suggestion, for: field)
        }
        .transition(SearchSuggestionDropdown.transition(reduceMotion: reduceMotion))
    }

    /// The Done key drops the focus and removes the results list. The field keeps its text.
    private func closeResults() {
        focusedField = nil
        routeStore.showOriginSuggestions = false
        routeStore.showDestSuggestions = false
    }

    /// True while a field has focus. The card hides Search Route, and the screen hides the tab bar.
    private var isEditing: Bool { focusedField != nil }

    private var editingMotion: Animation {
        reduceMotion ? .easeInOut(duration: Motion.fadeDuration) : .spring(duration: Motion.resultsDuration)
    }

    /// The focused field's text when its search is open and has no rows. Nil otherwise.
    private var pendingEmptyQuery: String? {
        switch focusedField {
        case .origin where routeStore.showOriginSuggestions && routeStore.originSuggestions.isEmpty:
            routeStore.originText
        case .destination where routeStore.showDestSuggestions && routeStore.destSuggestions.isEmpty:
            routeStore.destinationText
        default:
            nil
        }
    }

    /// True while the No Results view shows: the empty query has settled.
    private var showsNoResults: Bool {
        guard let query = pendingEmptyQuery else { return false }
        return query == settledEmptyQuery
    }

    /// Origin selection moves focus to the destination. Destination selection drops focus.
    private func select(_ suggestion: LocationSuggestion, for field: SearchField) {
        Task {
            guard await routeStore.select(suggestion, for: field) else { return }
            focusedField = field == .origin ? .destination : nil
        }
    }

    private var suggestionsVisible: Bool {
        (routeStore.showOriginSuggestions && !routeStore.originSuggestions.isEmpty) ||
        (routeStore.showDestSuggestions && !routeStore.destSuggestions.isEmpty)
    }
}

// MARK: - Constants

/// The swap button animation state: at rest, texts sliding past each other, or texts faded out.
private enum SwapPhase { case idle, sliding, fading }

private enum Motion {
    static let swapDuration: Double = 0.35
    static let fadeDuration: Double = 0.15
    static let springResponse: Double = 0.45
    static let springDamping: Double = 0.85
    /// The results list and Search Route move with this spring when a field gains or loses focus.
    static let resultsDuration: Double = 0.38
    static let noResultsDelay: Double = 0.8
    /// Time the spring needs to come to rest.
    static let settleDuration: Double = springResponse * 1.5
    /// Wait before inserted content fades in: about half the spring response, when the surface is nearly full size.
    static let revealDelay: Double = springResponse * 0.55
}

private enum Layout {
    static let controlSize: CGFloat = 44
    /// Width of the marker column in a field row. It equals the larger marker, so both texts start at the same x.
    static let markerColumnWidth: CGFloat = 11
    /// Card height used until the first measurement replaces it.
    static let initialCardHeight: CGFloat = 230
    static let cardStackSpacing: CGFloat = 6
    static let savedPlacesTopPadding: CGFloat = 6
    static let fieldSpacing: CGFloat = 14
    static let fieldHorizontalPadding: CGFloat = 18
    static let fieldVerticalPadding: CGFloat = 15
    static let cardTopPadding: CGFloat = 8
    static let errorHorizontalPadding: CGFloat = 18
    static let actionRowHorizontalPadding: CGFloat = 8
    static let actionRowTopPadding: CGFloat = 8
    static let actionRowBottomPadding: CGFloat = 8
    static let searchButtonVerticalPadding: CGFloat = 15
    static let disabledOpacity: Double = 0.55
    static let swapCircleSize: CGFloat = 36
    static let swapIconSize: CGFloat = 17
    /// The swap target's gap to the card edge. The row's trailing padding, accessory, and spacing
    /// (18 + 22 + 14 = 54 pt) keep the text clear of the 44 pt target.
    static let swapTrailingInset: CGFloat = 8
    /// The divider starts under the text: row padding, marker column, and spacing.
    static let dividerLeadingInset: CGFloat = fieldHorizontalPadding + markerColumnWidth + fieldSpacing
    /// The divider ends before the swap target.
    static let dividerTrailingInset: CGFloat = swapTrailingInset + controlSize + 2
    /// Space between a marker and each end of the dotted rail.
    static let railGap: CGFloat = 6
}

private enum Strings {
    static let originPlaceholder: LocalizedStringKey = "Start"
    static let destinationPlaceholder: LocalizedStringKey = "Destination"
    static let searchRoute: LocalizedStringKey = "Search Route"
    static let back: LocalizedStringKey = "Back"
    static let swap: LocalizedStringKey = "Swap start and destination"
    static let routeGroup: LocalizedStringKey = "Route"
}

private enum CoordinateSpaces {
    static let card = "search-card"
}

private enum Symbol {
    static let back = "chevron.left"
    static let swap = "arrow.up.arrow.down"
}
