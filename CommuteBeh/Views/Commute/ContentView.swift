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
    @Namespace private var searchNS

    private enum SearchField { case origin, destination }

    private static let manilaRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 14.5763, longitude: 121.0194),
        span: MKCoordinateSpan(latitudeDelta: 0.18, longitudeDelta: 0.18)
    )

    var body: some View {
        MapReader { proxy in
            Map(position: $mapPosition) {
                if let result = vm.routeResult {
                    // ── Polylines — one per RouteLeg ─────────────────────────────
                    ForEach(result.legs) { leg in
                        let coords = leg.polylineCoordinates.map {
                            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
                        }
                        if leg.line == "ACCESS_WALK" {
                            // Access/egress walk: dashed gray to match TransportModeConfig.mapLineDash
                            MapPolyline(coordinates: coords)
                                .stroke(.gray.opacity(0.6),
                                        style: StrokeStyle(lineWidth: 2.5, dash: [6, 5]))
                        } else {
                            MapPolyline(coordinates: coords)
                                .stroke(leg.mode.color, lineWidth: leg.mode.lineWidth)
                        }
                    }
                    // ── Origin pin ───────────────────────────────────────────────
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
                    // ── Destination pin ──────────────────────────────────────────
                    if let last = result.legs.last {
                        let destLabel = last.line == "ACCESS_WALK" ? "" : last.toStation.shortName
                        Annotation(destLabel, coordinate: CLLocationCoordinate2D(
                            latitude: last.toStation.coordinates.lat,
                            longitude: last.toStation.coordinates.lng
                        )) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title)
                                .foregroundStyle(.red)
                                .shadow(color: .black.opacity(0.4), radius: 2)
                        }
                    }
                    // ── Transfer dots — boarding station of every non-access leg ──
                    ForEach(result.legs.dropFirst().filter { $0.line != "ACCESS_WALK" }) { leg in
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
                if !vm.routeOptions.isEmpty {
                    RouteResultsPanel(
                        options: vm.routeOptions,
                        onSelect: { vm.selectRoute($0) },
                        onPreview: { vm.previewRoute($0) }
                    )
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(DesignTokens.Motion.cardEnter, value: vm.routeOptions.isEmpty)
            .onChange(of: vm.isLoading) { _, isLoading in
                if !isLoading, let result = vm.routeResult { fitMap(to: result) }
            }
            .task(id: vm.isLoading) {
                if vm.isLoading {
                    try? await Task.sleep(for: DesignTokens.Motion.progressGraceDelay)
                    if vm.isLoading { showSearchProgress = true }
                } else if showSearchProgress {
                    try? await Task.sleep(for: DesignTokens.Motion.progressMinVisible)
                    showSearchProgress = false
                }
            }
            // Long-press on map: first press sets origin, subsequent presses set destination.
            .gesture(
                LongPressGesture(minimumDuration: 0.5)
                    .simultaneously(with: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                    .onEnded { value in
                        guard value.first == true else { return }
                        if let cgPoint = value.second?.startLocation,
                           let clCoord = proxy.convert(cgPoint, from: .local) {
                            handleMapLongPress(at: Coordinates(
                                lat: clCoord.latitude, lng: clCoord.longitude))
                        }
                    }
            )
        }
    }

    // MARK: - Design constants

    private static let orange = Color(red: 0.91, green: 0.38, blue: 0.16)
    private static let originGreen = Color(red: 0.18, green: 0.48, blue: 0.20)
    private static let cardCream = Color(red: 0.96, green: 0.94, blue: 0.90)

    // MARK: - Search Panel

    private var isSearchCollapsed: Bool {
        vm.isLoading || !vm.routeOptions.isEmpty
    }

    private var searchPanel: some View {
        Group {
            if isSearchCollapsed {
                collapsedSearchPill
                    .transition(.opacity)
            } else {
                expandedSearchCard
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: isSearchCollapsed)
    }

    // MARK: Collapsed pill (shown while loading / showing results)

    private var collapsedSearchPill: some View {
        HStack(spacing: 10) {
            Button(action: resetAll) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(.white))
                    .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Circle()
                    .fill(Self.originGreen)
                    .frame(width: 8, height: 8)
                    .matchedGeometryEffect(id: "origin-dot", in: searchNS, properties: .position)

                Text(originText)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                    .matchedGeometryEffect(id: "origin-text", in: searchNS, properties: .position)

                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)

                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary)
                    .frame(width: 8, height: 8)
                    .matchedGeometryEffect(id: "dest-dot", in: searchNS, properties: .position)

                Text(destinationText)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                    .matchedGeometryEffect(id: "dest-text", in: searchNS, properties: .position)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Capsule().fill(.white))
            .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 2)

            Spacer()
        }
    }

    // MARK: Expanded card (default search state)

    private var expandedSearchCard: some View {
        VStack(spacing: 6) {
            VStack(spacing: 0) {
                // Origin field
                HStack(spacing: 14) {
                    Circle()
                        .fill(Self.originGreen)
                        .frame(width: 10, height: 10)
                        .matchedGeometryEffect(id: "origin-dot", in: searchNS, properties: .position)
                    ZStack(alignment: .leading) {
                        // Invisible anchor for the origin name — used only for geometry matching
                        Text(originText)
                            .font(.system(.body, weight: .semibold))
                            .opacity(0)
                            .matchedGeometryEffect(id: "origin-text", in: searchNS, properties: .position)
                            .allowsHitTesting(false)
                        TextField("Start", text: $originText)
                            .font(.system(.body, weight: .semibold))
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .origin)
                            .onChange(of: originText) { _, val in updateOriginSuggestions(val) }
                    }
                    if !originText.isEmpty {
                        Button(action: clearOrigin) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.gray.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 15)

                dashedDivider.padding(.horizontal, 18)

                // Destination field
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Self.orange)
                        .frame(width: 10, height: 10)
                        .matchedGeometryEffect(id: "dest-dot", in: searchNS, properties: .position)
                    ZStack(alignment: .leading) {
                        // Invisible anchor for the destination name — geometry matching only
                        Text(destinationText)
                            .font(.system(.body, weight: .semibold))
                            .opacity(0)
                            .matchedGeometryEffect(id: "dest-text", in: searchNS, properties: .position)
                            .allowsHitTesting(false)
                        TextField("Destination", text: $destinationText)
                            .font(.system(.body, weight: .semibold))
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .destination)
                            .onChange(of: destinationText) { _, val in updateDestSuggestions(val) }
                    }
                    if !destinationText.isEmpty {
                        Button(action: clearDestination) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.gray.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 15)

                // Action row
                HStack(spacing: 12) {
                    Button {
                        focusedField = nil
                        Task { await vm.calculateRoute() }
                    } label: {
                        Group {
                            if showSearchProgress {
                                ProgressView().tint(.white)
                            } else {
                                Text("SEARCH ROUTE")
                                    .font(.system(.subheadline, weight: .bold))
                                    .kerning(1.2)
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Capsule().fill(Self.orange))
                    }
                    .disabled(!vm.canCalculate || vm.isLoading)
                    .opacity(!vm.canCalculate ? 0.55 : 1)

                    Button(action: swapOriginDestination) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 46, height: 46)
                            .background(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 14)

                if let error = vm.errorMessage {
                    Text(error)
                        .font(DesignTokens.TypeScale.meta)
                        .foregroundStyle(DesignTokens.Colors.destructive)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 12)
                }
            }
            .background(Self.cardCream)
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
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if showDestSuggestions && !destSuggestions.isEmpty {
                SuggestionList(stations: Array(destSuggestions.prefix(5))) { station in
                    selectDestination(station)
                }
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
                .cardShadow(y: 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(DesignTokens.Motion.suggestEnter, value: suggestionsVisible)
    }

    private var dashedDivider: some View {
        GeometryReader { geo in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0.5))
                path.addLine(to: CGPoint(x: geo.size.width, y: 0.5))
            }
            .stroke(Color.primary.opacity(0.15),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .frame(height: 1)
    }

    private var suggestionsVisible: Bool {
        (showOriginSuggestions && !originSuggestions.isEmpty) ||
        (showDestSuggestions && !destSuggestions.isEmpty)
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
        vm.originCoordinate = nil
        showOriginSuggestions = false
        originSuggestions = []
        focusedField = .destination
    }

    private func selectDestination(_ station: Station) {
        destinationText = station.name
        vm.destinationID = station.id
        vm.destinationCoordinate = nil
        showDestSuggestions = false
        destSuggestions = []
        focusedField = nil
    }

    private func clearOrigin() {
        originText = ""; vm.originID = ""
        vm.originCoordinate = nil
        originSuggestions = []; showOriginSuggestions = false
    }

    private func clearDestination() {
        destinationText = ""; vm.destinationID = ""
        vm.destinationCoordinate = nil
        destSuggestions = []; showDestSuggestions = false
    }

    private func resetAll() {
        focusedField = nil
        clearOrigin(); clearDestination()
        vm.routeResult = nil
        vm.routeOptions = []
        vm.errorMessage = nil
        withAnimation(.easeInOut(duration: 0.4)) {
            mapPosition = .region(Self.manilaRegion)
        }
    }

    private func swapOriginDestination() {
        let tempText  = originText
        let tempID    = vm.originID
        let tempCoord = vm.originCoordinate

        originText           = destinationText
        vm.originID          = vm.destinationID
        vm.originCoordinate  = vm.destinationCoordinate

        destinationText         = tempText
        vm.destinationID        = tempID
        vm.destinationCoordinate = tempCoord

        // Normalise virtual IDs after the swap
        if vm.originID == RouteRequest.virtualDestID       { vm.originID = RouteRequest.virtualOriginID }
        if vm.destinationID == RouteRequest.virtualOriginID { vm.destinationID = RouteRequest.virtualDestID }

        showOriginSuggestions = false
        showDestSuggestions   = false
        originSuggestions     = []
        destSuggestions       = []
    }

    /// Long-press handler: sets the tapped coordinate as origin if unset, destination otherwise.
    private func handleMapLongPress(at coord: Coordinates) {
        if vm.originID.isEmpty {
            originText = "Pinned Location"
            showOriginSuggestions = false
            vm.setOriginCoordinate(coord)
        } else {
            destinationText = "Pinned Location"
            showDestSuggestions = false
            vm.setDestinationCoordinate(coord)
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

// MARK: - Route Results Panel

struct RouteResultsPanel: View {
    let options: [RouteOption]
    let onSelect: (RouteOption) -> Void
    let onPreview: (RouteOption) -> Void

    @State private var selectedIndex: Int = 0

    private static let cardCream = Color(red: 0.96, green: 0.94, blue: 0.90)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BEST WAY THERE")
                .font(.subheadline.weight(.heavy))
                .kerning(0.8)
                .padding(.horizontal, 4)

            ForEach(Array(options.enumerated()), id: \.element.id) { i, option in
                RouteOptionCard(
                    option: option,
                    isExpanded: i == selectedIndex,
                    onExpand: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            selectedIndex = i
                        }
                        onPreview(option)
                    },
                    onSelect: { onSelect(option) }
                )
                .jellyEffect(trigger: i == selectedIndex)
            }
        }
        .padding(16)
        .background(Self.cardCream)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.10), radius: 12, x: 0, y: -4)
    }
}

