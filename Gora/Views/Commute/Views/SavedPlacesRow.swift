//
//  SavedPlacesRow.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import SwiftUI

/// The row of saved-place chips under the search card. The Add Place chip stays pinned at the
/// trailing edge. The saved places scroll behind it, newest on the left and oldest next to it.
/// A chip counts as selected while the destination holds that place's name and coordinates.
struct SavedPlacesRow: View {
    let routeStore: RouteStore
    @Binding var destinationText: String
    @FocusState.Binding var focusedField: SearchField?
    let onClearDestination: () -> Void
    let onSearch: () -> Void

    @Environment(SavedPlacesStore.self) private var store
    @Environment(SavedPlaceDragState.self) private var drag
    @State private var showsAddPlace = false
    @State private var editingPlace: SavedPlace?
    @State private var addChipWidth: CGFloat = 110
    @State private var hasChipBehindAdd = false
    @State private var liftCount = 0

    /// Scroll distance under which the content counts as resting at its trailing end.
    private static let restTolerance: CGFloat = 4
    /// The search panel pads the row by this much. The row bleeds through it so chips scroll
    /// to the screen edge.
    private static let bleed = CommuteSearchPanel.panelPadding

    var body: some View {
        ZStack(alignment: .trailing) {
            chipScroll
            addChip
        }
        .padding(.horizontal, -Self.bleed)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drag.rowFrame = $0 }
        .sensoryFeedback(.impact(weight: .light), trigger: liftCount)
        .sheet(isPresented: $showsAddPlace) {
            AddPlaceSheet(routeStore: routeStore, onSave: store.add)
        }
        // The hold guard clears when the edit sheet closes, so the release tap never selects the chip.
        .sheet(item: $editingPlace, onDismiss: drag.holdEnded) { place in
            AddPlaceSheet(routeStore: routeStore, editing: place) { update($0, replacing: place) }
        }
    }

    private var chipScroll: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(store.places.reversed()) { place in
                    placeChip(place)
                }
            }
            .background(panInstaller)
        }
        .contentMargins(.leading, Self.bleed, for: .scrollContent)
        .contentMargins(.trailing, addChipWidth + DesignTokens.Space.xs + Self.bleed, for: .scrollContent)
        .defaultScrollAnchor(.trailing)
        .scrollIndicators(.hidden)
        .scrollDisabled(drag.phase != .idle)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let hiddenWidth = geometry.contentSize.width + geometry.contentInsets.trailing
                - geometry.containerSize.width - geometry.contentOffset.x
            return hiddenWidth > Self.restTolerance
        } action: { _, isBehind in hasChipBehindAdd = isBehind }
    }

    // MARK: Chips

    private func placeChip(_ place: SavedPlace) -> some View {
        let isSelected = isSelected(place)
        return Button { toggle(place) } label: {
            SavedPlaceChipLabel(icon: place.icon.systemImage, iconSize: 17, title: place.name,
                                isSelected: isSelected)
        }
        .buttonStyle(.plain)
        // Not interactive: interactive glass tracks the touch itself, which stops the row's
        // scroll pan and the vertical pull pan from starting on a chip.
        .glassEffect(.clear, in: .capsule)
        .animation(DesignTokens.Motion.disclose, value: isSelected)
        .savedPlaceDragSource(place: place, onEdit: { editingPlace = place })
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Edit") { editingPlace = place }
        .accessibilityAction(named: "Remove") { remove(place) }
    }

    private var addChip: some View {
        Button { showsAddPlace = true } label: {
            SavedPlaceChipLabel(icon: "plus", iconSize: 15, title: "Add Place", isSelected: false)
        }
        .buttonStyle(.plain)
        .background(Capsule().fill(Color(.secondarySystemBackground)).opacity(hasChipBehindAdd ? 0.92 : 0))
        .glassEffect(.clear.interactive(), in: .capsule)
        .animation(DesignTokens.Motion.disclose, value: hasChipBehindAdd)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { addChipWidth = $0 }
        .padding(.trailing, Self.bleed)
    }

    // MARK: Lift

    private var panInstaller: some View {
        SavedPlacesPanInstaller(chipID: drag.chipID(at:), onBegan: liftChip,
                                onChanged: drag.move(to:), onEnded: dropChip)
    }

    private func liftChip(_ id: SavedPlace.ID, at location: CGPoint) {
        guard drag.phase == .idle, let place = store.places.first(where: { $0.id == id }) else { return }
        drag.begin(place: place, isSelected: isSelected(place), chipFrame: drag.chipFrames[id] ?? .zero)
        drag.move(to: location)
        liftCount += 1
    }

    private func dropChip() {
        guard let place = drag.place else { return }
        drag.release { removeDropped(place) }
    }

    // MARK: Selection

    private func isSelected(_ place: SavedPlace) -> Bool {
        routeStore.destinationCoordinate == place.coordinates
            && routeStore.confirmedDestLabel == place.name
    }

    /// Fills the destination with the place and searches when a start is set. A tap on the
    /// selected place clears the destination.
    private func toggle(_ place: SavedPlace) {
        if drag.swallowsTap { return }
        if isSelected(place) {
            onClearDestination()
            return
        }
        fillDestination(with: place)
        if routeStore.canCalculate { onSearch() }
    }

    private func fillDestination(with place: SavedPlace) {
        routeStore.destDebounce?.cancel()
        routeStore.setDestinationCoordinate(place.coordinates)
        routeStore.confirmedDestLabel = place.name
        routeStore.destSuggestions = []
        routeStore.showDestSuggestions = false
        destinationText = place.name
        focusedField = nil
    }

    /// Saves the edit. A place that is the selected destination refreshes the destination too.
    private func update(_ place: SavedPlace, replacing old: SavedPlace) {
        let wasSelected = isSelected(old)
        withAnimation(drag.slotAnimation) { store.update(place) }
        if wasSelected { fillDestination(with: place) }
    }

    /// Clears the destination when the place is selected, then deletes the place.
    private func remove(_ place: SavedPlace) {
        clearDestinationIfSelected(place)
        withAnimation(DesignTokens.Motion.disclose) { store.remove(id: place.id) }
    }

    /// Deletes a dropped place with no animation. Its slot is closed and its chip is hidden.
    private func removeDropped(_ place: SavedPlace) {
        clearDestinationIfSelected(place)
        store.remove(id: place.id)
    }

    private func clearDestinationIfSelected(_ place: SavedPlace) {
        if isSelected(place) { onClearDestination() }
    }
}
