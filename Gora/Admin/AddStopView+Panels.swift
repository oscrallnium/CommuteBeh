//
//  AddStopView+Panels.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/7/26.
//

import SwiftUI
import MapKit

// The bottom panel: the form, the direction choice, the coordinate readout, and the polyline list.
// These members are internal only because the stored properties they read sit in AddStopView.swift.

extension AddStopView {

    // MARK: - Panels

    var instructionPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.tap")
            Text("Tap the route to place the stop")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .clipShape(Capsule())
    }

    var formPanel: some View {
        VStack(spacing: 12) {
            ScrollView {
                VStack(spacing: 12) {
                    coordinateReadout

                    TextField("Stop name", text: $name)
                        .textFieldStyle(.roundedBorder)

                    Picker("Position", selection: $position) {
                        Text("Before").tag("before")
                        Text("After").tag("after")
                    }
                    .pickerStyle(.segmented)

                    // A directional line holds two independent chains; an insert applies to
                    // exactly one of them, so it has to be chosen before anything else
                    // makes sense.
                    if chains.count > 1 {
                        Picker("Direction", selection: $selectedChainPrefix) {
                            ForEach(chains, id: \.prefix) { chain in
                                Text(chain.prefix).tag(chain.prefix)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: selectedChainPrefix) { _, _ in
                            referenceStationId = orderedStations.first?.id ?? ""
                            tappedCoordinate = nil
                            tapChoice = nil
                            resolvedHeading = nil
                        }
                    }

                    directionChoiceRow

                    Picker("Reference stop", selection: $referenceStationId) {
                        ForEach(orderedStations) { station in
                            Text(station.name).tag(station.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: referenceStationId) { _, newValue in
                        // Keeps `resolvedHeading` current for the *next* tap even when the
                        // admin picks a stop by hand instead of resolving a choice — see
                        // `StopInsertionPreview.headingOfSegment`.
                        resolvedHeading = StopInsertionPreview.headingOfSegment(
                            startingAt: newValue, stations: orderedStations, edges: chainEdges
                        )
                        // Picking a stop from this menu is how the admin finds it on a
                        // route framed on the whole chain at open (`init`'s own comment) —
                        // without this, a long route leaves them hunting for it by eye
                        // before they can tap anywhere near it. A tap-driven change lands
                        // here too, but the resolved station already sits at or near the
                        // tap, so this only ever nudges the camera a short distance there.
                        if let station = orderedStations.first(where: { $0.id == newValue }) {
                            withAnimation(DesignTokens.Motion.cameraFit) {
                                cameraPosition = .region(Self.region(spanning: [station]))
                            }
                        }
                    }

                    stopOrderSection

                    polylinePreviewSection
                }
                .padding(.horizontal, 2)
            }
            // Self-sizing to min(content, cap), with `fixedSize` outermost — matching
            // `RouteLegList`'s own use of this pair. Without it, `frame(maxHeight:)` alone
            // always claims the full 360, so hiding the polyline card (see
            // `polylinePreviewSection`) left this much blank space behind rather than
            // shrinking the panel to whatever is actually left to show.
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)

            if let error = errorMessage {
                Text(error).font(.caption).foregroundStyle(Color.vermilion)
            }

            Button {
                Task { await save() }
            } label: {
                if isSaving {
                    HStack {
                        ProgressView().tint(.white)
                        Text(isFetchingGeometry ? "Fetching road route…" : "Adding…")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text(allowSaveWithoutGeometry ? "Add Stop Without Road Geometry" : "Add Stop")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            // Disabled while the road route is in flight: saving mid-fetch would take the
            // "no geometry" path and ask the admin to override something that is seconds
            // from arriving. Also disabled while a direction choice is unresolved — saving
            // a guess between two carriageways is exactly the failure this view exists to
            // prevent.
            .disabled(isSaving || isFetchingGeometry || placedCoordinate == nil
                      || name.trimmingCharacters(in: .whitespaces).isEmpty
                      || referenceStationId.isEmpty
                      || tapChoice != nil)
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.bottom, 32)
    }

    /// A `Picker` between the two segments a tap resolved to, shown only when
    /// `StopInsertionPreview.resolveTap` found a nearby segment pointing the opposite way.
    /// Uses its own binding rather than `$referenceStationId` directly, so picking either
    /// option is what clears `tapChoice` — changing `referenceStationId` any other way
    /// (the Reference-stop menu below) leaves a pending choice exactly as ambiguous as it
    /// was, since that picker doesn't know which of the two roads it's choosing between.
    @ViewBuilder
    var directionChoiceRow: some View {
        if let tapChoice, let alternative = tapChoice.alternative {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.arrow.right")
                    Text("This road carries the route both ways here. Which stop is this for?")
                }
                .font(.caption)
                .foregroundStyle(Color.ember)

                Picker("Direction", selection: directionChoiceSelection) {
                    Text(tapChoice.chosen.station.name).tag(tapChoice.chosen.station.id)
                    Text(alternative.station.name).tag(alternative.station.id)
                }
                .pickerStyle(.segmented)
            }
            .padding(10)
            .background(Color.ember.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Resolving `tapChoice` is a side effect of the admin's pick, not just a value
    /// change, so it goes through a custom binding rather than `$referenceStationId`.
    var directionChoiceSelection: Binding<String> {
        Binding(
            get: { referenceStationId },
            set: { newValue in
                referenceStationId = newValue
                position = "after"
                tapChoice = nil
            }
        )
    }

    private var coordinateReadout: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: placedCoordinate == nil ? "mappin.slash" : "mappin.circle.fill")
                    .foregroundStyle(placedCoordinate == nil ? Color.secondary : Color.onyx)
                Text(placedCoordinate.map { String(format: "%.6f,  %.6f", $0.latitude, $0.longitude) }
                     ?? "No location placed yet")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(placedCoordinate == nil ? Color.secondary : Color.primary)
                Spacer()
            }

            if tapTooFarFromRoute {
                HStack {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(Color.ember)
                    Text("Tap is far from every stop on this chain — choose the reference stop by hand.")
                        .font(.caption2)
                        .foregroundStyle(Color.ember)
                    Spacer()
                }
            } else if let snap, snap.didSnap, let distance = snap.snappedDistanceMeters {
                HStack {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .foregroundStyle(Color.jade)
                    Text(String(format: "Snapped %.1f m onto a polyline point", distance))
                        .font(.caption2)
                        .foregroundStyle(Color.jade)
                    Spacer()
                }
            } else if placedCoordinate != nil {
                HStack {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                    Text(snapEnabled
                         ? "No polyline point within \(Int(Self.snapRadiusMeters)) m — using the exact tap."
                         : "Snapping off — using the exact tap.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            Toggle(isOn: $snapEnabled) {
                Text("Snap to polyline points")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
    }

    /// The boxed card only earns its background when it actually has polylines to list —
    /// a `preview` with none (e.g. mid-fetch, `newPolylines: []` with only `warning` set)
    /// drew an otherwise-empty box with just a header and a warning line, which read as a
    /// card about nothing. That state now falls through to the same plain, unboxed
    /// warning text the "no preview at all" case already used below.
    @ViewBuilder
    private var polylinePreviewSection: some View {
        if let preview, !preview.newPolylines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Polylines created")
                        .font(.caption.bold())
                    Spacer()
                    Text(preview.newStationID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }

                if let replaced = preview.replacedEdge {
                    Text("Replaces \(replaced.id) · \(replaced.coordinates.count) pts"
                         + (preview.splitVertexIndex.map { " · split at point \($0 + 1)" } ?? ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(preview.newPolylines.enumerated()), id: \.element.id) { index, poly in
                    polylineRow(poly, color: index == 0 ? Color.slate : Color.ember)
                }

                if let warning = preview.warning {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(warning)
                    }
                    .font(.caption2)
                    .foregroundStyle(Color.ember)
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else if let warning = preview?.warning {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(warning)
            }
            .font(.caption2)
            .foregroundStyle(Color.ember)
        } else if placedCoordinate != nil {
            Text("No polyline preview for this position — the backend may reject inserting here.")
                .font(.caption2)
                .foregroundStyle(Color.ember)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func polylineRow(_ poly: StopInsertionPreview.NewPolyline, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expandedPolylineID = expandedPolylineID == poly.id ? nil : poly.id
            } label: {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color)
                        .frame(width: 14, height: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(poly.fromName) → \(poly.toName)")
                            .font(.caption)
                            .lineLimit(1)
                        Text("\(poly.id) · \(poly.coordinates.count) pts · "
                             + String(format: "%.2f km", poly.lengthKm)
                             + (poly.isFetched ? " · road route" : " · sliced"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: expandedPolylineID == poly.id ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if expandedPolylineID == poly.id {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(poly.coordinates.enumerated()), id: \.offset) { i, point in
                            Text(String(format: "%2d  %.6f, %.6f", i + 1, point.lat, point.lng))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(
                                    isNewStopVertex(point) ? Color.onyx : Color.secondary
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        }
    }

    /// Highlights the vertex that coincides with the stop being added — after snapping
    /// that's the shared junction both halves keep.
    private func isNewStopVertex(_ point: Coordinates) -> Bool {
        guard let placedCoordinate else { return false }
        return abs(point.lat - placedCoordinate.latitude) < 1e-9
            && abs(point.lng - placedCoordinate.longitude) < 1e-9
    }

    // MARK: - Stop order

    /// One row of the stop-order list.
    struct StopOrderRow: Identifiable {
        enum Kind { case existing, reference, new, loopBack }
        let id: String
        var number: Int?
        let name: String
        let kind: Kind
    }

    /// The chain in travel order after the insert, with the new stop at its slot. A closed
    /// loop ends with a row for the return to the first stop.
    var stopOrderRows: [StopOrderRow] {
        let ordered = orderedStations
        var rows = ordered.map {
            StopOrderRow(id: $0.id, name: $0.name, kind: $0.id == referenceStationId ? .reference : .existing)
        }
        if let slot = StopInsertionPreview.slot(
            referenceStationID: referenceStationId, position: position,
            ordered: ordered, edges: chainEdges
        ) {
            let newName = name.trimmingCharacters(in: .whitespaces)
            rows.insert(StopOrderRow(id: "new", name: newName.isEmpty ? "New stop" : newName, kind: .new),
                        at: min(slot.p - 1, rows.count))
        }
        for index in rows.indices { rows[index].number = index + 1 }
        if StopInsertionPreview.isClosedLoop(ordered, edges: chainEdges), let first = ordered.first {
            rows.append(StopOrderRow(id: "loop-back", name: "Back to \(first.name)", kind: .loopBack))
        }
        return rows
    }

    /// Stops this close to the new stop stay visible when the list is collapsed.
    private static let collapsedStopRadius = 2

    private var stopOrderSection: some View {
        let rows = stopOrderRows
        let newIndex = rows.firstIndex { $0.kind == .new } ?? 0
        let isCollapsible = rows.count > Self.collapsedStopRadius * 2 + 1
        let visible = showAllStops || !isCollapsible
            ? rows[...]
            : rows[max(0, newIndex - Self.collapsedStopRadius)...min(rows.count - 1, newIndex + Self.collapsedStopRadius)]

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Stop order")
                    .font(.caption.bold())
                Spacer()
                if isCollapsible {
                    Button(showAllStops ? "Show fewer" : "Show all \(rows.count)") { showAllStops.toggle() }
                        .font(.caption2)
                }
            }
            ForEach(visible) { stopOrderRow($0) }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func stopOrderRow(_ row: StopOrderRow) -> some View {
        HStack(spacing: 8) {
            Group {
                if let number = row.number {
                    Text("\(number)")
                } else {
                    Image(systemName: "arrow.uturn.backward")
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 22, alignment: .trailing)

            Circle()
                .fill(row.kind == .new ? Color.onyx : Color.canvas)
                .stroke(row.kind == .existing || row.kind == .loopBack ? Color.slate : Color.onyx, lineWidth: 2)
                .frame(width: 9, height: 9)

            Text(row.name)
                .font(row.kind == .new || row.kind == .reference ? .caption.bold() : .caption)
                .foregroundStyle(row.kind == .loopBack ? Color.secondary : .primary)
                .lineLimit(1)

            if row.kind == .reference {
                Text("Reference")
                    .font(.caption2)
                    .foregroundStyle(Color.onyx)
            }
            Spacer()
        }
    }
}
