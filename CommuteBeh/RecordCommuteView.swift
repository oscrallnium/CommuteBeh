import SwiftUI
import MapKit
import CoreLocation

// MARK: - Recording State

enum RecordingState {
    case idle, recording, processing
}

// MARK: - Recorded Creation Phase

enum RecordedCreationPhase {
    case processing     // road-snapping the raw GPS track
    case definingStops
    case fillingMetadata
    case output
}

// MARK: - RecordCommuteViewModel

@Observable
@MainActor
final class RecordCommuteViewModel: NSObject {
    var state: RecordingState = .idle
    var rawWaypoints: [CLLocationCoordinate2D] = []
    var authStatus: CLAuthorizationStatus = .notDetermined
    var locationError: String?
    var showCompletionSheet = false

    private let locationManager: CLLocationManager

    override init() {
        locationManager = CLLocationManager()
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 15     // record a point every ~15 m
        authStatus = locationManager.authorizationStatus
    }

    func requestPermission() { locationManager.requestAlwaysAuthorization() }

    func startRecording() {
        rawWaypoints = []
        locationError = nil
        state = .recording
        locationManager.startUpdatingLocation()
    }

    func completeRecording() {
        locationManager.stopUpdatingLocation()
        state = .processing
        showCompletionSheet = true
    }

    func cancelRecording() {
        locationManager.stopUpdatingLocation()
        rawWaypoints = []
        state = .idle
    }

    var canComplete: Bool { rawWaypoints.count >= 3 }
}

extension RecordCommuteViewModel: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy < 50 else { return }
        let coord = loc.coordinate
        Task { @MainActor [weak self] in self?.rawWaypoints.append(coord) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in self?.authStatus = status }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor [weak self] in self?.locationError = msg }
    }
}

// MARK: - RecordedRouteCreatorViewModel

@Observable
@MainActor
final class RecordedRouteCreatorViewModel {

    // Processing
    var phase: RecordedCreationPhase = .processing
    var processProgress: Double = 0

    // Track data (populated after processing)
    var roadPolylineCoords: [CLLocationCoordinate2D] = []
    var simplifiedWaypoints: [CLLocationCoordinate2D] = []

    // Stop definition
    var markedStopIndices: Set<Int> = []
    var stopNames: [Int: String] = [:]

    // Metadata
    var routeDisplayName = ""
    var lineID = ""
    var selectedMode: TransportMode = .jeepney
    var baseFare: Double = 13
    var farePerKm: Double = 1.8
    var isAirConditioned = false
    var selectedPayments: Set<String> = ["cash"]
    var openTime = "05:00"
    var closeTime = "22:00"
    var crowdFactor: Double = 0.7
    var reliability: Double = 0.65

    // Output
    var isSaving = false
    var savedRouteID: String?
    var errorMessage: String?

    var canContinueFromStops: Bool { markedStopIndices.count >= 2 }
    var canSave: Bool { !routeDisplayName.isEmpty && !lineID.isEmpty && canContinueFromStops }

    private let rawWaypoints: [CLLocationCoordinate2D]

    init(rawWaypoints: [CLLocationCoordinate2D]) {
        self.rawWaypoints = rawWaypoints
    }

    // MARK: - Processing

    func beginProcessing() async {
        phase = .processing
        processProgress = 0

        let simplified = RDPSimplifier.simplify(rawWaypoints, epsilon: 0.0003)
        simplifiedWaypoints = simplified
        processProgress = 0.1

        guard simplified.count >= 2 else {
            roadPolylineCoords = simplified
            phase = .definingStops
            return
        }

        let segmentCount = simplified.count - 1
        // Road-snap each consecutive pair concurrently
        var collected: [(idx: Int, seg: [CLLocationCoordinate2D])] = []
        await withTaskGroup(of: (Int, [CLLocationCoordinate2D]).self) { group in
            for i in 0..<segmentCount {
                let from = simplified[i], to = simplified[i + 1]
                group.addTask {
                    let seg = await Self.roadSegment(from: from, to: to)
                    return (i, seg)
                }
            }
            for await result in group {
                collected.append((result.0, result.1))
                processProgress = 0.1 + 0.9 * Double(collected.count) / Double(segmentCount)
            }
        }

        var stitched: [CLLocationCoordinate2D] = []
        for (_, seg) in collected.sorted(by: { $0.idx < $1.idx }) {
            stitched += stitched.isEmpty ? seg : Array(seg.dropFirst())
        }
        roadPolylineCoords = stitched.isEmpty ? simplified : stitched
        phase = .definingStops
    }

