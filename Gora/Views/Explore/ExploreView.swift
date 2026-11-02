//
//  ExploreView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 6/30/26.
//

import SwiftUI
import MapKit

// MARK: - Supporting Types

nonisolated struct ExplorePolyline: Identifiable, Sendable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    /// The edge's own `mkDirectionsTransportType`, carried through so road snapping asks
    /// MapKit for the right kind of route (`DirectionsTransport.snapType(for:)`) instead of
    /// assuming every line is driven.
    let transportHint: String?
}

nonisolated struct VisibleStation: Identifiable, Sendable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let color: Color
    let dotSize: CGFloat
    let isInterchange: Bool
    let isTerminal: Bool
}

nonisolated struct RouteLayer: Identifiable, Sendable {
    let id: String
    let mode: String
    let displayName: String
    let color: Color
    let lineWidth: CGFloat
    let polylines: [ExplorePolyline]
    /// Position of each edge ID in `polylines`.
    let polylineIndex: [String: Int]
    /// Edge IDs grouped into connected chains in path order. The map draws one line per chain.
    let chains: [[String]]
    let stations: [VisibleStation]
    var isVisible: Bool = true
}

struct ColoredPolyline: Identifiable {
    let id: String
    let layerID: String
    let coordinates: [CLLocationCoordinate2D]
    let color: Color
    let lineWidth: CGFloat
}

// MARK: - Station Dot

/// Draws no shadow, because the map shows one dot per station and a shadow on each one is slow to render.
struct StationDot: View {
    let color: Color
    let size: CGFloat
    let isInterchange: Bool

    var body: some View {
        ZStack {
            Circle().fill(.white).frame(width: size, height: size)
            Circle().stroke(color, lineWidth: isInterchange ? 3 : 2.5).frame(width: size, height: size)
            Circle().fill(color).frame(width: size * 0.42, height: size * 0.42)
            if isInterchange {
                Circle().stroke(color.opacity(0.35), lineWidth: 2).frame(width: size + 5, height: size + 5)
            }
        }
    }
}

// MARK: - Explore Map

/// Reads only the visible polylines and stations, so status and panel changes do not rebuild the map.
private struct ExploreMap: View {
    let vm: ExploreViewModel
    @Binding var position: MapCameraPosition

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                ForEach(vm.visiblePolylines) { item in
                    MapPolyline(coordinates: item.coordinates)
                        .stroke(item.color, lineWidth: item.lineWidth)
                }
                ForEach(vm.visibleStations) { station in
                    Annotation("", coordinate: station.coordinate, anchor: .center) {
                        StationDot(color: station.color,
                                   size: station.dotSize,
                                   isInterchange: station.isInterchange)
                    }
                }
            }
            .onTapGesture(coordinateSpace: .local) { point in
                focusLine(near: point, proxy: proxy)
            }
        }
    }

    /// Focuses the route whose line is nearest the tap. A focused map ignores taps.
    private func focusLine(near point: CGPoint, proxy: MapProxy) {
        guard vm.focusedLayerID == nil else { return }
        let layerID = ExploreMapHitTest.nearestLayerID(to: point, in: vm.visiblePolylines) {
            proxy.convert($0, to: .local)
        }
        if let layerID { vm.focus(layerID) }
    }
}

// MARK: - Explore View

struct ExploreView: View {
    @Environment(UserSession.self) private var session
    @State private var vm = ExploreViewModel()
    @State private var mapPosition: MapCameraPosition = .region(ExploreView.startRegion)
    @State private var panelExpanded = true
    @State private var showCreateLoop = false
    @State private var layerToDelete: RouteLayer?