// MARK: - Route Option Card

private struct RouteOptionCard: View {
    let option: RouteOption
    let isExpanded: Bool
    let onExpand: () -> Void
    let onSelect: () -> Void

    @Namespace private var ns

    private static let fastestBlue   = Color(red: 0.22, green: 0.45, blue: 0.87)
    private static let cheapestGreen = Color(red: 0.18, green: 0.60, blue: 0.28)
    private static let orange        = Color(red: 0.91, green: 0.38, blue: 0.16)

    private var result: RouteResult { option.result }

    // VStack with a persistent header row lets SwiftUI interpolate the card's height
    // smoothly as the conditional sections are added/removed below it.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            compactBar
            if !isExpanded {
                collapsedSubRow
                    .transition(.opacity)
            }
            if isExpanded {
                expandedSection
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
        .clipped()
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isExpanded ? Color.primary.opacity(0.12) : Color.primary.opacity(0.07),
                        lineWidth: isExpanded ? 1.5 : 1)
        )
        .shadow(color: isExpanded ? .black.opacity(0.08) : .clear, radius: 6, x: 0, y: 2)
    }

    // MARK: Compact bar — only rendered when collapsed.
    // SwiftUI tracks the last-known geometry positions even after this view leaves the
    // hierarchy, so matchedGeometryEffect in expandedSection still animates correctly.

    @ViewBuilder
    private var compactBar: some View {
        if !isExpanded {
            Button(action: onExpand) {
                HStack(alignment: .center) {
                    HStack(spacing: 6) {
                        Text("\(Int(result.totalTimeMinutes)) min")
                            .font(.system(.body, design: .default, weight: .bold))
                            .matchedGeometryEffect(id: "time", in: ns, properties: .position)
                        labelBadge(compact: true)
                            .matchedGeometryEffect(id: "badge", in: ns, properties: .position)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("₱").font(.footnote.bold())
                            Text("\(Int(result.totalFare))").font(.body.bold())
                        }
                        .matchedGeometryEffect(id: "fare", in: ns, properties: .position)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .transition(.opacity)
        }
    }

    // MARK: Collapsed-only sub-row

    private var collapsedSubRow: some View {
        HStack(spacing: 4) {
            Text("Arrive at \(arrivalText)")
                .font(.caption).foregroundStyle(.secondary)
            if !paymentsText.isEmpty {
                Text("·").font(.caption).foregroundStyle(.secondary)
                Text(paymentsText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: Expanded-only section

    private var expandedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row 1: label badge + departure | payment chips
            HStack(spacing: 8) {
                labelBadge(compact: false)
                    .matchedGeometryEffect(id: "badge", in: ns, properties: .position)
                Text(departureText).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(acceptedPayments, id: \.self) { paymentChip($0) }
                }
            }

            // Row 2: duration | fare
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(result.totalTimeMinutes)) min")
                    .font(.system(.title, design: .default, weight: .bold))
                    .matchedGeometryEffect(id: "time", in: ns, properties: .position)
                Text("Arrive at \(arrivalText)")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("₱").font(.subheadline.bold())
                    Text("\(Int(result.totalFare))").font(.title2.bold())
                }
                .matchedGeometryEffect(id: "fare", in: ns, properties: .position)
            }

            // Dashed divider
            GeometryReader { geo in
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0.5))
                    p.addLine(to: CGPoint(x: geo.size.width, y: 0.5))
                }
                .stroke(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            .frame(height: 1)

            // Row 3: mode chips (single-line, horizontally scrollable)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(legChips) { legChipView($0) }
                }
                .padding(.horizontal, 1)
            }

            // Row 4: transfer + walk stats
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.swap")
                    .font(.caption).foregroundStyle(.secondary)
                Text(statsText).font(.caption).foregroundStyle(.secondary)
            }

            // USE THIS ROUTE button
            Button(action: onSelect) {
                Text("USE THIS ROUTE")
                    .font(.system(.subheadline, design: .default, weight: .bold))
                    .kerning(1.0)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Self.orange))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    // MARK: Badge (shared between expanded and collapsed)

    @ViewBuilder
    private func labelBadge(compact: Bool) -> some View {
        let hPad: CGFloat = compact ? 7 : 10
        let vPad: CGFloat = compact ? 3 : 5
        let font: Font  = compact ? .caption2.weight(.heavy) : .caption.weight(.heavy)
        switch option.label {
        case .fastest:
            Text("FASTEST")
                .font(font)
                .foregroundStyle(.white)
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .padding(.horizontal, hPad).padding(.vertical, vPad)
                .background(Capsule().fill(Self.fastestBlue))
        case .cheapest:
            Text("CHEAPEST")
                .font(font)
                .foregroundStyle(.white)
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .padding(.horizontal, hPad).padding(.vertical, vPad)
                .background(Capsule().fill(Self.cheapestGreen))
        case .balanced:
            EmptyView()
        }
    }

    @ViewBuilder
    private func paymentChip(_ paymentID: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: sfSymbol(for: paymentID))
                .font(.caption2)
            Text(shortName(for: paymentID))
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.35), lineWidth: 1))
    }

    // MARK: Computed

    private var departureText: String {
        guard let first = result.legs.first else { return "" }
        let dep = first.estimatedArrival.addingTimeInterval(-first.effectiveTravelMinutes * 60)
        let fmt = DateFormatter(); fmt.dateFormat = "h:mm a"
        return "Leaves \(fmt.string(from: dep))"
    }

    private var arrivalText: String {
        guard let last = result.legs.last else { return "" }
        let fmt = DateFormatter(); fmt.dateFormat = "h:mm a"
        return fmt.string(from: last.estimatedArrival)
    }

    private var acceptedPayments: [String] {
        let nonWalk = result.legs.filter { $0.mode != .walk }
        guard !nonWalk.isEmpty else { return [] }
        var common = Set(nonWalk[0].rawSteps.flatMap { $0.edge.acceptedPayments })
        for leg in nonWalk.dropFirst() {
            common = common.intersection(Set(leg.rawSteps.flatMap { $0.edge.acceptedPayments }))
        }
        return Array(common).sorted()
    }

    private var paymentsText: String {
        acceptedPayments.map { shortName(for: $0) }.joined(separator: " · ")
    }

    private struct LegChip: Identifiable {
        let id = UUID()
        let label: String
        let color: Color
        let isWalk: Bool
    }

    private var legChips: [LegChip] {
        result.legs
            .filter { $0.line != "ACCESS_WALK" }
            .map { leg -> LegChip in
                if leg.mode == .walk || leg.line == "INTERCHANGE" {
                    let mins = Int(leg.effectiveTravelMinutes.rounded())
                    return LegChip(label: "Walk · \(mins) min", color: .gray, isWalk: true)
                }
                let stops = leg.stopCount
                return LegChip(
                    label: "\(leg.line) · \(stops) stop\(stops == 1 ? "" : "s")",
                    color: leg.mode.color, isWalk: false
                )
            }
    }

    @ViewBuilder
    private func legChipView(_ chip: LegChip) -> some View {
        Text(chip.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(chip.isWalk ? AnyShapeStyle(.secondary) : AnyShapeStyle(chip.color))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(chip.isWalk ? Color.secondary.opacity(0.1) : chip.color.opacity(0.12)))
    }

    private var statsText: String {
        let xfers = result.transfers
        let walkMins = Int(result.legs
            .filter { $0.mode == .walk && $0.line != "ACCESS_WALK" }
            .reduce(0.0) { $0 + $1.effectiveTravelMinutes }
            .rounded())
        let xferPart = xfers == 0 ? "Direct" : "\(xfers) transfer\(xfers > 1 ? "s" : "")"
        let walkPart = walkMins > 0 ? " · \(walkMins) min\(walkMins == 1 ? "" : "s") walking" : ""
        return "\(xferPart)\(walkPart)"
    }

    private func sfSymbol(for paymentID: String) -> String {
        switch paymentID {
        case "beep_card": return "creditcard.fill"
        case "cash":      return "banknote"
        case "gcash":     return "g.circle.fill"
        case "maya":      return "m.circle.fill"
        case "card":      return "creditcard"
        default:          return "banknote"
        }
    }

    private func shortName(for paymentID: String) -> String {
        switch paymentID {
        case "beep_card": return "Beep"
        case "cash":      return "Cash"
        case "gcash":     return "GCash"
        case "maya":      return "Maya"
        case "card":      return "Card"
        default:          return paymentID.capitalized
        }
    }
}