    nonisolated private static func roadSegment(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) async -> [CLLocationCoordinate2D] {
        await withTaskGroup(of: [CLLocationCoordinate2D]?.self) { group in
            group.addTask {
                let req = MKDirections.Request()
                req.source      = MKMapItem(placemark: MKPlacemark(coordinate: from))
                req.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
                req.transportType = .automobile
                guard let resp = try? await MKDirections(request: req).calculate(),
                      let route = resp.routes.first else { return nil }
                let n = route.polyline.pointCount
                var coords = Array(repeating: CLLocationCoordinate2D(), count: n)
                route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
                return coords
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result ?? [from, to]
        }
    }

    // MARK: - Stops

    func toggleStop(at index: Int) {
        if markedStopIndices.contains(index) {
            markedStopIndices.remove(index)
            stopNames.removeValue(forKey: index)
        } else {
            markedStopIndices.insert(index)
            stopNames[index] = "Stop \(markedStopIndices.count)"
        }
    }

    func updateRouteDisplayName(_ name: String) {
        routeDisplayName = name
        if lineID.isEmpty || autoLineID(String(routeDisplayName.dropLast())) == lineID {
            lineID = autoLineID(name)
        }
    }

    private func autoLineID(_ name: String) -> String {
        name.uppercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private func nearestRoadIndex(for coord: CLLocationCoordinate2D) -> Int {
        let road = roadPolylineCoords
        return road.indices.min(by: {
            let a = road[$0], b = road[$1]
            let da = (a.latitude-coord.latitude)*(a.latitude-coord.latitude)
                   + (a.longitude-coord.longitude)*(a.longitude-coord.longitude)
            let db = (b.latitude-coord.latitude)*(b.latitude-coord.latitude)
                   + (b.longitude-coord.longitude)*(b.longitude-coord.longitude)
            return da < db
        }) ?? 0
    }

    // MARK: - Save

    func generateAndSave() async {
        guard canSave else { errorMessage = "Fill in all required fields and mark at least 2 stops."; return }
        isSaving = true
        errorMessage = nil

        let orderedSI = markedStopIndices.sorted()  // indices into simplifiedWaypoints
        let road = roadPolylineCoords

        // Map each simplified-waypoint stop to its nearest index in the road path
        let roadIdxForStop: [Int] = orderedSI.map { nearestRoadIndex(for: simplifiedWaypoints[$0]) }

        // Build stations
        var stationDicts: [[String: Any]] = []
        for (i, si) in orderedSI.enumerated() {
            let coord = simplifiedWaypoints[si]
            let name = stopNames[si] ?? "Stop \(i + 1)"
            let shortName = name.components(separatedBy: .whitespaces).prefix(2).joined(separator: " ")
            let isTerminal = (i == 0 || i == orderedSI.count - 1)
            let coords: [String: Double] = ["lat": coord.latitude, "lng": coord.longitude]
            let hours: [String: String] = ["open": openTime, "close": closeTime]
            var dict: [String: Any] = [:]
            dict["id"]             = "\(lineID)_STOP\(i + 1)"
            dict["name"]           = name
            dict["shortName"]      = shortName
            dict["line"]           = lineID
            dict["type"]           = selectedMode.rawValue
            dict["coordinates"]    = coords
            dict["isTerminal"]     = isTerminal
            dict["isInterchange"]  = false
            dict["amenities"]      = [String]()
            dict["operatingHours"] = hours
            stationDicts.append(dict)
        }

        // Build edges (open/linear — no wrap-around to first stop)
        var edgeDicts: [[String: Any]] = []
        for i in 0..<(orderedSI.count - 1) {
            let fromRoad = roadIdxForStop[i]
            let toRoad   = roadIdxForStop[i + 1]

            let polySlice: [[String: Double]]
            if fromRoad <= toRoad, toRoad < road.count {
                polySlice = (fromRoad...toRoad).map { ["lat": road[$0].latitude, "lng": road[$0].longitude] }
            } else {
                let a = simplifiedWaypoints[orderedSI[i]]
                let b = simplifiedWaypoints[orderedSI[i + 1]]
                polySlice = [["lat": a.latitude, "lng": a.longitude],
                             ["lat": b.latitude, "lng": b.longitude]]
            }

            var dist = 0.0
            for k in 1..<polySlice.count {
                dist += haversine(lat1: polySlice[k-1]["lat"]!, lng1: polySlice[k-1]["lng"]!,
                                  lat2: polySlice[k]["lat"]!,   lng2: polySlice[k]["lng"]!)
            }
            let travelTime = max(2.0, dist / 0.4)

            edgeDicts.append([
                "id":                       "\(lineID)_SEG\(i + 1)",
                "from":                     "\(lineID)_STOP\(i + 1)",
                "to":                       "\(lineID)_STOP\(i + 2)",
                "mode":                     selectedMode.rawValue,
                "line":                     lineID,
                "travelTimeMinutes":        round(travelTime * 10) / 10,
                "distanceKm":               round(dist * 100) / 100,
                "baseFare":                 baseFare,
                "farePerKm":                farePerKm,
                "acceptedPayments":         Array(selectedPayments),
                "isAirConditioned":         isAirConditioned,
                "crowdFactor":              crowdFactor,
                "reliability":              reliability,
                "bidirectional":            true,
                "isRoadSnapped":            true,
                "polylineCoordinates":      polySlice,
                "mkDirectionsTransportType": "automobile"
            ])
        }

        let routeID = UUID().uuidString
        do {
            try saveToRecordedRoutes(id: routeID, stations: stationDicts, edges: edgeDicts)
            savedRouteID = routeID
            phase = .output
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
        isSaving = false
    }

    private func haversine(lat1: Double, lng1: Double, lat2: Double, lng2: Double) -> Double {
        let R = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLng = (lng2 - lng1) * .pi / 180
        let a = sin(dLat/2)*sin(dLat/2) + cos(lat1 * .pi/180)*cos(lat2 * .pi/180)*sin(dLng/2)*sin(dLng/2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    private func saveToRecordedRoutes(id: String, stations: [[String: Any]], edges: [[String: Any]]) throws {
        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = docsURL.appendingPathComponent("recorded_routes.json")

        var root: [String: Any]
        if FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        } else {
            root = ["version": "1.0", "routes": [[String: Any]]()]
        }

        var routes = root["routes"] as? [[String: Any]] ?? []
        routes.append([
            "id":          id,
            "recordedAt":  ISO8601DateFormatter().string(from: Date()),
            "name":        routeDisplayName,
            "lineID":      lineID,
            "mode":        selectedMode.rawValue,
            "stations":    stations,
            "edges":       edges
        ])
        root["routes"] = routes

        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: fileURL, options: .atomic)
    }
}

// MARK: - RecordCommuteView

struct RecordCommuteView: View {
    @State private var vm = RecordCommuteViewModel()
    @State private var mapPosition: MapCameraPosition = .userLocation(
        fallback: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 14.5763, longitude: 121.0194),
            span: MKCoordinateSpan(latitudeDelta: 0.18, longitudeDelta: 0.18)
        ))
    )

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $mapPosition) {
                UserAnnotation()
                if vm.rawWaypoints.count >= 2 {
                    MapPolyline(coordinates: vm.rawWaypoints)
                        .stroke(.blue.opacity(0.75), lineWidth: 4)
                }
                if let first = vm.rawWaypoints.first {
                    Annotation("", coordinate: first, anchor: .center) {
                        ZStack {
                            Circle().fill(.green).frame(width: 14, height: 14)
                            Circle().stroke(.white, lineWidth: 2).frame(width: 14, height: 14)
                        }
                    }
                }
            }
            .ignoresSafeArea()
            .onChange(of: vm.state) { _, state in
                if state == .recording {
                    mapPosition = .userLocation(fallback: mapPosition)
                }
            }

            controlPanel
        }
        .sheet(isPresented: $vm.showCompletionSheet) {
            RecordedRouteCreatorView(
                rawWaypoints: vm.rawWaypoints,
                onDone: { vm.showCompletionSheet = false; vm.state = .idle }
            )
        }
        .onAppear {
            if vm.authStatus == .notDetermined { vm.requestPermission() }
        }
    }

    // MARK: - Control Panel

    private var controlPanel: some View {
        VStack(spacing: 10) {
            if let err = vm.locationError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial).clipShape(Capsule())
            }

            if vm.state == .recording {
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text("\(vm.rawWaypoints.count) points recorded")
                        .font(.subheadline.bold())
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial).clipShape(Capsule())
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            }

            VStack(spacing: 0) {
                switch vm.state {
                case .idle:
                    idlePanel
                case .recording:
                    recordingPanel
                case .processing:
                    processingPanel
                }
            }
            .padding(16)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: .black.opacity(0.15), radius: 10, y: -4)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 32)
    }

    @ViewBuilder
    private var idlePanel: some View {
        VStack(spacing: 10) {
            if vm.authStatus == .denied || vm.authStatus == .restricted {
                Text("Location access is required. Enable it in Settings → Privacy → Location.")
                    .font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            Button {
                vm.startRecording()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    Text("Record Commute")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.authStatus == .denied || vm.authStatus == .restricted)
        }
    }

    private var recordingPanel: some View {
        HStack(spacing: 12) {
            Button(action: vm.cancelRecording) {
                Label("Cancel", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)

            Button(action: vm.completeRecording) {
                Label("Complete", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!vm.canComplete)
        }
    }

    private var processingPanel: some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.85)
            Text("Preparing route…").font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 4)
    }
}

