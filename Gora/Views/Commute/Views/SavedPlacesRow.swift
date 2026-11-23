//
//  SavedPlacesRow.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import SwiftUI

/// The row of saved-place chips under the search card. The Add Place chip stays pinned at the
/// trailing edge and hides while a search field has focus. The saved places scroll behind it,
/// newest on the left and oldest next to it.
/// A chip counts as selected while the origin or the destination holds that place's name and
/// coordinates. A tap fills the origin when it has focus, and the destination otherwise.
struct SavedPlacesRow: View {
    let routeStore: RouteStore
    @FocusState.Binding var focusedField: SearchField?

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
        .contentMargins(.trailing, showsAddChip ? addChipWidth + DesignTokens.Space.xs + Self.bleed : Self.bleed,
                        for: .scrollContent)
        .animation(DesignTokens.Motion.disclose, value: showsAddChip)
        .defaultScrollAnchor(.trailing)
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
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
        .goraGlass(.regular.interactive(), in: .capsule)
        .animation(DesignTokens.Motion.disclose, value: isSelected)
        .savedPlaceDragSource(place: place, onEdit: { editingPlace = place })
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Edit") { editingPlace = place }
        .accessibilityAction(named: "Remove") { remove(place) }
    }

    private var addChip: some View {
        Button { showsAddPlace = true } label: {
            SavedPlaceChipLabel(icon: "plus", iconSize: 15, title: "Add Place", isSelected: false,
                                restingColor: DesignTokens.Colors.secondaryAction)
                .background(DesignTokens.Colors.secondaryActionFill, in: .capsule)
        }
        .buttonStyle(.plain)
        // Same glass as the place chips, so the two have the same size. The fill is part of the
        // glass content, so it draws above the glass and inside the capsule.
        .goraGlass(.regular.interactive(), in: .capsule)
        .animation(DesignTokens.Motion.disclose, value: hasChipBehindAdd)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { addChipWidth = $0 }
        .padding(.trailing, Self.bleed)
        .opacity(showsAddChip ? 1 : 0)
        .allowsHitTesting(showsAddChip)
        .accessibilityHidden(!showsAddChip)
        .animation(DesignTokens.Motion.disclose, value: showsAddChip)
    }

    /// The Add Place chip shows only while no search field has focus.
    private var showsAddChip: Bool { focusedField == nil }

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

    private func fieldsHolding(_ place: SavedPlace) -> [SearchField] {
        var fields: [SearchField] = []
        if routeStore.originCoordinate == place.coordinates
            && routeStore.confirmedOriginLabel == place.name { fields.append(.origin) }
        if routeStore.destinationCoordinate == place.coordinates
            && routeStore.confirmedDestLabel == place.name { fields.append(.destination) }
        return fields
    }

    private func isSelected(_ place: SavedPlace) -> Bool {
        !fieldsHolding(place).isEmpty
    }

    /// Fills the focused origin field, or the destination when the origin is not focused. A tap on
    /// a place that already fills the target field clears that field. The passenger starts the search.
    private func toggle(_ place: SavedPlace) {
        if drag.swallowsTap { return }
        let field: SearchField = focusedField == .origin ? .origin : .destination
        if fieldsHolding(place).contains(field) {
            routeStore.clear(field)
            return
        }
        routeStore.fill(field, with: place)
        focusedField = field == .origin ? .destination : nil
    }

    /// Saves the edit. Each field that held the old place takes the new place.
    private func update(_ place: SavedPlace, replacing old: SavedPlace) {
        let heldFields = fieldsHolding(old)
        withAnimation(drag.slotAnimation) { store.update(place) }
        heldFields.forEach { routeStore.fill($0, with: place) }
    }

    /// Clears each field that holds the place, then deletes the place.
    private func remove(_ place: SavedPlace) {
        clearFieldsHolding(place)
        withAnimation(DesignTokens.Motion.disclose) { store.remove(id: place.id) }
    }

    /// Deletes a dropped place with no animation. Its slot is closed and its chip is hidden.
    private func removeDropped(_ place: SavedPlace) {
        clearFieldsHolding(place)
        store.remove(id: place.id)
    }

    private func clearFieldsHolding(_ place: SavedPlace) {
        fieldsHolding(place).forEach { routeStore.clear($0) }
    }
}

private enum Layout {
    /// Opacity of the gray fill behind the Add Place glass.
    static let addChipFillOpacity: Double = 0.1
}
