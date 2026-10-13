//
//  AddPlaceSheet.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import SwiftUI

/// The sheet that saves a place: a name, an icon, and a location. See `Commute-Cards.md`.
struct AddPlaceSheet: View {
    let routeStore: RouteStore
    let onSave: (SavedPlace) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: AddPlaceViewModel
    /// Height of the sheet content. The only detent follows it, so the sheet fits its content.
    @State private var contentHeight: CGFloat = 520

    private static let rowHeight: CGFloat = 52
    /// Suggestions shown under the address field. The sheet grows by one row for each.
    private static let maxSuggestions = 4

    init(routeStore: RouteStore, editing: SavedPlace? = nil, onSave: @escaping (SavedPlace) -> Void) {
        self.routeStore = routeStore
        self.onSave = onSave
        _model = State(initialValue: AddPlaceViewModel(stations: routeStore.allStations,
                                                       userLocation: routeStore.userLocation,
                                                       editing: editing))
    }

    /// The sheet keeps the system Liquid Glass background. A second glass layer here would draw
    /// an inner edge above the home indicator and a touch glow while the sheet is dragged.
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
            header
            nameSection
            iconSection
            addressSection
            currentLocationRow
            saveButton
        }
        .padding(.horizontal, DesignTokens.Space.l)
        .padding(.top, DesignTokens.Space.m)
        .padding(.bottom, DesignTokens.Space.m)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDragIndicator(.visible)
        .presentationDetents([.height(contentHeight)])
        .task { await model.loadCurrentAddress() }
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            Text(model.editing == nil ? "Add Place" : "Edit Place")
                .font(DesignTokens.TypeScale.instructionCompact)
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Close")
                Spacer()
            }
        }
    }

    // MARK: Name

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
            TextField("Name", text: $model.name)
                .font(.body)
                .padding(.horizontal, DesignTokens.Space.xl)
                .frame(height: Self.rowHeight)
                .background(Capsule().fill(Self.fieldFill))
            Text("Shown in your saved places.")
                .font(DesignTokens.TypeScale.subtitle)
                .foregroundStyle(.secondary)
                .padding(.horizontal, DesignTokens.Space.xl)
        }
    }

    // MARK: Icon

    private var iconSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s) {
            Text("Icon")
                .font(DesignTokens.TypeScale.subtitleEmphasis)
                .foregroundStyle(.secondary)
            HStack(spacing: DesignTokens.Space.xs) {
                ForEach(SavedPlaceIcon.allCases) { icon in
                    iconButton(icon)
                }
            }
            .sensoryFeedback(.selection, trigger: model.icon)
        }
    }

    private func iconButton(_ icon: SavedPlaceIcon) -> some View {
        let isSelected = model.icon == icon
        return Button { model.icon = icon } label: {
            Image(systemName: icon.systemImage)
                .font(.system(size: 18))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(HierarchicalShapeStyle.primary))
                .frame(width: 46, height: 46)
                .background(Circle().fill(isSelected ? Self.accent : Self.fieldFill))
        }
        .buttonStyle(.plain)
        .animation(DesignTokens.Motion.disclose, value: isSelected)
        .accessibilityLabel(icon.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Address

    private var addressSection: some View {
        VStack(spacing: DesignTokens.Space.xs) {
            HStack(spacing: DesignTokens.Space.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search address", text: $model.query)
                    .font(.body)
                    .autocorrectionDisabled()
                    .onChange(of: model.query) { _, text in model.queryChanged(text) }
                if model.isResolving {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, DesignTokens.Space.xl)
            .frame(height: Self.rowHeight)
            .background(Capsule().fill(Self.fieldFill))

            if !model.suggestions.isEmpty {
                SuggestionList(
                    suggestions: Array(model.suggestions.prefix(Self.maxSuggestions)),
                    lineName: routeStore.lineDisplayName,
                    lineColor: routeStore.lineColor,
                    onSelect: model.pick
                )
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
            }
        }
        .animation(DesignTokens.Motion.suggestEnter, value: model.suggestions.isEmpty)
    }

    // MARK: Use current location

    private var currentLocationRow: some View {
        let isSelected = model.picked?.source == .current
        return Button(action: model.useCurrentLocation) {
            HStack(spacing: DesignTokens.Space.m) {
                Image(systemName: "location.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Color(.systemBackground))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Self.accent))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use Current Location")
                        .font(DesignTokens.TypeScale.rowTitle)
                        .foregroundStyle(.primary)
                    Text(model.currentLocationSubtitle)
                        .font(DesignTokens.TypeScale.subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignTokens.Space.ml)
            .frame(height: 60)
            .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.card).fill(Self.fieldFill))
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                    .strokeBorder(Self.accent, lineWidth: isSelected ? 2 : 0)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.userLocation == nil)
        .animation(DesignTokens.Motion.disclose, value: isSelected)
    }

    // MARK: Save

    private var saveButton: some View {
        Button {
            guard let place = model.makePlace() else { return }
            onSave(place)
            dismiss()
        } label: {
            Text(model.editing == nil ? "Save Place" : "Save Changes")
                .font(DesignTokens.TypeScale.controlLabel)
                .foregroundStyle(model.canSave ? Color.licorice : Color.secondary.opacity(0.6))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Capsule().fill(model.canSave ? Color.tangerine : Color(.tertiarySystemFill)))
        }
        .buttonStyle(.plain)
        .disabled(!model.canSave)
        .animation(DesignTokens.Motion.disclose, value: model.canSave)
    }

    private static let fieldFill = Color.primary.opacity(0.08)
    /// Selection and location color. Lagoon is for selection inside sheets only, never on the map,
    /// where it could read as the green status or the bus blue.
    private static let accent = Color.lagoon
}