// MARK: - RecordedRouteCreatorView

struct RecordedRouteCreatorView: View {
    let rawWaypoints: [CLLocationCoordinate2D]
    let onDone: () -> Void

    @State private var vm: RecordedRouteCreatorViewModel
    @Environment(\.dismiss) private var dismiss

    init(rawWaypoints: [CLLocationCoordinate2D], onDone: @escaping () -> Void) {
        self.rawWaypoints = rawWaypoints
        self.onDone = onDone
        _vm = State(initialValue: RecordedRouteCreatorViewModel(rawWaypoints: rawWaypoints))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch vm.phase {
                case .processing:    RecordedProcessingView(vm: vm)
                case .definingStops: RecordedDefiningStopsView(vm: vm)
                case .fillingMetadata: RecordedMetadataView(vm: vm)
                case .output:        RecordedOutputView(vm: vm, onDone: { dismiss(); onDone() })
                }
            }
            .navigationTitle(phaseTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if vm.phase != .output && vm.phase != .processing {
                        Button("Cancel") { dismiss(); onDone() }
                    }
                }
            }
        }
        .task { await vm.beginProcessing() }
    }

    private var phaseTitle: String {
        switch vm.phase {
        case .processing:      return "Snapping to Roads"
        case .definingStops:   return "Mark Stops"
        case .fillingMetadata: return "Route Details"
        case .output:          return "Route Saved"
        }
    }
}