    private static let startRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 14.5763, longitude: 121.0194),
        span: MKCoordinateSpan(latitudeDelta: 0.18, longitudeDelta: 0.18)
    )

    var body: some View {
        ZStack(alignment: .bottom) {
            ExploreMap(vm: vm, position: $mapPosition)
                .ignoresSafeArea()

            statusPills

            if let layer = vm.focusedLayer {
                closeButton(for: layer)
            }

            routePanel
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .onAppear { vm.start() }
        .onChange(of: vm.focusedLayerID) { moveCamera() }
    }

    // MARK: - Camera

    /// Fits the focused route above the panel, or returns to the start region without a focus.
    private func moveCamera() {
        withAnimation(.easeInOut(duration: 0.6)) {
            if let rect = vm.focusedMapRect, !rect.isNull {
                mapPosition = .rect(Self.cameraRect(fitting: rect))
            } else {
                mapPosition = .region(Self.startRegion)
            }
        }
    }

    /// Pads the rect on every side, then adds height below so the route clears the bottom panel.
    private static func cameraRect(fitting rect: MKMapRect) -> MKMapRect {
        let minimumSide = 3000.0
        let width = max(rect.width, minimumSide), height = max(rect.height, minimumSide)
        let padded = MKMapRect(x: rect.midX - width * 0.65, y: rect.midY - height * 0.65,
                               width: width * 1.3, height: height * 1.3)
        return MKMapRect(x: padded.minX, y: padded.minY,
                         width: padded.width, height: padded.height * 1.7)
    }

    // MARK: - Close Button

    private func closeButton(for layer: RouteLayer) -> some View {
        Button { vm.clearFocus() } label: {
            HStack(spacing: 6) {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(Color.ember)
                Text(layer.displayName).font(.subheadline.bold())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.leading, 16)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // Status pills (stacked above the panel)
    private var statusPills: some View {
        VStack(spacing: 6) {
            if vm.isLoading {
                statusPill {
                    ProgressView()
                    Text("Loading routes…").font(.caption)
                }
            }
            if vm.isFetchingRoads {
                statusPill {
                    ProgressView(value: Double(vm.fetchProgress),
                                 total: Double(max(vm.fetchTotal, 1)))
                        .progressViewStyle(.linear)
                        .frame(width: 80)
                        .tint(Color.ember)
                    Text("Plotting roads \(vm.fetchProgress)/\(vm.fetchTotal)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if vm.isDeletingLayer {
                statusPill {
                    ProgressView()
                    Text("Deleting route…").font(.caption)
                }
            }
            if let err = vm.errorMessage {
                statusPill {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.vermilion)
                    Text(err).font(.caption).foregroundStyle(Color.vermilion)
                }
            }
            if let err = vm.deleteError {
                statusPill {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.vermilion)
                    Text(err).font(.caption).foregroundStyle(Color.vermilion)
                    Button {
                        vm.deleteError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 56) // clear status bar
    }

    @ViewBuilder
    private func statusPill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }

    // MARK: - Route Panel

    private var routePanel: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.faint)
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 2)

            HStack {
                Text("Routes").font(.headline)
                Spacer()
                if panelExpanded {
                    HStack(spacing: 0) {
                        Button("Show All") { withAnimation { vm.showAll() } }
                            .font(.caption.bold()).disabled(vm.allVisible)
                        Text(" · ").font(.caption).foregroundStyle(.secondary)
                        Button("Hide All") { withAnimation { vm.hideAll() } }
                            .font(.caption.bold()).disabled(vm.noneVisible)
                    }
                    .padding(.trailing, 6)
                }
                // Saving a route hits an admin-only backend endpoint (POST
                // /api/v1/admin/graph/routes) — hide the entry point for everyone else
                // rather than let them build a whole route and hit a 403 at the last step.
                if session.isAdmin {
                    Button { showCreateLoop = true } label: {
                        Image(systemName: "plus.circle")
                            .font(.subheadline.bold())
                            .foregroundStyle(Color.ember)
                            .frame(width: 30, height: 30)
                            .background(Color.haze)
                            .clipShape(Circle())
                    }
                    .padding(.trailing, 4)
                }
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        panelExpanded.toggle()
                    }
                } label: {
                    Image(systemName: panelExpanded ? "chevron.down" : "chevron.up")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.haze)
                        .clipShape(Circle())
                }
            }
            .fullScreenCover(isPresented: $showCreateLoop) {
                CreateLoopView()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if panelExpanded {
                Divider()
                List {
                    ForEach(modeGroups, id: \.mode) { group in
                        Section {
                            ForEach(group.layers) { layer in
                                routeRow(layer)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparatorTint(Color.smoke)
                                    .listRowInsets(EdgeInsets())
                                    // Deleting a route is admin-only on the backend, same
                                    // as creating one — don't offer a swipe that can only
                                    // ever come back as a 403.
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        if session.isAdmin {
                                            Button(role: .destructive) {
                                                layerToDelete = layer
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                    }
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: ExploreViewModel.modeIcon(group.mode))
                                    .font(.caption2.bold())
                                Text(group.mode.uppercased())
                                    .font(.caption2.bold()).kerning(0.5)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: 270)
                .disabled(vm.isDeletingLayer)
            }
        }
        .confirmationDialog(
            "Delete \(layerToDelete?.displayName ?? "") route?",
            isPresented: Binding(
                get: { layerToDelete != nil },
                set: { if !$0 { layerToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: layerToDelete
        ) { layer in
            Button("Delete Route", role: .destructive) {
                layerToDelete = nil
                Task { await vm.deleteLayer(layer.id) }
            }
            Button("Cancel", role: .cancel) { layerToDelete = nil }
        } message: { layer in
            Text("This permanently removes all \(layer.stations.count) stops and every segment on \(layer.id) from the server. This cannot be undone.")
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 12, y: -4)
    }

    @ViewBuilder
    private func routeRow(_ layer: RouteLayer) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(layer.color)
                    .frame(width: 22, height: layer.lineWidth)
                StationDot(color: layer.color, size: 11, isInterchange: false)
                    .shadow(color: .black.opacity(0.22), radius: 2, x: 0, y: 1)
            }
            .frame(width: 36, height: 36)
            .background(layer.color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(layer.displayName)
                .font(.subheadline)
                .foregroundStyle(layer.isVisible ? .primary : .secondary)

            Spacer()

            Button { vm.toggle(layer.id) } label: {
                Image(systemName: layer.isVisible ? "eye.fill" : "eye.slash")
                    .font(.subheadline)
                    .foregroundStyle(layer.isVisible ? layer.color : Color.faint)
                    .frame(width: 36, height: 36)
                    .background(layer.isVisible ? layer.color.opacity(0.12) : Color.haze)
                    .clipShape(Circle())
                    .animation(.easeInOut(duration: 0.15), value: layer.isVisible)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(vm.focusedLayerID == layer.id ? layer.color.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { vm.focus(layer.id) }
    }

    private var modeGroups: [(mode: String, layers: [RouteLayer])] {
        ["train", "bus", "jeepney", "uv_express", "tricycle"].compactMap { mode in
            let subset = vm.layers.filter { $0.mode == mode }
            return subset.isEmpty ? nil : (mode: mode, layers: subset)
        }
    }
}

#Preview { ExploreView() }
