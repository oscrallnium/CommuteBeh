//
//  ExploreView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 6/30/26.
//

import SwiftUI
import MapKit

// MARK: - Supporting Types

struct ExplorePolyline: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
}

struct VisibleStation: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let color: Color
    let dotSize: CGFloat
    let isInterchange: Bool
    let isTerminal: Bool
}

struct RouteLayer: Identifiable {
    let id: String
    let mode: String
    let displayName: String
    let color: Color
    let lineWidth: CGFloat
    let polylines: [ExplorePolyline]
    let stations: [VisibleStation]
    var isVisible: Bool = true
}

struct ColoredPolyline: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let color: Color
    let lineWidth: CGFloat
}

struct VisibleWaypoint: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let color: Color
}

// MARK: - Station Dot

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
        .shadow(color: .black.opacity(0.22), radius: 2, x: 0, y: 1)
    }
}

// MARK: - Waypoint Dot

struct WaypointDot: View {
    let color: Color

    var body: some View {
        ZStack {
            Circle().fill(.white).frame(width: 6, height: 6)
            Circle().stroke(color.opacity(0.75), lineWidth: 1.5).frame(width: 6, height: 6)
        }
        .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 0.5)
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class ExploreViewModel {

    var layers: [RouteLayer] = []
    var isLoading = false
    var errorMessage: String?

    // Road-snapped coordinates fetched via MKDirections, keyed by edge ID.
    // visiblePolylines prefers these over the static JSON coordinates.
    private var roadPolylines: [String: [CLLocationCoordinate2D]] = [:]
    var fetchProgress: Int = 0
    var fetchTotal: Int = 0
    var isFetchingRoads: Bool { fetchProgress < fetchTotal }

    init() {
        Task { await load() }
        NotificationCenter.default.addObserver(
            forName: Notification.Name("TransitDataDidUpdate"),
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.load() }
        }
    }

    // MARK: - Load

    func load() async {
        isLoading = true
        errorMessage = nil
        // Intentionally keep roadPolylines across reloads — re-snapping all edges on every
        // TransitDataDidUpdate (e.g. Enforce-Operating-Hours toggle) fires 50+ MKDirections
        // requests at once and hits Apple's GEO rate limit. Edges that are already cached
        // are skipped by the roadPolylines[poly.id] == nil guard below.
        fetchProgress = 0
        fetchTotal = 0

        switch await GraphLoader.ensureLoaded() {
        case .success(let graph):
            layers = buildLayers(from: graph)

            // Edges created by the Loop Creator already have MKDirections-sourced coordinates.
            // Copy them directly into roadPolylines so the snap pass below leaves them alone.
            for edge in graph.edges where edge.isRoadSnapped == true {
                let coords = edge.polylineCoordinates.map {
                    CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
                }
                if coords.count >= 2 { roadPolylines[edge.id] = coords }
            }

            // Trains run on elevated/underground guideways — MKDirections would route
            // via surface streets. Keep the JSON polylineCoordinates for trains unchanged.
            // All other modes use .automobile, which reliably follows the road network
            // in the Philippines; .transit lacks jeepney/bus data and can hang indefinitely.
            let edges = layers.flatMap { layer -> [(id: String, coordinates: [CLLocationCoordinate2D], transportType: MKDirectionsTransportType)] in
                guard layer.mode != "train" else { return [] }
                return layer.polylines.compactMap { poly in
                    guard poly.coordinates.count >= 2,
                          roadPolylines[poly.id] == nil else { return nil }  // skip pre-populated
                    return (poly.id, poly.coordinates, MKDirectionsTransportType.automobile)
                }
            }
            // fetchTotal = total segments (consecutive coord pairs) across all polylines.
            fetchTotal = edges.reduce(0) { $0 + ($1.coordinates.count - 1) }
            Task { await snapToRoads(edges: edges) }

        case .failure(let err):
            errorMessage = "Failed to load graph: \(err)"
        }
        isLoading = false
    }

