//
//  SettingsSavedPlacesView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/14/26.
//

import SwiftUI

/// A pushed page that lists the saved places. Swipe a row to delete it.
struct SettingsSavedPlacesView: View {
    @Environment(SavedPlacesStore.self) private var store

    var body: some View {
        List {
            ForEach(store.places) { place in
                row(for: place)
            }
            .onDelete(perform: delete)
        }
        .overlay {
            if store.places.isEmpty {
                ContentUnavailableView(
                    "No Saved Places",
                    systemImage: "mappin.and.ellipse",
                    description: Text("Places you save appear here."))
            }
        }
        .navigationTitle("Saved Places")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(for place: SavedPlace) -> some View {
        HStack(spacing: DesignTokens.Space.m) {
            SettingsRowIcon(systemImage: place.icon.systemImage, tint: .vermilion)
            VStack(alignment: .leading) {
                Text(place.name)
                Text(place.addressLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        let ids = offsets.map { store.places[$0].id }
        ids.forEach { store.remove(id: $0) }
    }
}
