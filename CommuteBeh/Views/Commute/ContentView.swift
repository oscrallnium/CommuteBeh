//
//  ContentView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 5/27/26.
//

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
    @State private var showSearchProgress = false
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
                        .stroke(leg.mode.color, lineWidth: leg.mode.lineWidth)
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
                            .overlay(Circle().stroke(leg.mode.color, lineWidth: 2))
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
                RouteResultCard(result: result)
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity)) // motion.cardEnter
            }
        }
        .animation(DesignTokens.Motion.cardEnter, value: vm.routeResult == nil)
        .onChange(of: vm.isLoading) { _, isLoading in
            if !isLoading, let result = vm.routeResult { fitMap(to: result) }
        }
        // motion.searchProgress: inline progress only past a 250 ms grace delay,
        // then visible ≥ 500 ms — replaces the full-screen LoadingOverlay, which
        // rendered as a dark flash for a < 100 ms local A* computation.
        .task(id: vm.isLoading) {
            if vm.isLoading {
                try? await Task.sleep(for: DesignTokens.Motion.progressGraceDelay)
                if vm.isLoading { showSearchProgress = true }
            } else if showSearchProgress {
                try? await Task.sleep(for: DesignTokens.Motion.progressMinVisible)
                showSearchProgress = false
            }
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
                        Group {
                            if showSearchProgress {
                                ProgressView().tint(.white)
                            } else {
                                Label("Search Route", systemImage: "magnifyingglass")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.canCalculate || vm.isLoading)

                    Button(action: resetAll) {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                }
                if let error = vm.errorMessage {
                    Text(error)
                        .font(DesignTokens.TypeScale.meta)
                        .foregroundStyle(DesignTokens.Colors.destructive)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(DesignTokens.Space.s3)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
            .cardShadow(y: 4)

            // Suggestions — outside the clipped card so they aren't cut off
            if showOriginSuggestions && !originSuggestions.isEmpty {
                SuggestionList(stations: Array(originSuggestions.prefix(5))) { station in
                    selectOrigin(station)
                }
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
                .cardShadow(y: 4)
                .transition(.opacity.combined(with: .move(edge: .top))) // motion.suggestEnter
            } else if showDestSuggestions && !destSuggestions.isEmpty {
                SuggestionList(stations: Array(destSuggestions.prefix(5))) { station in
                    selectDestination(station)
                }
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
                .cardShadow(y: 4)
                .transition(.opacity.combined(with: .move(edge: .top))) // motion.suggestEnter
            }
        }
        .animation(DesignTokens.Motion.suggestEnter, value: suggestionsVisible)
    }

    private var suggestionsVisible: Bool {
        (showOriginSuggestions && !originSuggestions.isEmpty) ||
        (showDestSuggestions && !destSuggestions.isEmpty)
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
        if !vm.originID.isEmpty {
            // onChange fires when selectOrigin sets originText = station.name.
            // If the new text still matches the confirmed selection, do nothing —
            // this is the programmatic setText after a tap, not a user edit.
            if vm.allStations.first(where: { $0.id == vm.originID })?.name == query { return }
            vm.originID = ""  // user edited away from the selection, invalidate it
        }
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
        if !vm.destinationID.isEmpty {
            if vm.allStations.first(where: { $0.id == vm.destinationID })?.name == query { return }
            vm.destinationID = ""
        }
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

    // Mode styling lives in extension TransportMode (DesignTokens.swift).
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
                        Image(systemName: mode(of: station)?.icon ?? "figure.walk")
                            .foregroundStyle(mode(of: station)?.color ?? Color(.systemGray))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(station.name)
                                .font(DesignTokens.TypeScale.body)
                                .foregroundStyle(.primary)
                            Text(lineLabel(for: station))
                                .font(DesignTokens.TypeScale.meta)
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

    private func mode(of station: Station) -> TransportMode? {
        TransportMode(rawValue: station.type)
    }

    // Commuter-facing line label: hyphenated keys (MRT-3, LRT-1) are real-world
    // line names and pass through; underscored keys (JEEPNEY_QUIAPO) are internal
    // ids — show the mode's display name instead of leaking the raw key.
    private func lineLabel(for station: Station) -> String {
        guard station.line.contains("_") else { return station.line }
        return mode(of: station)?.rawValue.capitalized ?? station.line
    }
}

// MARK: - Route Result Card

private struct RouteModeChip: Identifiable {
    let mode: TransportMode
    let count: Int
    let label: String
    let isWalk: Bool
    var id: String { label }
}

struct RouteResultCard: View {
    let result: RouteResult
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Summary (always visible) — tap anywhere to expand ────────────
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                topRow
                timeRow
                chipsRow
            }
            .padding()
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(DesignTokens.Motion.disclose) { expanded.toggle() } }

            // ── Expanded leg detail ──────────────────────────────────────────
            if expanded {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(result.legs.enumerated()), id: \.element.id) { i, leg in
                            RouteLegRow(leg: leg).padding(.horizontal)
                            if i < result.legs.count - 1 {
                                Divider().padding(.leading, 54)
                            }
                        }
                    }
                    .padding(.vertical, DesignTokens.Space.s2)
                }
                .frame(maxHeight: 280)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
        .cardShadow(y: -4)
    }

    // MARK: Rows

    // Row 1: badge · transfers + distance · payment icons
    private var topRow: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            Text("FASTEST")
                .font(.caption.weight(.heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.orange)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(subtitleText)
                .font(DesignTokens.TypeScale.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            HStack(spacing: 6) {
                ForEach(acceptedPayments, id: \.self) { paymentID in
                    paymentIcon(paymentID)
                }
            }
        }
    }

    // Row 2: duration · departure → arrival · fare
    private var timeRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            Text("\(Int(result.totalTimeMinutes)) min")
                .font(.system(.title2, design: .default, weight: .bold))

            Text(timeRangeText)
                .font(DesignTokens.TypeScale.meta)
                .foregroundStyle(.secondary)

            Spacer()

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("₱\(Int(result.totalFare))")
                    .font(.system(.title3, design: .default, weight: .bold))
                Text("TOTAL")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Row 3: mode summary chips + expand chevron
    private var chipsRow: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            ForEach(modeChips) { chip in chipView(chip) }
            Spacer()
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Computed values

    private var subtitleText: String {
        let xfer = result.transfers == 0
            ? "Direct"
            : "\(result.transfers) transfer\(result.transfers > 1 ? "s" : "")"
        return "\(xfer) · \(String(format: "%.1f", result.totalDistanceKm)) km"
    }

    // Depart = first leg's estimated arrival minus that leg's travel time.
    // Arrive = last leg's estimated arrival.
    private var timeRangeText: String {
        guard let first = result.legs.first, let last = result.legs.last else { return "" }
        let departure = first.estimatedArrival.addingTimeInterval(-first.effectiveTravelMinutes * 60)
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return "Arrives at \(fmt.string(from: last.estimatedArrival))"
    }

    // Payments that every non-walk leg accepts (intersection = works the whole journey).
    private var acceptedPayments: [String] {
        let nonWalk = result.legs.filter { $0.mode != .walk }
        guard !nonWalk.isEmpty else { return [] }
        var common = Set(nonWalk[0].rawSteps.flatMap { $0.edge.acceptedPayments })
        for leg in nonWalk.dropFirst() {
            common = common.intersection(Set(leg.rawSteps.flatMap { $0.edge.acceptedPayments }))
        }
        return Array(common).sorted()
    }

    private var modeChips: [RouteModeChip] {
        var chips: [RouteModeChip] = []
        var order: [TransportMode] = []
        var counts: [TransportMode: Int] = [:]
        var stationTotals: [TransportMode: Int] = [:]

        for leg in result.legs where leg.mode != .walk {
            if counts[leg.mode] == nil { order.append(leg.mode) }
            counts[leg.mode, default: 0] += 1
            stationTotals[leg.mode, default: 0] += leg.stops.count
        }
        for mode in order {
            let count = counts[mode, default: 0]
            let n = stationTotals[mode, default: 0]
            let noun: String
            switch mode {
            case .train:    noun = "train ride\(count > 1 ? "s" : "")"
            case .bus:      noun = "bus ride\(count > 1 ? "s" : "")"
            case .jeepney:  noun = "jeepney ride\(count > 1 ? "s" : "")"
            case .tricycle: noun = "tricycle ride\(count > 1 ? "s" : "")"
            case .walk:     noun = "walk"
            }
            chips.append(RouteModeChip(
                mode: mode, count: count,
                label: "\(count) \(noun) (\(n) station\(n == 1 ? "" : "s"))",
                isWalk: false
            ))
        }

        let walks = result.legs.filter { $0.mode == .walk }
        if !walks.isEmpty {
            let mins = Int(walks.reduce(0.0) { $0 + $1.effectiveTravelMinutes }.rounded())
            chips.append(RouteModeChip(
                mode: .walk, count: walks.count,
                label: "\(walks.count) walk\(walks.count > 1 ? "s" : "") (\(mins) min)",
                isWalk: true
            ))
        }
        return chips
    }

    // MARK: Sub-views

    @ViewBuilder
    private func paymentIcon(_ paymentID: String) -> some View {
        Image(systemName: Self.sfSymbol(for: paymentID))
            .font(.caption)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func chipView(_ chip: RouteModeChip) -> some View {
        HStack(spacing: DesignTokens.Space.s1) {
            Image(systemName: chip.mode.icon).font(.caption.weight(.semibold))
            Text(chip.label).font(DesignTokens.TypeScale.meta).fontWeight(.medium)
        }
        .foregroundStyle(chip.isWalk ? AnyShapeStyle(.secondary) : AnyShapeStyle(chip.mode.color))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background { chipBackground(chip) }
    }

    @ViewBuilder
    private func chipBackground(_ chip: RouteModeChip) -> some View {
        if chip.isWalk {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        } else {
            RoundedRectangle(cornerRadius: 8).fill(chip.mode.color.opacity(0.12))
        }
    }

    private static func sfSymbol(for paymentID: String) -> String {
        switch paymentID {
        case "beep_card": return "creditcard.fill"
        case "cash":      return "banknote"
        case "gcash":     return "g.circle.fill"
        case "maya":      return "m.circle.fill"
        case "card":      return "creditcard"
        default:          return "banknote"
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
            HStack(alignment: .top, spacing: DesignTokens.Space.s3) {
                // Mode indicator — the transition cue: ride legs show their mode
                // icon in the mode color; walk/interchange legs show the gray
                // figure.walk, so "exit train → walk → board next line" reads
                // as an icon change down the list.
                Image(systemName: leg.mode.icon)
                    .font(.caption)
                    .foregroundStyle(leg.mode.color)
                    .frame(width: 26, height: 26)
                    .background(leg.mode.color.opacity(0.15), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(leg.instruction)
                        .font(DesignTokens.TypeScale.cardTitle)

                    HStack(spacing: DesignTokens.Space.s2) {
                        // Time
                        Label("\(Int(leg.effectiveTravelMinutes)) min", systemImage: "clock")
                            .font(DesignTokens.TypeScale.meta)
                            .foregroundStyle(.secondary)
                        // Fare (walk legs have zero fare — hide chip)
                        if leg.fare > 0 {
                            Text("•")
                                .font(DesignTokens.TypeScale.meta)
                                .foregroundStyle(.secondary)
                            Label("₱\(String(format: "%.0f", leg.fare))", systemImage: "banknote")
                                .font(DesignTokens.TypeScale.meta)
                                .foregroundStyle(.secondary)
                        }
                        // Estimated arrival
                        Text("•")
                            .font(DesignTokens.TypeScale.meta)
                            .foregroundStyle(.secondary)
                        Text(arrivalString)
                            .font(DesignTokens.TypeScale.meta)
                            .foregroundStyle(.secondary)
                    }

                    // Intermediate stops disclosure — only shown when there are stops to expand
                    if leg.stopCount > 1 {
                        Button {
                            withAnimation(DesignTokens.Motion.disclose) {
                                stopsExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: DesignTokens.Space.s1) {
                                Text(stopsExpanded
                                     ? "Hide stops"
                                     : "\(leg.stopCount) stop\(leg.stopCount > 1 ? "s" : "")")
                                    .font(DesignTokens.TypeScale.meta)
                                    .foregroundStyle(leg.mode.color)
                                Image(systemName: stopsExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(leg.mode.color)
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
                        HStack(spacing: DesignTokens.Space.s3) {
                            // Vertical track line + small dot
                            ZStack {
                                Rectangle()
                                    .fill(leg.mode.color.opacity(0.35))
                                    .frame(width: 2)
                                Circle()
                                    .fill(leg.mode.color.opacity(0.6))
                                    .frame(width: 6, height: 6)
                            }
                            .frame(width: 10)
                            .padding(.leading, 2)

                            Text(station.name)
                                .font(DesignTokens.TypeScale.meta)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, DesignTokens.Space.s1)
                    }
                }
                .padding(.leading, 38) // align under leg text (26 pt icon + 12 pt gap)
                .transition(.opacity.combined(with: .move(edge: .top))) // motion.disclose
            }
        }
    }

    private var arrivalString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: leg.estimatedArrival)
    }
}

// MARK: - Preview Helpers

#if DEBUG
private extension Station {
    static func mock(
        id: String, name: String, shortName: String,
        line: String, type: String,
        lat: Double = 14.5763, lng: Double = 121.0194
    ) -> Station {
        Station(
            id: id, name: name, shortName: shortName,
            line: line, type: type,
            coordinates: Coordinates(lat: lat, lng: lng),
            isTerminal: false, isInterchange: false,
            interchangesWith: nil, amenities: [],
            operatingHours: .init(open: "05:30", close: "23:00")
        )
    }
}

private extension RouteLeg {
    static func mock(
        from: Station, to: Station,
        mode: TransportMode, line: String,
        direction: String? = nil,
        stops: [Station]? = nil,
        minutes: Double, fare: Double, distanceKm: Double = 3,
        instruction: String,
        arrival: Date = Date().addingTimeInterval(1800)
    ) -> RouteLeg {
        RouteLeg(
            fromStation: from, toStation: to,
            mode: mode, line: line, direction: direction,
            stops: stops ?? [from, to],
            effectiveTravelMinutes: minutes,
            fare: fare, distanceKm: distanceKm,
            polylineCoordinates: [],
            estimatedArrival: arrival,
            instruction: instruction,
            rawSteps: []
        )
    }
}
#endif

// MARK: - Previews

#Preview("Search Suggestions") {
    let stations: [Station] = [
        .mock(id: "MRT3_AYALA",    name: "Ayala Station",          shortName: "Ayala",       line: "MRT-3",          type: "train"),
        .mock(id: "MRT3_BUENDIA", name: "Buendia Station",         shortName: "Buendia",     line: "MRT-3",          type: "train"),
        .mock(id: "LRT1_GIL",     name: "Gil Puyat Station",       shortName: "Gil Puyat",   line: "LRT-1",          type: "train"),
        .mock(id: "BUS_AYALA",    name: "Ayala EDSA Bus Stop",     shortName: "Ayala Bus",   line: "EDSA_BUS",       type: "bus"),
        .mock(id: "JEEP_BGC",     name: "Ayala BGC Gate",          shortName: "BGC Ayala",   line: "EJEEPNEY_BGC",   type: "jeepney"),
    ]
    VStack {
        Text("\"Ayala\" results")
            .font(DesignTokens.TypeScale.meta)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
        SuggestionList(stations: stations) { _ in }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
            .cardShadow(y: 4)
            .padding(.horizontal)
        Spacer()
    }
    .padding(.top)
    .background(Color(.systemGroupedBackground))
}