    // MARK: - Road Snapping

    private func snapToRoads(
        edges: [(id: String, coordinates: [CLLocationCoordinate2D], transportType: MKDirectionsTransportType)]
    ) async {
        fetchProgress = 0
        struct Seg {
            let edgeID: String; let idx: Int
            let snapped: [CLLocationCoordinate2D]?
            let from: CLLocationCoordinate2D; let to: CLLocationCoordinate2D
        }
        // Flatten all (edge, segment-index) pairs so the sliding window below can schedule
        // them in order without nested loops inside the group body.
        struct SegInput {
            let edgeID: String; let idx: Int
            let from: CLLocationCoordinate2D; let to: CLLocationCoordinate2D
            let transportType: MKDirectionsTransportType
        }
        var inputs: [SegInput] = []
        for (edgeID, coords, type) in edges {
            for i in 0..<(coords.count - 1) {
                inputs.append(SegInput(edgeID: edgeID, idx: i,
                                       from: coords[i], to: coords[i + 1],
                                       transportType: type))
            }
        }

        var byEdge: [String: [Seg]] = [:]
        // Sliding-window concurrency: keep at most maxConcurrent in-flight requests so we
        // never burst more than ~8 simultaneous MKDirections calls. Apple's GEO service
        // allows 50 per 60 s; each call takes ~1–2 s, so 8 concurrent ≈ 4–8 RPS max.
        let maxConcurrent = 8
        await withTaskGroup(of: Seg.self) { group in
            var nextIndex = 0
            // Seed the initial batch.
            while nextIndex < inputs.count && nextIndex < maxConcurrent {
                let s = inputs[nextIndex]; nextIndex += 1
                group.addTask {
                    Seg(edgeID: s.edgeID, idx: s.idx,
                        snapped: await Self.roadPolyline(from: s.from, to: s.to, transportType: s.transportType),
                        from: s.from, to: s.to)
                }
            }
            // As each task finishes, schedule the next pending segment.
            for await seg in group {
                byEdge[seg.edgeID, default: []].append(seg)
                fetchProgress += 1
                if nextIndex < inputs.count {
                    let s = inputs[nextIndex]; nextIndex += 1
                    group.addTask {
                        Seg(edgeID: s.edgeID, idx: s.idx,
                            snapped: await Self.roadPolyline(from: s.from, to: s.to, transportType: s.transportType),
                            from: s.from, to: s.to)
                    }
                }
            }
        }
        // Stitch each edge's segments back into one road-following polyline.
        for (edgeID, segs) in byEdge {
            var stitched: [CLLocationCoordinate2D] = []
            for seg in segs.sorted(by: { $0.idx < $1.idx }) {
                if let snapped = seg.snapped {
                    stitched += stitched.isEmpty ? snapped : Array(snapped.dropFirst())
                } else {
                    if stitched.isEmpty { stitched.append(seg.from) }
                    stitched.append(seg.to)
                }
            }
            if stitched.count >= 2 { roadPolylines[edgeID] = stitched }
        }
    }

