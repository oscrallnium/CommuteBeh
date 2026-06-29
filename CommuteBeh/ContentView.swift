import SwiftUI
import MapKit

// MARK: - ContentView

struct ContentView: View {
    @State private var vm = CommuteViewModel()
    @State private var originText = ""
    @State private var destinationText = ""
    @State private var originSuggestions: [Station] = []
    @State private var destSuggestions: [Station] = []
    @State private var showOriginSuggestions = false
    @State private var showDestSuggestions = false
    @State private var mapPosition: MapCameraPosition = .region(Self.manilaRegion)
    @FocusState private var focusedField: SearchField?

    private enum SearchField { case origin, destination }

    private static let manilaRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 14.5763, longitude: 121.0194),
        span: MKCoordinateSpan(latitudeDelta: 0.18, longitudeDelta: 0.18)
    )

    var body: some View {
        Map(position: $mapPosition) {
            if let result = vm.routeResult {
                // ── Polylines — one per RouteLeg, using merged polylineCoordinates ──
                ForEach(result.legs) { leg in
                    let coords = leg.polylineCoordinates.map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
                    }
                    MapPolyline(coordinates: coords)
                        .stroke(modeColor(leg.mode), lineWidth: modeLineWidth(leg.mode))
                }
                // ── Origin pin ───────────────────────────────────────────────────
                if let first = result.legs.first {
                    Annotation("", coordinate: CLLocationCoordinate2D(
                        latitude: first.fromStation.coordinates.lat,
                        longitude: first.fromStation.coordinates.lng
                    )) {
                        ZStack {
                            Circle().fill(.green).frame(width: 16, height: 16)
                            Circle().stroke(.white, lineWidth: 2.5).frame(width: 16, height: 16)
                        }
                        .shadow(color: .black.opacity(0.3), radius: 2)
                    }
                }
                // ── Destination pin ──────────────────────────────────────────────
                if let last = result.legs.last {
                    Annotation(last.toStation.shortName, coordinate: CLLocationCoordinate2D(
                        latitude: last.toStation.coordinates.lat,
                        longitude: last.toStation.coordinates.lng
                    )) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title)
                            .foregroundStyle(.red)
                            .shadow(color: .black.opacity(0.4), radius: 2)
                    }
                }
                // ── Transfer dots — boarding station of every non-first leg ──────
                ForEach(result.legs.dropFirst()) { leg in
                    Annotation("", coordinate: CLLocationCoordinate2D(
                        latitude: leg.fromStation.coordinates.lat,
                        longitude: leg.fromStation.coordinates.lng
                    )) {
                        Circle()
                            .fill(.white)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(modeColor(leg.mode), lineWidth: 2))
                            .shadow(color: .black.opacity(0.2), radius: 1)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .safeAreaInset(edge: .top, spacing: 0) {
            searchPanel.padding()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let result = vm.routeResult {
                RouteResultCard(result: result).padding()
            }
        }
        .overlay {
            if vm.isLoading { LoadingOverlay() }
        }
        .onChange(of: vm.isLoading) { _, isLoading in
            if !isLoading, let result = vm.routeResult { fitMap(to: result) }
        }
    }

    // MARK: - Search Panel

    private var searchPanel: some View {
        VStack(spacing: 6) {
            // Input card
            VStack(spacing: 8) {
                fieldRow(
                    placeholder: "From: Search station…",
                    text: $originText,
                    icon: "circle.fill",
                    iconColor: .green,
                    field: .origin,
                    onChange: updateOriginSuggestions,
                    onClear: clearOrigin
                )
                Divider().padding(.horizontal, 4)
                fieldRow(
                    placeholder: "To: Search station…",
                    text: $destinationText,
                    icon: "mappin.circle.fill",
                    iconColor: .red,
                    field: .destination,
                    onChange: updateDestSuggestions,
                    onClear: clearDestination
                )
                Divider().padding(.horizontal, 4)
                HStack(spacing: 10) {
                    Button {
                        focusedField = nil
                        Task { await vm.calculateRoute() }
                    } label: {
                        Label("Search Route", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.canCalculate)

                    Button(action: resetAll) {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                }
                if let error = vm.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

            // Suggestions — outside the clipped card so they aren't cut off
            if showOriginSuggestions && !originSuggestions.isEmpty {
                SuggestionList(stations: Array(originSuggestions.prefix(5))) { station in
                    selectOrigin(station)
                }
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            } else if showDestSuggestions && !destSuggestions.isEmpty {
                SuggestionList(stations: Array(destSuggestions.prefix(5))) { station in
                    selectDestination(station)
                }
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            }
        }
    }

    @ViewBuilder
    private func fieldRow(
        placeholder: String,
        text: Binding<String>,
        icon: String,
        iconColor: Color,
        field: SearchField,
        onChange: @escaping (String) -> Void,
        onClear: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .font(.subheadline)
                .frame(width: 20)
            TextField(placeholder, text: text)
                .autocorrectionDisabled()
                .focused($focusedField, equals: field)
                .onChange(of: text.wrappedValue) { _, val in onChange(val) }
            if !text.wrappedValue.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.gray.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Actions

    private func updateOriginSuggestions(_ query: String) {
        vm.originID = ""
        guard !query.isEmpty else {
            originSuggestions = []; showOriginSuggestions = false; return
        }
        let q = query.lowercased()
        originSuggestions = vm.allStations.filter {
            $0.name.lowercased().contains(q) || $0.shortName.lowercased().contains(q)
        }
        showOriginSuggestions = true
        showDestSuggestions = false
    }

    private func updateDestSuggestions(_ query: String) {
        vm.destinationID = ""
        guard !query.isEmpty else {
            destSuggestions = []; showDestSuggestions = false; return
        }
        let q = query.lowercased()
        destSuggestions = vm.allStations.filter {
            $0.name.lowercased().contains(q) || $0.shortName.lowercased().contains(q)
        }
        showDestSuggestions = true
        showOriginSuggestions = false
    }

    private func selectOrigin(_ station: Station) {
        originText = station.name
        vm.originID = station.id
        showOriginSuggestions = false
        originSuggestions = []
        focusedField = .destination
    }

    private func selectDestination(_ station: Station) {
        destinationText = station.name
        vm.destinationID = station.id
        showDestSuggestions = false
        destSuggestions = []
        focusedField = nil
    }

    private func clearOrigin() {
        originText = ""; vm.originID = ""
        originSuggestions = []; showOriginSuggestions = false
    }

    private func clearDestination() {
        destinationText = ""; vm.destinationID = ""
        destSuggestions = []; showDestSuggestions = false
    }

    private func resetAll() {
        focusedField = nil
        clearOrigin(); clearDestination()
        vm.routeResult = nil
        vm.errorMessage = nil
        withAnimation(.easeInOut(duration: 0.4)) {
            mapPosition = .region(Self.manilaRegion)
        }
    }

    // Fits the camera to the bounding box of all leg polylines.
    private func fitMap(to result: RouteResult) {
        let allCoords = result.legs.flatMap { leg in
            leg.polylineCoordinates.map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
            }
        }
        guard !allCoords.isEmpty else { return }
        let lats = allCoords.map(\.latitude)
        let lngs = allCoords.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude:  ((lats.min() ?? 0) + (lats.max() ?? 0)) / 2,
            longitude: ((lngs.min() ?? 0) + (lngs.max() ?? 0)) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta:  max(((lats.max() ?? 0) - (lats.min() ?? 0)) * 1.6, 0.02),
            longitudeDelta: max(((lngs.max() ?? 0) - (lngs.min() ?? 0)) * 1.6, 0.02)
        )
        withAnimation(.easeInOut(duration: 0.5)) {
            mapPosition = .region(MKCoordinateRegion(center: center, span: span))
        }
    }

    // MARK: - Mode Styling (keyed on TransportMode enum, not raw String)

    private func modeColor(_ mode: TransportMode) -> Color {
        switch mode {
        case .train:    return .blue
        case .bus:      return .orange
        case .jeepney:  return .green
        case .tricycle: return .purple
        case .walk:     return Color(.systemGray).opacity(0.6)
        }
    }

    private func modeLineWidth(_ mode: TransportMode) -> CGFloat {
        switch mode {
        case .train:    return 5
        case .bus:      return 4
        case .jeepney:  return 4
        case .tricycle: return 3
        case .walk:     return 2
        }
    }
}

// MARK: - Suggestion List

struct SuggestionList: View {
    let stations: [Station]
    let onSelect: (Station) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(stations.enumerated()), id: \.offset) { index, station in
                Button { onSelect(station) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: typeIcon(station.type))
                            .foregroundStyle(typeColor(station.type))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(station.name)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Text(station.line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                if index < stations.count - 1 {
                    Divider().padding(.leading, 48)
                }
            }
        }
    }

    private func typeIcon(_ type: String) -> String {
        switch type {
        case "train":    return "tram.fill"
        case "bus":      return "bus.fill"
        case "jeepney":  return "car.fill"
        case "tricycle": return "bicycle"
        default:         return "figure.walk"
        }
    }

    private func typeColor(_ type: String) -> Color {
        switch type {
        case "train":    return .blue
        case "bus":      return .orange
        case "jeepney":  return .green
        case "tricycle": return .purple
        default:         return Color(.systemGray)
        }
    }
}