#Preview("Route Result Card") {
    let ayala   = Station.mock(id: "MRT3_AYALA",    name: "Ayala Station",    shortName: "Ayala",      line: "MRT-3", type: "train")
    let kalaw   = Station.mock(id: "MRT3_KALAW",    name: "Kalaw Station",    shortName: "Kalaw",      line: "MRT-3", type: "train")
    let central = Station.mock(id: "LRT1_CENTRAL",  name: "Central Station",  shortName: "Central",    line: "LRT-1", type: "train")
    let avenida = Station.mock(id: "LRT1_AVENIDA",  name: "Avenida Station",  shortName: "Avenida",    line: "LRT-1", type: "train")

    let mrt3Stops: [Station] = [
        ayala,
        .mock(id: "MRT3_BUENDIA",  name: "Buendia Station",  shortName: "Buendia",  line: "MRT-3", type: "train"),
        .mock(id: "MRT3_VITO",     name: "Vito Cruz Station", shortName: "Vito Cruz",line: "MRT-3", type: "train"),
        kalaw,
    ]
    let lrt1Stops: [Station] = [
        central,
        .mock(id: "LRT1_CARRIEDO", name: "Carriedo Station", shortName: "Carriedo", line: "LRT-1", type: "train"),
        avenida,
    ]

    let legs: [RouteLeg] = [
        .mock(from: ayala,   to: kalaw,   mode: .train, line: "MRT-3", direction: "southbound",
              stops: mrt3Stops, minutes: 12, fare: 28, distanceKm: 4.1,
              instruction: "Ride MRT-3 Southbound to Kalaw",
              arrival: Date().addingTimeInterval(720)),
        .mock(from: kalaw,   to: central, mode: .walk,  line: "walk",
              minutes: 5, fare: 0, distanceKm: 0.4,
              instruction: "Walk to LRT-1 Central Station",
              arrival: Date().addingTimeInterval(1020)),
        .mock(from: central, to: avenida, mode: .train, line: "LRT-1",
              stops: lrt1Stops, minutes: 8, fare: 20, distanceKm: 2.9,
              instruction: "Ride LRT-1 Northbound to Avenida",
              arrival: Date().addingTimeInterval(1500)),
    ]

    let result = RouteResult(
        legs: legs, totalTimeMinutes: 25, totalFare: 48,
        totalDistanceKm: 7.4, transfers: 2,
        modes: [.train, .walk, .train]
    )

    ZStack(alignment: .bottom) {
        Color(.systemGroupedBackground).ignoresSafeArea()
        RouteResultCard(result: result).padding()
    }
}