    nonisolated private static func roadPolyline(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        transportType: MKDirectionsTransportType
    ) async -> [CLLocationCoordinate2D]? {
        // Race MKDirections against a 10-second timeout so a single hanging request
        // never stalls the whole progress bar.
        await withTaskGroup(of: [CLLocationCoordinate2D]?.self) { group in
            group.addTask {
                let request = MKDirections.Request()
                request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
                request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
                request.transportType = transportType
                guard let response = try? await MKDirections(request: request).calculate(),
                      let route = response.routes.first,
                      route.polyline.pointCount > 0 else { return nil }
                let count = route.polyline.pointCount
                var coords = Array(repeating: CLLocationCoordinate2D(), count: count)
                route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
                return coords
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    // MARK: - Layer Visibility

    func toggle(_ layerID: String) {
        guard let i = layers.firstIndex(where: { $0.id == layerID }) else { return }
        var updated = layers[i]; updated.isVisible.toggle(); layers[i] = updated
    }

    func deleteLayer(_ layerID: String) async {
        // Remove from in-memory layers immediately for a snappy UI response.
        if let layer = layers.first(where: { $0.id == layerID }) {
            layer.polylines.forEach { roadPolylines.removeValue(forKey: $0.id) }
        }
        layers.removeAll { $0.id == layerID }

        // Persist the deletion to the JSON graph on disk.
        do { try await removeFromGraph(lineID: layerID) } catch {}
    }

    private func removeFromGraph(lineID: String) async throws {
        guard let docsURL = GraphLoader.documentsURL(),
              FileManager.default.fileExists(atPath: docsURL.path) else {
            throw URLError(.fileDoesNotExist)
        }
        let sourceURL = docsURL

        let data = try Data(contentsOf: sourceURL)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotDecodeContentData)
        }

        if var stations = root["stations"] as? [[String: Any]] {
            stations.removeAll { ($0["line"] as? String) == lineID }
            root["stations"] = stations
        }
        if var edges = root["edges"] as? [[String: Any]] {
            edges.removeAll { ($0["line"] as? String) == lineID }
            root["edges"] = edges
        }
        if var modes = root["transportModes"] as? [String: Any] {
            for (key, val) in modes {
                if var entry = val as? [String: Any],
                   var lines = entry["lines"] as? [String],
                   lines.contains(lineID) {
                    lines.removeAll { $0 == lineID }
                    entry["lines"] = lines
                    modes[key] = entry
                }
            }
            root["transportModes"] = modes
        }

        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: docsURL, options: .atomic)

        NotificationCenter.default.post(name: Notification.Name("TransitDataDidUpdate"), object: nil)
    }

    func showAll() { layers = layers.map { var l = $0; l.isVisible = true;  return l } }
    func hideAll() { layers = layers.map { var l = $0; l.isVisible = false; return l } }

    var allVisible:  Bool { layers.allSatisfy(\.isVisible) }
    var noneVisible: Bool { !layers.isEmpty && layers.allSatisfy { !$0.isVisible } }

    // MARK: - Computed Map Content

    var visiblePolylines: [ColoredPolyline] {
        layers.filter(\.isVisible).flatMap { layer in
            layer.polylines.compactMap { poly in
                guard poly.coordinates.count >= 2 else { return nil }
                // Road-snapped coordinates take priority; straight line is the fallback.
                let coords = roadPolylines[poly.id] ?? poly.coordinates
                return ColoredPolyline(id: poly.id, coordinates: coords,
                                       color: layer.color, lineWidth: layer.lineWidth)
            }
        }
    }

    var visibleStations: [VisibleStation] {
        var seen = Set<String>()
        return layers.filter(\.isVisible).flatMap { layer in
            layer.stations.filter { seen.insert($0.id).inserted }
        }
    }

    // Intermediate polyline waypoints from the JSON (excludes station endpoints).
    // Shown as small hollow dots so the user can verify/adjust coordinates in the JSON.
    var visibleWaypoints: [VisibleWaypoint] {
        layers.filter(\.isVisible).flatMap { layer in
            layer.polylines.flatMap { poly -> [VisibleWaypoint] in
                guard poly.coordinates.count > 2 else { return [] }
                return poly.coordinates.dropFirst().dropLast()
                    .enumerated()
                    .map { idx, coord in
                        VisibleWaypoint(id: "\(poly.id)_wp\(idx)",
                                        coordinate: coord,
                                        color: layer.color)
                    }
            }
        }
    }

    // MARK: - Graph → Layers