// MARK: - Route Result Card

struct RouteResultCard: View {
    let result: RouteResult
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ── Summary header ───────────────────────────────────────────────
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Route Found", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    HStack(spacing: 14) {
                        Label("\(Int(result.totalTimeMinutes)) min", systemImage: "clock")
                        Label("₱\(String(format: "%.0f", result.totalFare))", systemImage: "banknote")
                        Label("\(String(format: "%.1f", result.totalDistanceKm)) km", systemImage: "map")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(Color.gray.opacity(0.15))
                        .clipShape(Circle())
                }
            }

            // ── Mode chain + transfer count ──────────────────────────────────
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(result.modes.enumerated()), id: \.offset) { i, mode in
                        if i > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        modePill(mode)
                    }
                    if result.transfers > 0 {
                        Text("• \(result.transfers) transfer\(result.transfers > 1 ? "s" : "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // ── Expanded leg list ────────────────────────────────────────────
            if expanded {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(result.legs.enumerated()), id: \.element.id) { i, leg in
                            RouteLegRow(leg: leg)
                            if i < result.legs.count - 1 {
                                Divider().padding(.leading, 22)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: -4)
    }

    @ViewBuilder
    private func modePill(_ mode: TransportMode) -> some View {
        let color = modeColor(mode)
        HStack(spacing: 4) {
            Image(systemName: modeIcon(mode))
            Text(mode.rawValue.capitalized)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.15))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }

    private func modeColor(_ mode: TransportMode) -> Color {
        switch mode {
        case .train:    return .blue
        case .bus:      return .orange
        case .jeepney:  return .green
        case .tricycle: return .purple
        case .walk:     return Color(.systemGray)
        }
    }

    private func modeIcon(_ mode: TransportMode) -> String {
        switch mode {
        case .train:    return "tram.fill"
        case .bus:      return "bus.fill"
        case .jeepney:  return "car.fill"
        case .tricycle: return "bicycle"
        case .walk:     return "figure.walk"
        }
    }
}

