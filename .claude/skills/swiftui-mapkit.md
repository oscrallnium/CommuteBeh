# SwiftUI + MapKit Patterns

Conventions used in CommuteBeh for maps, overlays, and layout.

## Map Setup

Always use `Map(position:)` with a `@State MapCameraPosition`. Never use the deprecated `Map(coordinateRegion:)`.

```swift
@State private var mapPosition: MapCameraPosition = .region(MKCoordinateRegion(
    center: CLLocationCoordinate2D(latitude: 14.5763, longitude: 121.0194),
    span: MKCoordinateSpan(latitudeDelta: 0.18, longitudeDelta: 0.18)
))

var body: some View {
    Map(position: $mapPosition) {
        // MapContent here
    }
    .ignoresSafeArea()
}
```

## Polylines

Use `MapPolyline` inside the `Map` content builder:

```swift
MapPolyline(coordinates: coords)
    .stroke(color, lineWidth: lineWidth)
```

`coords` is `[CLLocationCoordinate2D]`. Convert from `[Coordinates]` model type with:
```swift
leg.polylineCoordinates.map {
    CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
}
```

## Annotations

Use `Annotation` with an explicit anchor. Empty string label hides the callout:

```swift
Annotation("", coordinate: coord, anchor: .center) {
    Circle()
        .fill(.white)
        .frame(width: 10, height: 10)
        .overlay(Circle().stroke(color, lineWidth: 2))
        .shadow(color: .black.opacity(0.2), radius: 1)
}
```

Keep annotation views lightweight — complex SwiftUI inside `Annotation` degrades map performance when there are many stations.

## Overlays (Search Panel, Bottom Cards)

Use `.safeAreaInset(edge:)` to attach UI above or below the map without covering it:

```swift
Map(position: $mapPosition) { ... }
    .ignoresSafeArea()
    .safeAreaInset(edge: .top, spacing: 0) {
        searchPanel.padding()
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
        if let result = vm.routeResult {
            RouteResultCard(result: result).padding()
        }
    }
```

For overlays that float on top (loading spinner, status pills), use `.overlay { }` or `ZStack`.

## Fitting the Map to a Route

After a route is found, animate the camera to show all polyline coordinates:

```swift
private func fitMap(to result: RouteResult) {
    let allCoords = result.legs.flatMap { $0.polylineCoordinates.map {
        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
    }}
    guard !allCoords.isEmpty else { return }
    let lats = allCoords.map(\.latitude)
    let lngs = allCoords.map(\.longitude)
    let center = CLLocationCoordinate2D(
        latitude:  ((lats.min()! + lats.max()!) / 2),
        longitude: ((lngs.min()! + lngs.max()!) / 2)
    )
    let span = MKCoordinateSpan(
        latitudeDelta:  max((lats.max()! - lats.min()!) * 1.6, 0.02),
        longitudeDelta: max((lngs.max()! - lngs.min()!) * 1.6, 0.02)
    )
    withAnimation(.easeInOut(duration: 0.5)) {
        mapPosition = .region(MKCoordinateRegion(center: center, span: span))
    }
}
```

The `1.6` padding factor gives comfortable margin around the route. `0.02` is the minimum span to avoid zooming in too far for short routes.

## Road Snapping — Drawing Polylines Along Roads

Polylines must follow the road network, not draw straight lines between points. Use `MKDirections` with `.automobile` transport type. Every road-snap call must be `nonisolated` (called from a task group) and must extract coordinates directly from `MKPolyline` without going through a `@MainActor`-isolated extension.

### Transport type by mode

| Mode | Transport type | Reason |
|---|---|---|
| `train` | Skip — use JSON coords | Elevated/underground guideways; `MKDirections` would route via surface streets |
| `bus`, `jeepney` | `.automobile` | `.transit` lacks PH bus/jeepney data and can hang indefinitely |
| `tricycle`, `walk` | `.automobile` | Short local roads; automobile reliably follows the barangay street network |

### Per-segment pattern (used in ExploreViewModel and RecordedRouteCreatorViewModel)

Road-snap **each consecutive pair of waypoints** independently via a task group so all segments fly in parallel. Stitch results by dropping the first coord of every segment after the first (shared junction point).