    private func buildLayers(from graph: TransitGraph) -> [RouteLayer] {
        let stationMap = Dictionary(uniqueKeysWithValues: graph.stations.map { ($0.id, $0) })

        var stationsByLine: [String: [Station]] = [:]
        for station in graph.stations {
            stationsByLine[station.line, default: []].append(station)
        }

        var groups: [String: (mode: String, edges: [TransitEdge])] = [:]
        for edge in graph.edges where edge.mode != "walk" && edge.line != "INTERCHANGE" {
            var entry = groups[edge.line] ?? (mode: edge.mode, edges: [])
            entry.edges.append(edge)
            groups[edge.line] = entry
        }

        return groups
            .map { line, value -> RouteLayer in
                let color = Self.color(for: line)
                let baseSize = Self.dotSize(for: value.mode)

                // polylineCoordinates already starts with the from-station coord
                // and ends with the to-station coord (guaranteed by the JSON schema).
                // Use them directly — no prepend/append needed.
                let polylines: [ExplorePolyline] = value.edges.map { edge in
                    let coords = edge.polylineCoordinates.map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
                    }
                    return ExplorePolyline(id: edge.id, coordinates: coords)
                }

                let stations: [VisibleStation] = (stationsByLine[line] ?? []).map { s in
                    VisibleStation(
                        id: s.id,
                        coordinate: CLLocationCoordinate2D(latitude: s.coordinates.lat, longitude: s.coordinates.lng),
                        color: color,
                        dotSize: (s.isInterchange || s.isTerminal) ? baseSize + 3 : baseSize,
                        isInterchange: s.isInterchange,
                        isTerminal: s.isTerminal
                    )
                }

                return RouteLayer(
                    id: line, mode: value.mode,
                    displayName: Self.displayName(for: line),
                    color: color, lineWidth: Self.lineWidth(for: value.mode),
                    polylines: polylines, stations: stations
                )
            }
            .sorted { Self.modeOrder($0.mode) < Self.modeOrder($1.mode) }
    }

    // MARK: - Static Helpers

    static func color(for line: String) -> Color {
        switch line {
        case "MRT-3":                 return Color(red: 0.07, green: 0.47, blue: 0.93)
        case "LRT-1":                 return Color(red: 0.10, green: 0.70, blue: 0.20)
        case "LRT-2":                 return Color(red: 0.55, green: 0.10, blue: 0.90)
        case "EDSA_BUS":              return Color(red: 0.96, green: 0.50, blue: 0.09)
        case "COMMONWEALTH_BUS":      return Color(red: 0.65, green: 0.30, blue: 0.05)
        case "JEEPNEY_QUIAPO_CUBAO":  return Color(red: 0.90, green: 0.10, blue: 0.10)
        case "JEEPNEY_QUIAPO":        return Color(red: 0.88, green: 0.15, blue: 0.52)
        case "JEEPNEY_NORTH":         return Color(red: 0.00, green: 0.60, blue: 0.65)
        case "JEEPNEY_MAKATI":        return Color(red: 0.00, green: 0.72, blue: 0.80)
        case "EJEEPNEY_BGC":          return Color(red: 0.28, green: 0.18, blue: 0.88)
        case "TRICYCLE_MANILA":        return Color(red: 0.00, green: 0.68, blue: 0.48)
        case "JEEPNEY_CARTIMAR_LRT":  return Color(red: 0.95, green: 0.35, blue: 0.10)
        default:                       return .gray
        }
    }

    static func displayName(for line: String) -> String {
        switch line {
        case "MRT-3":                 return "MRT-3"
        case "LRT-1":                 return "LRT-1"
        case "LRT-2":                 return "LRT-2"
        case "EDSA_BUS":              return "EDSA Bus"
        case "COMMONWEALTH_BUS":      return "Commonwealth Bus"
        case "JEEPNEY_QUIAPO_CUBAO":  return "Jeepney Quiapo–Cubao"
        case "JEEPNEY_QUIAPO":        return "Jeepney Quiapo"
        case "JEEPNEY_NORTH":         return "Jeepney North"
        case "JEEPNEY_MAKATI":        return "Jeepney Makati"
        case "EJEEPNEY_BGC":          return "E-Jeepney BGC"
        case "TRICYCLE_MANILA":        return "Tricycle Manila"
        case "JEEPNEY_CARTIMAR_LRT":  return "Cartimar LRT Jeep"
        default:                       return line.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func lineWidth(for mode: String) -> CGFloat {
        switch mode {
        case "train":    return 6
        case "bus":      return 5
        case "jeepney":  return 4
        case "tricycle": return 3
        default:         return 3
        }
    }

    static func dotSize(for mode: String) -> CGFloat {
        switch mode {
        case "train":    return 13
        case "bus":      return 10
        case "jeepney":  return 9
        case "tricycle": return 8
        default:         return 8
        }
    }

    static func modeOrder(_ mode: String) -> Int {
        ["train": 0, "bus": 1, "jeepney": 2, "tricycle": 3][mode] ?? 4
    }

    static func modeIcon(_ mode: String) -> String {
        switch mode {
        case "train":    return "tram.fill"
        case "bus":      return "bus.fill"
        case "jeepney":  return "car.fill"
        case "tricycle": return "bicycle"
        default:         return "figure.walk"
        }
    }
}

// MARK: - Explore View

struct ExploreView: View {
    @State private var vm = ExploreViewModel()
    @State private var mapPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 14.5763, longitude: 121.0194),
            span: MKCoordinateSpan(latitudeDelta: 0.18, longitudeDelta: 0.18)
        )
    )
    @State private var panelExpanded = true
    @State private var showCreateLoop = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $mapPosition) {
                ForEach(vm.visiblePolylines) { item in
                    MapPolyline(coordinates: item.coordinates)
                        .stroke(item.color, lineWidth: item.lineWidth)
                }
                ForEach(vm.visibleWaypoints) { wp in
                    Annotation("", coordinate: wp.coordinate, anchor: .center) {
                        WaypointDot(color: wp.color)
                    }
                }
                ForEach(vm.visibleStations) { station in
                    Annotation("", coordinate: station.coordinate, anchor: .center) {
                        StationDot(color: station.color,
                                   size: station.dotSize,
                                   isInterchange: station.isInterchange)
                    }
                }
            }
            .ignoresSafeArea()

            // Status pills (stacked above the panel)
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
                            .tint(.blue)
                        Text("Plotting roads \(vm.fetchProgress)/\(vm.fetchTotal)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let err = vm.errorMessage {
                    statusPill {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 56) // clear status bar

            routePanel
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
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
                .fill(Color.gray.opacity(0.4))
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
                Button { showCreateLoop = true } label: {
                    Image(systemName: "plus.circle")
                        .font(.subheadline.bold())
                        .foregroundStyle(.blue)
                        .frame(width: 30, height: 30)
                        .background(Color.blue.opacity(0.10))
                        .clipShape(Circle())
                }
                .padding(.trailing, 4)
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        panelExpanded.toggle()
                    }
                } label: {
                    Image(systemName: panelExpanded ? "chevron.down" : "chevron.up")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.gray.opacity(0.12))
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
                                    .listRowSeparatorTint(Color.gray.opacity(0.25))
                                    .listRowInsets(EdgeInsets())
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            Task { await vm.deleteLayer(layer.id) }
                                        } label: {
                                            Label("Delete", systemImage: "trash")
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
            }
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
                    .foregroundStyle(layer.isVisible ? layer.color : Color.gray.opacity(0.4))
                    .frame(width: 36, height: 36)
                    .background(layer.isVisible ? layer.color.opacity(0.12) : Color.gray.opacity(0.08))
                    .clipShape(Circle())
                    .animation(.easeInOut(duration: 0.15), value: layer.isVisible)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { vm.toggle(layer.id) }
    }

    private var modeGroups: [(mode: String, layers: [RouteLayer])] {
        ["train", "bus", "jeepney", "tricycle"].compactMap { mode in
            let subset = vm.layers.filter { $0.mode == mode }
            return subset.isEmpty ? nil : (mode: mode, layers: subset)
        }
    }
}

#Preview { ExploreView() }