#Preview("Route Leg Row – Train") {
    let from = Station.mock(id: "MRT3_AYALA",   name: "Ayala Station",    shortName: "Ayala",    line: "MRT-3", type: "train")
    let to   = Station.mock(id: "MRT3_KALAW",   name: "Kalaw Station",    shortName: "Kalaw",    line: "MRT-3", type: "train")
    let stops: [Station] = [
        from,
        .mock(id: "MRT3_BUENDIA", name: "Buendia Station",  shortName: "Buendia",  line: "MRT-3", type: "train"),
        .mock(id: "MRT3_VITO",    name: "Vito Cruz Station", shortName: "Vito Cruz",line: "MRT-3", type: "train"),
        to,
    ]
    let leg = RouteLeg.mock(from: from, to: to, mode: .train, line: "MRT-3",
                            direction: "southbound", stops: stops,
                            minutes: 12, fare: 28, distanceKm: 4.1,
                            instruction: "Ride MRT-3 Southbound to Kalaw")
    List { RouteLegRow(leg: leg) }.listStyle(.plain)
}

#Preview("Route Leg Row – Walk") {
    let from = Station.mock(id: "MRT3_KALAW",  name: "Kalaw Station",   shortName: "Kalaw",  line: "MRT-3", type: "train")
    let to   = Station.mock(id: "LRT1_CENTRAL",name: "Central Station", shortName: "Central",line: "LRT-1", type: "train")
    let leg  = RouteLeg.mock(from: from, to: to, mode: .walk, line: "walk",
                             minutes: 5, fare: 0, distanceKm: 0.4,
                             instruction: "Walk to LRT-1 Central Station")
    List { RouteLegRow(leg: leg) }.listStyle(.plain)
}