// MARK: - Processing Phase

private struct RecordedProcessingView: View {
    let vm: RecordedRouteCreatorViewModel

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "road.lanes")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
            VStack(spacing: 10) {
                Text("Snapping route to roads")
                    .font(.title3.bold())
                ProgressView(value: vm.processProgress, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(.blue)
                    .frame(width: 220)
                Text("\(Int(vm.processProgress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Each segment is matched to the road network via MapKit.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }
}

// MARK: - Defining Stops Phase

private struct RecordedDefiningStopsView: View {
    @Bindable var vm: RecordedRouteCreatorViewModel

    var body: some View {
        ZStack(alignment: .bottom) {
            // Reuse TappableMapView from LoopCreatorView in definingStops mode
            TappableMapView(
                phase: .definingStops,
                rawWaypoints: [],
                roadPolylineCoords: vm.roadPolylineCoords,
                simplifiedWaypoints: vm.simplifiedWaypoints,
                markedStopIndices: vm.markedStopIndices,
                isLoopClosed: false,
                onAnnotationTap: { idx in vm.toggleStop(at: idx) }
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap")
                    Text("Tap dots on the map to mark named stops")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial).clipShape(Capsule())
                .padding(.bottom, 8)

                if !vm.markedStopIndices.isEmpty {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(vm.markedStopIndices.sorted(), id: \.self) { idx in
                                HStack(spacing: 10) {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundStyle(.orange)
                                    TextField("Stop name", text: Binding(
                                        get: { vm.stopNames[idx] ?? "Stop \(idx + 1)" },
                                        set: { vm.stopNames[idx] = $0 }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.subheadline)
                                }
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                    }
                    .frame(maxHeight: 180)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 16).padding(.bottom, 8)
                    .shadow(color: .black.opacity(0.1), radius: 6, y: -2)
                }

                Button {
                    vm.phase = .fillingMetadata
                } label: {
                    Label("Continue", systemImage: "chevron.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canContinueFromStops)
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            .padding(.bottom, 28)
        }
    }
}

// MARK: - Metadata Phase

private struct RecordedMetadataView: View {
    @Bindable var vm: RecordedRouteCreatorViewModel
    private let paymentOptions = ["cash", "gcash", "maya", "beep_card", "card"]

    var body: some View {
        Form {
            Section("Route Identity") {
                TextField("Display Name", text: Binding(
                    get: { vm.routeDisplayName },
                    set: { vm.updateRouteDisplayName($0) }
                ))
                HStack {
                    Text("Line ID")
                    Spacer()
                    TextField("LINE_ID", text: $vm.lineID)
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Transport") {
                Picker("Mode", selection: $vm.selectedMode) {
                    ForEach([TransportMode.jeepney, .bus, .tricycle, .train], id: \.self) { m in
                        Text(m.rawValue.capitalized).tag(m)
                    }
                }
                Toggle("Air Conditioned", isOn: $vm.isAirConditioned)
            }

            Section("Fare") {
                HStack {
                    Text("Base Fare (₱)")
                    Spacer()
                    TextField("13", value: $vm.baseFare, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("Per km (₱)")
                    Spacer()
                    TextField("1.80", value: $vm.farePerKm, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("Accepted Payments") {
                ForEach(paymentOptions, id: \.self) { p in
                    Toggle(p.replacingOccurrences(of: "_", with: " ").capitalized,
                           isOn: Binding(
                            get: { vm.selectedPayments.contains(p) },
                            set: { on in
                                if on { vm.selectedPayments.insert(p) }
                                else  { vm.selectedPayments.remove(p) }
                            }
                           ))
                }
            }

            Section("Operating Hours") {
                HStack {
                    Text("Opens"); Spacer()
                    TextField("05:00", text: $vm.openTime).multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("Closes"); Spacer()
                    TextField("22:00", text: $vm.closeTime).multilineTextAlignment(.trailing)
                }
            }

            Section("Quality") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Crowd Factor: \(String(format: "%.2f", vm.crowdFactor))").font(.subheadline)
                    Slider(value: $vm.crowdFactor, in: 0...1, step: 0.05)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reliability: \(String(format: "%.2f", vm.reliability))").font(.subheadline)
                    Slider(value: $vm.reliability, in: 0...1, step: 0.05)
                }
            }

            Section {
                Button { vm.phase = .definingStops } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                Button {
                    Task { await vm.generateAndSave() }
                } label: {
                    if vm.isSaving {
                        HStack { ProgressView().scaleEffect(0.8); Text("Saving…") }
                    } else {
                        Label("Save Recorded Route", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .listRowBackground(vm.canSave ? Color.blue : Color.gray)
                .foregroundStyle(.white)
                .disabled(!vm.canSave || vm.isSaving)
            }

            if let err = vm.errorMessage {
                Section { Text(err).foregroundStyle(.red).font(.caption) }
            }
        }
    }
}

// MARK: - Output Phase

private struct RecordedOutputView: View {
    let vm: RecordedRouteCreatorViewModel
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            VStack(spacing: 8) {
                Text("Route Saved!")
                    .font(.title2.bold())
                Text(vm.routeDisplayName)
                    .font(.headline).foregroundStyle(.secondary)
                Text("\(vm.markedStopIndices.count) stops · road-snapped polylines")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Text("Saved to recorded_routes.json in the app's Documents folder.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Spacer()
            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 40).padding(.bottom, 40)
        }
    }
}

#Preview { RecordCommuteView() }
