//
//  PolylineRecorderView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 7/25/26.
//

import SwiftUI
import MapKit
import CoreLocation

// MARK: - Phase

enum PolylineRecordingPhase {
    case linePicker, recording, review, output
}

// MARK: - Staged Segment

/// One recorded GPS segment matched to an existing graph edge, awaiting review.
/// Never uploaded until the rider explicitly accepts it in the review phase.
struct StagedPolylineSegment: Identifiable {
    let edgeID: String
    let fromStationID: StationID
    let toStationID: StationID
    let fromName: String
    let toName: String
    let direction: String?
    let points: [Coordinates]              // RDP-simplified, ordered from -> to
    let existingPolyline: [Coordinates]     // what's currently on the edge, for comparison
    let recomputedDistanceKm: Double
    let existingDistanceKm: Double
    var isAccepted = true

    var id: String { edgeID }

    /// Flags an obviously-wrong match (e.g. a dropped signal or a mis-tapped direction)
    /// so the review list can surface it before anything gets uploaded.
    var distanceLooksOff: Bool {
        guard existingDistanceKm > 0 else { return false }
        let delta = abs(recomputedDistanceKm - existingDistanceKm) / existingDistanceKm
        return delta > 0.35
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class PolylineRecorderViewModel: NSObject {
    var phase: PolylineRecordingPhase = .linePicker

    // Line picker
    var availableLines: [String] = []
    var selectedLine: String?
    var isLoadingGraph = false
    var loadError: String?

    // Recording
    var rawWaypoints: [CLLocationCoordinate2D] = []
    var authStatus: CLAuthorizationStatus = .notDetermined
    var locationError: String?
    var currentStationID: StationID?
    var currentStationName: String?
    var currentDirection: String?
    var pendingDirectionStation: Station?
    var nearestStationDebug: String?
    var warningMessage: String?
    var skippedSegmentLog: [String] = []
    var proximityThresholdMeters: Double = 60

    // Review / save
    var stagedSegments: [StagedPolylineSegment] = []
    var isSaving = false
    var saveError: String?
    var savedCount = 0

    private var candidateStations: [Station] = []
    private var candidateEdges: [TransitEdge] = []
    private var stationIndex: [StationID: Station] = [:]
    private var segmentStartIndex = 0

    /// Empty for lines with only bidirectional edges (LRT-1/LRT-2) — no direction
    /// prompt is needed there since a single physical polyline serves both directions.
    var availableDirections: [String] = []

    private let locationManager: CLLocationManager

    override init() {
        locationManager = CLLocationManager()
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 15
        locationManager.activityType = .otherNavigation
        authStatus = locationManager.authorizationStatus
    }

    // MARK: Line selection

    func loadAvailableLines() async {
        isLoadingGraph = true
        loadError = nil
        switch await GraphLoader.ensureLoaded() {
        case .success(let graph):
            let trainEdges = graph.edges.filter { $0.mode == TransportMode.train.rawValue }
            availableLines = Array(Set(trainEdges.map(\.line))).sorted()
            stationIndex = Dictionary(uniqueKeysWithValues: graph.stations.map { ($0.id, $0) })
            allEdgesByLine = Dictionary(grouping: trainEdges, by: \.line)
            allStationsByLine = Dictionary(grouping: graph.stations, by: \.line)
        case .failure:
            loadError = "Couldn't load the transit graph. Check your connection and try again."
        }
        isLoadingGraph = false
    }

    private var allEdgesByLine: [String: [TransitEdge]] = [:]
    private var allStationsByLine: [String: [Station]] = [:]

    func selectLine(_ line: String) {
        selectedLine = line
        candidateEdges = allEdgesByLine[line] ?? []
        candidateStations = allStationsByLine[line] ?? []
        availableDirections = Array(Set(candidateEdges.compactMap(\.direction))).sorted()
    }

    // MARK: Recording lifecycle

    func requestPermission() { locationManager.requestAlwaysAuthorization() }

    func startRecording() {
        rawWaypoints = []
        stagedSegments = []
        currentStationID = nil
        currentStationName = nil
        currentDirection = nil
        pendingDirectionStation = nil
        warningMessage = nil
        skippedSegmentLog = []
        segmentStartIndex = 0
        locationError = nil
        applyBackgroundConfiguration()
        phase = .recording
        locationManager.startUpdatingLocation()
    }

    func finishRide() {
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        phase = stagedSegments.isEmpty ? .linePicker : .review
        if stagedSegments.isEmpty {
            warningMessage = "No segments were recorded — no station-to-station hop was completed."
        }
    }

    func cancelRecording() {
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        rawWaypoints = []
        stagedSegments = []
        phase = .linePicker
    }

    func setDirection(_ direction: String) {
        currentDirection = direction
        pendingDirectionStation = nil
    }

    // MARK: Background location

    /// Background updates require `.authorizedAlways` — setting the flag with any
    /// other status throws ("CLClientIsBackgroundable" invalid-parameter crash).
    /// Reads `locationManager.authorizationStatus` live rather than the cached
    /// `authStatus` property: that cache is only refreshed asynchronously from the
    /// `didChangeAuthorization` delegate callback, so it can still read `.authorizedAlways`
    /// for a moment after the OS has actually downgraded/revoked it (e.g. changed in
    /// Settings while the app was backgrounded), which is exactly the stale state that
    /// trips the assertion. Re-applied from `didChangeAuthorization` in case the user
    /// upgrades from "When In Use" to "Always" mid-session.
    private func applyBackgroundConfiguration() {
        guard locationManager.authorizationStatus == .authorizedAlways else {
            locationManager.allowsBackgroundLocationUpdates = false
            return
        }
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = true
    }

    // MARK: Proximity state machine

    private func handle(_ location: CLLocation) {
        rawWaypoints.append(location.coordinate)
        guard phase == .recording, !candidateStations.isEmpty else { return }

        guard let nearest = candidateStations.min(by: {
            distanceMeters(location, $0) < distanceMeters(location, $1)
        }) else { return }

        let dist = distanceMeters(location, nearest)
        nearestStationDebug = "\(nearest.name): \(Int(dist)) m"

        guard dist < proximityThresholdMeters, nearest.id != currentStationID else { return }
        arrive(at: nearest)
    }

    private func distanceMeters(_ location: CLLocation, _ station: Station) -> Double {
        CLLocation(latitude: station.coordinates.lat, longitude: station.coordinates.lng)
            .distance(from: location)
    }

    private func arrive(at station: Station) {
        if let previousID = currentStationID {
            closeSegment(fromID: previousID, toID: station.id)
        }
        currentStationID = station.id
        currentStationName = station.name
        segmentStartIndex = max(rawWaypoints.count - 1, 0)
        if currentDirection == nil, !availableDirections.isEmpty {
            pendingDirectionStation = station
        }
    }

    private func closeSegment(fromID: StationID, toID: StationID) {
        let endIndex = rawWaypoints.count - 1
        guard segmentStartIndex < endIndex else {
            log(warning: "\(stationName(fromID)) → \(stationName(toID)): too few GPS points to record.")
            return
        }
        let raw = Array(rawWaypoints[segmentStartIndex...endIndex])
        let simplified = RDPSimplifier.simplify(raw, epsilon: 0.00005)

        guard let (edge, ordered) = matchEdge(from: fromID, to: toID, points: simplified) else {
            let dirNote = currentDirection.map { " (\($0))" } ?? ""
            log(warning: "No \(stationName(fromID)) → \(stationName(toID))\(dirNote) edge in the graph — skipped.")
            return
        }

        let distanceKm = haversineSumKm(ordered)
        let staged = StagedPolylineSegment(
            edgeID: edge.id,
            fromStationID: fromID,
            toStationID: toID,
            fromName: stationName(fromID),
            toName: stationName(toID),
            direction: edge.direction,
            points: ordered.map { Coordinates(lat: $0.latitude, lng: $0.longitude) },
            existingPolyline: edge.polylineCoordinates,
            recomputedDistanceKm: distanceKm,
            existingDistanceKm: edge.distanceKm
        )
        stagedSegments.append(staged)
    }

    /// Directional lines (MRT-3) match from/to/direction exactly. Bidirectional lines
    /// (LRT-1/LRT-2) have a single physical edge per station pair — if the ride crossed
    /// it in the opposite direction from how it's stored, reverse the points so the
    /// uploaded polyline still starts at `edge.from` and ends at `edge.to`, matching the
    /// schema invariant.
    private func matchEdge(
        from: StationID, to: StationID, points: [CLLocationCoordinate2D]
    ) -> (TransitEdge, [CLLocationCoordinate2D])? {
        if let exact = candidateEdges.first(where: { $0.from == from && $0.to == to && $0.direction == currentDirection }) {
            return (exact, points)
        }
        if let bidirReversed = candidateEdges.first(where: {
            $0.direction == nil && $0.bidirectional && $0.from == to && $0.to == from
        }) {
            return (bidirReversed, points.reversed())
        }
        return nil
    }

    private func stationName(_ id: StationID) -> String { stationIndex[id]?.name ?? id }

    private func log(warning: String) {
        warningMessage = warning
        skippedSegmentLog.append(warning)
    }

    private func haversineSumKm(_ points: [CLLocationCoordinate2D]) -> Double {
        guard points.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            total += haversine(lat1: a.latitude, lng1: a.longitude, lat2: b.latitude, lng2: b.longitude)
        }
        return total
    }

    private func haversine(lat1: Double, lng1: Double, lat2: Double, lng2: Double) -> Double {
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLng = (lng2 - lng1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLng / 2) * sin(dLng / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    // MARK: Review

    func toggleAccept(_ id: String) {
        guard let idx = stagedSegments.firstIndex(where: { $0.id == id }) else { return }
        stagedSegments[idx].isAccepted.toggle()
    }

    func saveAccepted() async {
        isSaving = true
        saveError = nil
        var failed: [String] = []
        for segment in stagedSegments where segment.isAccepted {
            do {
                _ = try await AdminService.shared.updateEdge(id: segment.edgeID, polylineCoordinates: segment.points)
            } catch let error as APIError {
                failed.append("\(segment.fromName) → \(segment.toName) (\(error.userMessage))")
            } catch {
                failed.append("\(segment.fromName) → \(segment.toName)")
            }
        }
        let acceptedCount = stagedSegments.filter(\.isAccepted).count
        savedCount = acceptedCount - failed.count
        if !failed.isEmpty {
            saveError = "Failed to update: " + failed.joined(separator: "; ")
        }
        // Pull the corrected polylines into the local cache immediately, matching the
        // pattern used after CreateLoopViewModel.generateAndSave() — otherwise the fix
        // wouldn't show up until the next periodic graph-version poll.
        await GraphService.shared.forceSync()
        isSaving = false
        phase = .output
    }
}

extension PolylineRecorderViewModel: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Same stale-fix rejection as RecordCommuteViewModel — a cached, distant first
        // fix would otherwise corrupt the very edge this feature exists to correct.
        guard let loc = locations.last,
              loc.horizontalAccuracy > 0, loc.horizontalAccuracy < 50,
              abs(loc.timestamp.timeIntervalSinceNow) < 5 else { return }
        Task { @MainActor [weak self] in self?.handle(loc) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.authStatus = status
            self?.applyBackgroundConfiguration()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor [weak self] in self?.locationError = msg }
    }
}

// MARK: - Root View

struct PolylineRecorderView: View {
    @State private var vm = PolylineRecorderViewModel()
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch vm.phase {
                case .linePicker: PolylineLinePickerView(vm: vm)
                case .recording:  PolylineRecordingMapView(vm: vm)
                case .review:     PolylineReviewListView(vm: vm)
                case .output:     PolylineSaveOutputView(vm: vm, onDone: onDone)
                }
            }
            .navigationTitle(phaseTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if vm.phase == .linePicker {
                        Button("Close", action: onDone)
                    }
                }
            }
        }
        .task {
            if vm.authStatus == .notDetermined { vm.requestPermission() }
            await vm.loadAvailableLines()
        }
    }

    private var phaseTitle: String {
        switch vm.phase {
        case .linePicker: return "Update Track Polylines"
        case .recording:  return vm.selectedLine ?? "Recording"
        case .review:     return "Review Segments"
        case .output:     return "Saved"
        }
    }
}