#Preview("Route Leg Row – Jeepney") {
    let from = Station.mock(id: "JEEP_QUIAPO", name: "Quiapo Church",  shortName: "Quiapo", line: "JEEPNEY_QUIAPO_CUBAO", type: "jeepney")
    let to   = Station.mock(id: "JEEP_CUBAO",  name: "Cubao Terminal", shortName: "Cubao",  line: "JEEPNEY_QUIAPO_CUBAO", type: "jeepney")
    let stops: [Station] = [
        from,
        .mock(id: "JEEP_STA_MESA", name: "Sta. Mesa",     shortName: "Sta. Mesa",  line: "JEEPNEY_QUIAPO_CUBAO", type: "jeepney"),
        .mock(id: "JEEP_ESPANA",   name: "España Blvd.",  shortName: "España",     line: "JEEPNEY_QUIAPO_CUBAO", type: "jeepney"),
        to,
    ]
    let leg = RouteLeg.mock(from: from, to: to, mode: .jeepney, line: "JEEPNEY_QUIAPO_CUBAO",
                            stops: stops, minutes: 22, fare: 14, distanceKm: 6.8,
                            instruction: "Ride Jeepney (Quiapo–Cubao) to Cubao Terminal")
    List { RouteLegRow(leg: leg) }.listStyle(.plain)
}

#Preview {
    ContentView()
}