```swift
nonisolated private static func roadSegment(
    from: CLLocationCoordinate2D,
    to: CLLocationCoordinate2D
) async -> [CLLocationCoordinate2D] {
    // Race MKDirections against a 10-second timeout so a hanging request
    // never stalls the whole batch.
    await withTaskGroup(of: [CLLocationCoordinate2D]?.self) { group in
        group.addTask {
            let req = MKDirections.Request()
            req.source      = MKMapItem(placemark: MKPlacemark(coordinate: from))
            req.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
            req.transportType = .automobile
            guard let resp = try? await MKDirections(request: req).calculate(),
                  let route = resp.routes.first else { return nil }
            // IMPORTANT: Do NOT use a @MainActor extension on MKPolyline here.
            // With SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor the compiler will
            // reject it from a nonisolated context. Extract coords inline:
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
        return result ?? [from, to]   // straight-line fallback on timeout/failure
    }
}
```

### Stitching segments into a single polyline

```swift
var stitched: [CLLocationCoordinate2D] = []
for (_, seg) in collected.sorted(by: { $0.idx < $1.idx }) {
    // Drop the first coord of every segment after the first — it duplicates
    // the shared junction point with the previous segment's last coord.
    stitched += stitched.isEmpty ? seg : Array(seg.dropFirst())
}
```

### Key invariants

- **Simplify with RDP before snapping** — `RDPSimplifier.simplify(points, epsilon: 0.0003)` reduces a dense GPS trace (hundreds of points) to ~15–30, keeping shape accurate while cutting request count to a manageable batch.
- **Cache results** keyed by edge/segment ID (`roadPolylines: [String: [CLLocationCoordinate2D]]`) so `ExploreView` re-renders don't re-fetch.
- **Mark pre-snapped edges** with `"isRoadSnapped": true` in the JSON so `ExploreView` skips its own snap pass and doesn't re-route a sparser set of waypoints that may produce a different path.
- **Never use a `@MainActor`-isolated computed property on `MKPolyline`** (e.g. a `var coordinates` extension) from inside a `nonisolated` task group function — the compiler rejects it when `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Always call `getCoordinates(_:range:)` inline.

### Background location + road snapping (RecordCommuteView)

The Record tab collects raw GPS in the background (`CLLocationManager` with `allowsBackgroundLocationUpdates = true`, `pausesLocationUpdatesAutomatically = false`, `distanceFilter = 15 m`, `desiredAccuracy = kCLLocationAccuracyBest`). Road snapping is deferred to completion time to avoid firing `MKDirections` on every GPS update:

1. User taps **Complete** → `stopUpdatingLocation()`
2. RDP-simplify the raw GPS trace (`epsilon: 0.0003` ≈ ~30 m tolerance)
3. Batch-snap all simplified segments in parallel (`withTaskGroup`) with a 10 s per-segment timeout
4. Show `TappableMapView` in `.definingStops` phase — user taps annotation dots to mark named stops
5. Fill route metadata (name, mode, fare, operating hours)
6. Save to `recorded_routes.json` in the app's Documents directory (separate from `transit_graph_v3.json`)

Required Info.plist keys (set via `INFOPLIST_KEY_*` in project.pbxproj):
```
INFOPLIST_KEY_NSLocationWhenInUseUsageDescription
INFOPLIST_KEY_NSLocationAlwaysAndWhenInUseUsageDescription
INFOPLIST_KEY_UIBackgroundModes = location
```

## Material Backgrounds

All floating panels use `.regularMaterial` for an adaptive blur effect that works in both light and dark mode:

```swift
.background(.regularMaterial)
.clipShape(RoundedRectangle(cornerRadius: 16))
.shadow(color: .black.opacity(0.15), radius: 8, y: 4)
```

Use `.ultraThinMaterial` for status pills and loading overlays where you want maximum transparency.

## Performance Notes

- Limit `Annotation` count — iOS MapKit degrades with hundreds of simultaneous annotations. For dense station networks, consider hiding annotations below a zoom threshold or using `MapCircle` instead.
- `MapPolyline` is efficient for moderate counts. If rendering 100+ polylines simultaneously, batch or layer them.
- The `withTaskGroup` pattern in `snapToRoads` fires all `MKDirections` requests in parallel — acceptable for ~20–50 edges but may hit Apple's rate limits for larger graphs.