// MARK: - Line Picker Phase

private struct PolylineLinePickerView: View {
    @Bindable var vm: PolylineRecorderViewModel

    var body: some View {
        Group {
            if vm.isLoadingGraph {
                ProgressView("Loading transit graph…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.loadError {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else if vm.availableLines.isEmpty {
                ContentUnavailableView("No train lines found in the graph.", systemImage: "tram")
            } else {
                List {
                    Section {
                        Text("Ride an MRT/LRT train with this open. As you pass each station "
                             + "you'll be asked which direction you're headed, then the app "
                             + "keeps recording until the next station. After the ride, you "
                             + "review and accept segments before anything is uploaded.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Section("Pick a line") {
                        ForEach(vm.availableLines, id: \.self) { line in
                            Button {
                                vm.selectLine(line)
                                vm.startRecording()
                            } label: {
                                HStack {
                                    Image(systemName: "tram.fill").foregroundStyle(.blue)
                                    Text(line)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                            }
                            .foregroundStyle(.primary)
                            .disabled(vm.authStatus == .denied || vm.authStatus == .restricted)
                        }
                    }
                    if vm.authStatus == .denied || vm.authStatus == .restricted {
                        Section {
                            Text("Location access is required. Enable \"Always\" in Settings → Privacy → Location so recording keeps working while the app is backgrounded.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Recording Phase

private struct PolylineRecordingMapView: View {
    @Bindable var vm: PolylineRecorderViewModel
    @State private var mapPosition: MapCameraPosition = .userLocation(
        fallback: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 14.5763, longitude: 121.0194),
            span: MKCoordinateSpan(latitudeDelta: 0.18, longitudeDelta: 0.18)
        ))
    )
    @State private var showDebug = false

    private var currentSegmentPoints: [CLLocationCoordinate2D] {
        vm.rawWaypoints
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $mapPosition) {
                UserAnnotation()
                if currentSegmentPoints.count >= 2 {
                    MapPolyline(coordinates: currentSegmentPoints)
                        .stroke(.blue.opacity(0.75), lineWidth: 4)
                }
            }
            .ignoresSafeArea()

            controlPanel
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .destructive, action: vm.cancelRecording)
            }
        }
        .alert(
            "You're at \(vm.pendingDirectionStation?.name ?? "")",
            isPresented: Binding(
                get: { vm.pendingDirectionStation != nil },
                set: { if !$0 { vm.pendingDirectionStation = nil } }
            )
        ) {
            ForEach(directionsForPrompt, id: \.self) { direction in
                Button(direction.capitalized) { vm.setDirection(direction) }
            }
        } message: {
            Text("Which direction is this train headed?")
        }
    }

    private var directionsForPrompt: [String] { vm.availableDirections }

    private var controlPanel: some View {
        VStack(spacing: 10) {
            if let err = vm.locationError {
                pill {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            if let warning = vm.warningMessage {
                pill {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(warning).font(.caption).foregroundStyle(.orange)
                    Button {
                        vm.warningMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }

            pill {
                Circle().fill(.red).frame(width: 9, height: 9)
                Text(vm.currentStationName.map { "At \($0)" } ?? "Riding…")
                    .font(.subheadline.bold())
                Text("· \(vm.stagedSegments.count) segment\(vm.stagedSegments.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !vm.availableDirections.isEmpty {
                Menu {
                    ForEach(vm.availableDirections, id: \.self) { direction in
                        Button(direction.capitalized) { vm.setDirection(direction) }
                    }
                } label: {
                    pill {
                        Image(systemName: "arrow.up.arrow.down.circle")
                        Text("Direction: \(vm.currentDirection?.capitalized ?? "Not set")")
                            .font(.caption.bold())
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                }
                .buttonStyle(.plain)
            }

            DisclosureGroup("Debug", isExpanded: $showDebug) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(vm.nearestStationDebug ?? "Nearest station: —")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("Threshold").font(.caption2).foregroundStyle(.secondary)
                        Slider(value: $vm.proximityThresholdMeters, in: 30...150, step: 5)
                        Text("\(Int(vm.proximityThresholdMeters)) m").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            Button {
                vm.finishRide()
            } label: {
                Label("Finish Ride", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 32)
    }

    @ViewBuilder
    private func pill(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }
}

// MARK: - Review Phase

private struct PolylineReviewListView: View {
    @Bindable var vm: PolylineRecorderViewModel

    var body: some View {
        List {
            if !vm.skippedSegmentLog.isEmpty {
                Section("Skipped during recording") {
                    ForEach(vm.skippedSegmentLog, id: \.self) { msg in
                        Text(msg).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Segments") {
                ForEach(vm.stagedSegments) { segment in
                    SegmentReviewRow(segment: segment) { vm.toggleAccept(segment.id) }
                }
            }
            if let error = vm.saveError {
                Section { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            let acceptedCount = vm.stagedSegments.filter(\.isAccepted).count
            Button {
                Task { await vm.saveAccepted() }
            } label: {
                if vm.isSaving {
                    HStack { ProgressView().tint(.white); Text("Saving…") }
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Save \(acceptedCount) Accepted Segment\(acceptedCount == 1 ? "" : "s")")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(acceptedCount == 0 || vm.isSaving)
            .padding(16)
            .background(.regularMaterial)
        }
    }
}

private struct SegmentReviewRow: View {
    let segment: StagedPolylineSegment
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("\(segment.fromName) → \(segment.toName)")
                            .font(.subheadline.bold())
                        if let dir = segment.direction {
                            Text(dir.capitalized)
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.blue.opacity(0.12))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }
                    }
                    Text("\(segment.points.count) points")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onToggle) {
                    Image(systemName: segment.isAccepted ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(segment.isAccepted ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }

            SegmentPreviewMapView(existing: segment.existingPolyline, recorded: segment.points)
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 4) {
                Image(systemName: segment.distanceLooksOff ? "exclamationmark.triangle.fill" : "checkmark.seal")
                    .foregroundStyle(segment.distanceLooksOff ? .orange : .secondary)
                Text(String(format: "%.2f km recorded (was %.2f km)",
                            segment.recomputedDistanceKm, segment.existingDistanceKm))
                    .font(.caption)
                    .foregroundStyle(segment.distanceLooksOff ? .orange : .secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(segment.isAccepted ? 1 : 0.5)
    }
}

/// Static, non-interactive overlay of the existing (red, dashed) vs freshly recorded
/// (blue, solid) polyline for a single edge — the "old vs new" sanity check from the plan.
private struct SegmentPreviewMapView: View {
    let existing: [Coordinates]
    let recorded: [Coordinates]

    var body: some View {
        Map(initialPosition: .region(region), interactionModes: []) {
            if existing.count >= 2 {
                MapPolyline(coordinates: existing.map(\.coordinate2D))
                    .stroke(.red.opacity(0.7), style: StrokeStyle(lineWidth: 3, dash: [6, 4]))
            }
            if recorded.count >= 2 {
                MapPolyline(coordinates: recorded.map(\.coordinate2D))
                    .stroke(.blue, lineWidth: 3)
            }
        }
        .allowsHitTesting(false)
    }

    private var region: MKCoordinateRegion {
        let all = (existing + recorded).map(\.coordinate2D)
        guard !all.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 14.5763, longitude: 121.0194),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        }
        let lats = all.map(\.latitude), lngs = all.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLng = lngs.min()!, maxLng = lngs.max()!
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.8, 0.004),
            longitudeDelta: max((maxLng - minLng) * 1.8, 0.004)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}

private extension Coordinates {
    var coordinate2D: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
}

// MARK: - Output Phase

private struct PolylineSaveOutputView: View {
    let vm: PolylineRecorderViewModel
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: vm.saveError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 72))
                .foregroundStyle(vm.saveError == nil ? .green : .orange)
            VStack(spacing: 8) {
                Text(vm.saveError == nil ? "Polylines Updated!" : "Partially Saved")
                    .font(.title2.bold())
                Text("\(vm.savedCount) segment\(vm.savedCount == 1 ? "" : "s") updated on \(vm.selectedLine ?? "the graph")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let error = vm.saveError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            Spacer()
            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 40).padding(.bottom, 40)
        }
    }
}