// MARK: - Route Leg Row
// Replaces the old RouteStepRow. Renders one user-facing RouteLeg:
// one boarding → one alighting, with expandable intermediate stops.

struct RouteLegRow: View {
    let leg: RouteLeg
    @State private var stopsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Main leg row ─────────────────────────────────────────────────
            HStack(alignment: .top, spacing: 12) {
                // Mode indicator dot
                Circle()
                    .fill(modeColor(leg.mode))
                    .frame(width: 10, height: 10)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 3) {
                    Text(leg.instruction)
                        .font(.subheadline)

                    HStack(spacing: 8) {
                        // Time
                        Label("\(Int(leg.effectiveTravelMinutes)) min", systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // Fare (walk legs have zero fare — hide chip)
                        if leg.fare > 0 {
                            Text("•")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Label("₱\(String(format: "%.0f", leg.fare))", systemImage: "banknote")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        // Estimated arrival
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(arrivalString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Intermediate stops disclosure — only shown when there are stops to expand
                    if leg.stopCount > 1 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                stopsExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(stopsExpanded
                                     ? "Hide stops"
                                     : "\(leg.stopCount) stop\(leg.stopCount > 1 ? "s" : "")")
                                    .font(.caption)
                                    .foregroundStyle(modeColor(leg.mode))
                                Image(systemName: stopsExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(modeColor(leg.mode))
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 8)

            // ── Expandable intermediate stop list ────────────────────────────
            if stopsExpanded && leg.stops.count > 2 {
                let intermediate = leg.stops.dropFirst().dropLast()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(intermediate.enumerated()), id: \.offset) { _, station in
                        HStack(spacing: 12) {
                            // Vertical track line + small dot
                            ZStack {
                                Rectangle()
                                    .fill(modeColor(leg.mode).opacity(0.35))
                                    .frame(width: 2)
                                Circle()
                                    .fill(modeColor(leg.mode).opacity(0.6))
                                    .frame(width: 6, height: 6)
                            }
                            .frame(width: 10)
                            .padding(.leading, 2)

                            Text(station.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.leading, 22)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var arrivalString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: leg.estimatedArrival)
    }

    private func modeColor(_ mode: TransportMode) -> Color {
        switch mode {
        case .train:    return .blue
        case .bus:      return .orange
        case .jeepney:  return .green
        case .tricycle: return .purple
        case .walk:     return Color(.systemGray)
        }
    }
}

// MARK: - Loading Overlay

struct LoadingOverlay: View {
    @State private var pulse = false
    @State private var dotIndex = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                ZStack {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .stroke(
                                [Color.blue, Color.green, Color.orange][i],
                                lineWidth: 2.5
                            )
                            .frame(
                                width: CGFloat(50 + i * 22),
                                height: CGFloat(50 + i * 22)
                            )
                            .scaleEffect(pulse ? 1.45 : 1.0)
                            .opacity(pulse ? 0 : 0.8)
                            .animation(
                                .easeOut(duration: 1.1)
                                    .repeatForever(autoreverses: false)
                                    .delay(Double(i) * 0.3),
                                value: pulse
                            )
                    }
                    Image(systemName: "tram.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                }
                .frame(width: 100, height: 100)

                VStack(spacing: 6) {
                    Text("Calculating Route")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    HStack(spacing: 6) {
                        Text("Engine working")
                        HStack(spacing: 4) {
                            ForEach(0..<3, id: \.self) { i in
                                Circle()
                                    .fill(.white)
                                    .frame(width: 5, height: 5)
                                    .opacity(dotIndex == i ? 1.0 : 0.3)
                                    .animation(.easeInOut(duration: 0.15), value: dotIndex)
                            }
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(36)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 24))
        }
        .onAppear { pulse = true }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(420))
                dotIndex = (dotIndex + 1) % 3
            }
        }
    }
}

#Preview {
    ContentView()
}