// MARK: - Jelly Effect Modifier

/// Applies a spring-bounce to the view's container (background, border, shadow) when `trigger`
/// changes. The initial compression (scale = 1 − intensity) springs back with low damping so it
/// overshoots slightly before settling — producing the "jelly" feel.
///
/// Usage:
///   RouteOptionCard(...).jellyEffect(trigger: isExpanded)
///   someButton.jellyEffect(trigger: isPressed, intensity: 0.06)
struct JellyEffect<T: Equatable>: ViewModifier {
    let trigger: T
    var intensity: CGFloat = 0.04

    @State private var scale: CGFloat = 1.0

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onChange(of: trigger) { _, _ in
                scale = 1.0 - intensity
                withAnimation(.spring(response: 0.38, dampingFraction: 0.28)) {
                    scale = 1.0
                }
            }
    }
}

extension View {
    func jellyEffect(trigger: some Equatable, intensity: CGFloat = 0.04) -> some View {
        modifier(JellyEffect(trigger: trigger, intensity: intensity))
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

#Preview("Route Results Panel") {
    let ayala   = Station.mock(id: "MRT3_AYALA",    name: "Ayala Station",    shortName: "Ayala",      line: "MRT-3", type: "train")
    let kalaw   = Station.mock(id: "MRT3_KALAW",    name: "Kalaw Station",    shortName: "Kalaw",      line: "MRT-3", type: "train")
    let central = Station.mock(id: "LRT1_CENTRAL",  name: "Central Station",  shortName: "Central",    line: "LRT-1", type: "train")
    let avenida = Station.mock(id: "LRT1_AVENIDA",  name: "Avenida Station",  shortName: "Avenida",    line: "LRT-1", type: "train")
    let carriedo = Station.mock(id: "LRT1_CARRIEDO", name: "Carriedo Station", shortName: "Carriedo",  line: "LRT-1", type: "train")

    let mrt3Stops: [Station] = [
        ayala,
        .mock(id: "MRT3_BUENDIA",  name: "Buendia Station",  shortName: "Buendia",  line: "MRT-3", type: "train"),
        .mock(id: "MRT3_VITO",     name: "Vito Cruz Station", shortName: "Vito Cruz",line: "MRT-3", type: "train"),
        kalaw,
    ]
    let lrt1Stops: [Station] = [central, carriedo, avenida]

    let fastestLegs: [RouteLeg] = [
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
    let cheapestLegs: [RouteLeg] = [
        .mock(from: ayala, to: avenida, mode: .jeepney, line: "JEEPNEY_QUIAPO_CUBAO",
              minutes: 48, fare: 15, distanceKm: 9.2,
              instruction: "Ride Jeepney to Avenida",
              arrival: Date().addingTimeInterval(2880)),
    ]

    let fastest  = RouteResult(legs: fastestLegs,  totalTimeMinutes: 25, totalFare: 48,  totalDistanceKm: 7.4, transfers: 2, modes: [.train, .train])
    let cheapest = RouteResult(legs: cheapestLegs, totalTimeMinutes: 48, totalFare: 15,  totalDistanceKm: 9.2, transfers: 0, modes: [.jeepney])

    let options: [RouteOption] = [
        RouteOption(result: fastest,  label: .fastest),
        RouteOption(result: cheapest, label: .cheapest),
    ]

    ZStack(alignment: .bottom) {
        Color(.systemGroupedBackground).ignoresSafeArea()
        RouteResultsPanel(options: options, onSelect: { _ in }, onPreview: { _ in }).padding()
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
