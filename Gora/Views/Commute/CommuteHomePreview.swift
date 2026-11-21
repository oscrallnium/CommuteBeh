//
//  CommuteHomePreview.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/8/26.
//

#if DEBUG
import SwiftUI
import MapKit
import CoreLocation

// MARK: - Sample data

/// Preview-only values in Metro Manila. They are not app data.
private enum Sample {
    static let mapCenter = CLLocationCoordinate2D(latitude: 14.5547, longitude: 121.0244)
    static let mapSpan = MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)

    static let previewFileName = "commute_home_preview_saved_places.json"

    /// A home in Pasig and a workplace in Makati.
    static let places: [(name: String, icon: SavedPlaceIcon, address: String, lat: Double, lng: Double)] = [
        ("Home", .house, "Kapitolyo, Pasig", 14.5713, 121.0580),
        ("Work", .briefcase, "Ayala Avenue, Makati", 14.5547, 121.0244)
    ]

    @MainActor
    static func makeStore() -> SavedPlacesStore {
        let url = FileManager.default.temporaryDirectory.appending(path: previewFileName, directoryHint: .notDirectory)
        let store = SavedPlacesStore(fileURL: url)
        let now = Date()
        for place in places {
            store.add(SavedPlace(
                id: UUID(), name: place.name, icon: place.icon, addressLabel: place.address,
                coordinates: Coordinates(lat: place.lat, lng: place.lng), stationId: nil,
                createdAt: now, updatedAt: now))
        }
        return store
    }
}

// MARK: - Layout

private enum Layout {
    static let commuteTab = "Commute"
    static let commuteSymbol = "arrow.triangle.swap"
    static let settingsTab = "Settings"
    static let settingsSymbol = "gearshape"
}

// MARK: - Home screen

/// The Commute tab before a search: the map, the expanded search card, and the saved places row.
private struct CommuteHomeScreen: View {
    @State private var routeStore = RouteStore()
    @State private var controller = CommuteMapController()
    @State private var drawAnimator = RouteDrawAnimator()
    @State private var savedPlaces = Sample.makeStore()
    @FocusState private var focusedField: SearchField?
    @Namespace private var searchNS

    var body: some View {
        map
            .ignoresSafeArea()
            .safeAreaInset(edge: .top, spacing: 0) { searchPanel }
            .savedPlaceDragHost()
            .environment(savedPlaces)
    }

    private var map: some View {
        CommuteMapView(
            scene: CommuteMapScene(), controller: controller, drawAnimator: drawAnimator,
            events: events,
            initialRegion: MKCoordinateRegion(center: Sample.mapCenter, span: Sample.mapSpan))
    }

    private var searchPanel: some View {
        CommuteSearchPanel(
            routeStore: routeStore,
            focusedField: $focusedField,
            namespace: searchNS,
            showSearchProgress: false,
            onBack: {},
            onSearch: {})
            .padding(CommuteSearchPanel.panelPadding)
    }

    private var events: CommuteMapEvents {
        CommuteMapEvents(
            onCameraSettled: { _ in }, onTap: { _ in }, onLongPress: { _ in }, onSelectRoute: { _ in })
    }
}

// MARK: - Tab bar

/// The app's tab bar for a passenger who is not an admin, around the home screen.
private struct CommuteHomeTabs: View {
    var body: some View {
        TabView {
            Tab(Layout.commuteTab, systemImage: Layout.commuteSymbol) {
                CommuteHomeScreen()
            }
            Tab(Layout.settingsTab, systemImage: Layout.settingsSymbol) {
                Color.clear
            }
        }
    }
}

// MARK: - Preview

struct CommuteHomePreview_Previews: PreviewProvider {
    private static let device = PreviewDevice(rawValue: "iPhone 16 Pro Max")

    static var previews: some View {
        Group {
            CommuteHomeTabs()
                .previewDevice(device)
                .previewDisplayName("Commute Home · Light")
                .preferredColorScheme(.light)
            CommuteHomeTabs()
                .previewDevice(device)
                .previewDisplayName("Commute Home · Dark")
                .preferredColorScheme(.dark)
        }
    }
}
#endif
