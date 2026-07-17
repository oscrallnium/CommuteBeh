# Feature Spec: Real Walking Paths + Interactive Route Segment Highlighting

**Status:** Planned — not yet implemented. This document is the implementation brief.
**Implementer:** Claude Sonnet. Read this file fully before writing code. All file:line references were verified against the codebase on 7/16/26.

---

## Reference Scenario (use this to verify every phase)

Origin: **Gil Puyat (LRT-1)** → Destination: **Araneta Center-Cubao**.

The computed route includes a walk transfer from **LRT-1 Libertad** to the MRT line. Today that walk renders as a **straight line** cutting across city blocks. Both requirements below must be verified against this exact route.

---

## Requirement 1 — Walk legs must follow real pedestrian paths

### Current behavior (the bug)

Walk legs get straight-line geometry in two places:

1. **Access/egress walks** — `buildAccessEdges` in `CommuteBeh/Domain/TransportMode.swift:585-628` creates synthetic `ACCESS_WALK` edges whose `polylineCoordinates` is literally two points: `[coord, item.station.coordinates]` (line 606-608).
2. **Interchange walks** — edges with `"line": "INTERCHANGE"` come from `transit_graph_v3.json`; their `polylineCoordinates` are typically just the two station endpoints (e.g. Libertad → MRT transfer).

`ContentView.swift:37-50` renders each leg's `polylineCoordinates` verbatim, so both walk types draw as straight segments.

### Required behavior

Every walk leg (`leg.mode == .walk`, covering both `ACCESS_WALK` and `INTERCHANGE` lines) must render the **actual pedestrian route** obtained from MapKit walking directions (`MKDirections` with `transportType: .walking`). Note `TransitEdge` already carries `mkDirectionsTransportType: "walking"` for access edges (`TransportMode.swift:622`) — use that as the signal, not a hardcoded mode check, consistent with the CLAUDE.md invariant against hardcoding `"walk"`.

### Implementation plan

1. **New file** `CommuteBeh/Services/WalkingDirectionsService.swift`:
   - An `actor` (or `final class` with async methods) wrapping `MKDirections`.
   - `func walkingPath(from: Coordinates, to: Coordinates) async -> [Coordinates]?` — returns the polyline of `MKRoute.polyline` converted to `[Coordinates]`, or `nil` on failure/timeout.
   - **In-memory cache** keyed by the coordinate pair (round lat/lng to 5 decimals for the key) so repeated searches over the same transfer don't re-hit MapKit.
   - Apple rate-limits MKDirections. Serialize requests (the actor does this naturally) and cap at the handful of walk legs per route.

2. **Enrichment step, not an A\* change.** After `CommuteViewModel` (`TransportMode.swift:1243`) receives a `RouteResult`, run an async enrichment pass:
   - For each leg where the leg is a walk (access or interchange), request the walking path.
   - **Progressive enhancement:** display the route immediately with the existing straight lines, then swap in resolved geometry as each request completes. Do not block route display on MKDirections.
   - On failure, keep the straight line (current behavior is the fallback).

3. **Model note:** `RouteLeg` is a struct with `let id = UUID()` (`TransportMode.swift:280-284`) — the id is transient (see CLAUDE.md invariant). If you rebuild legs to swap geometry, **preserve the original `id`** or the map/list identity breaks mid-animation. Recommended: change `id` to an injected constant on copy, or hold resolved walk geometry in a side dictionary on the view model keyed by leg id, and have the map view prefer it: `vm.resolvedWalkPath[leg.id] ?? leg.polylineCoordinates`. The side-dictionary approach avoids touching the immutable model at all — prefer it.

4. **ETA (optional, small):** `MKRoute.expectedTravelTime` is more accurate than the haversine × 1.3 detour estimate in `buildAccessEdges` (line 592-603). If the resolved walking time differs by > 2 min, update the displayed leg minutes and `RouteResult.totalTimeMinutes`. Keep the A* cost function untouched — this is display-only refinement.

5. **`fitMap` (`ContentView.swift:363-383`)** must use the resolved geometry when fitting, otherwise the camera may clip the real walking path.

---

## Requirement 2 — Tap-to-highlight route segments

### Required behavior

1. **Select a segment** by either:
   - Tapping its polyline on the map (e.g. the LRT-1 line between Gil Puyat and Libertad), or
   - Tapping that leg's cell (`RouteLegRow`) in the expanded route card.
2. On selection, the map **animates/zooms** to that segment's bounding region and shows a **detail panel** for that leg (instruction, time, fare, stops — the data already rendered by `RouteLegRow`, `ContentView.swift:669-776`).
3. All **other** legs' polylines drop to reduced opacity (e.g. `0.25`) so the selected segment stands out. Animate the opacity change.
4. **Prev/next arrows** on the detail panel step the selection to the previous/next leg (e.g. from "Walk to Libertad" forward to "Board MRT-3 …"). Each step animates both the camera (zoom to the new leg) and the highlight/opacity transition. Disable the back arrow on the first leg and the forward arrow on the last leg.
5. **Dismiss** by tapping the map background or a dismiss (✕) button on the detail panel. The map animates back to the **exact camera position it had before the first selection** (not just refit-to-route), opacities restore, and the detail panel goes away.

### Implementation plan

#### State (in `ContentView` or `CommuteViewModel`)

Selection is view-state; keep it in `ContentView`:

```swift
@State private var selectedLegID: UUID? = nil
@State private var savedCameraPosition: MapCameraPosition? = nil
```

- On first selection (nil → some): store the current `mapPosition` into `savedCameraPosition` **before** animating to the leg.
- Stepping between legs does **not** overwrite `savedCameraPosition` — it was captured once at entry.
- On dismiss: animate `mapPosition = savedCameraPosition`, then clear both.
- When a new route is computed (`vm.routeResult` changes), reset selection state.

#### Polyline rendering (`ContentView.swift:37-50`)

```swift
let isDimmed = selectedLegID != nil && leg.id != selectedLegID
// apply .opacity(isDimmed ? 0.25 : 1.0) to the stroke color,
// wrapped in withAnimation / .animation on selectedLegID
```

Optionally increase the selected leg's `lineWidth` slightly (+1.5pt) for emphasis. Colors and widths stay sourced from `leg.mode.color` / `leg.mode.lineWidth` (DesignTokens extension) — do not hardcode.

#### Tap hit-testing on polylines

SwiftUI `MapPolyline` has no tap handler. Use the existing `MapReader` (`ContentView.swift:33`) + a `SpatialTapGesture` (or `.onTapGesture` with location) on the `Map`:

1. Convert the tap point to a coordinate via `proxy.convert(point, from: .local)`.
2. For each leg, compute the minimum distance from the tap to the leg's polyline. Do this **in screen points**, not meters, so the touch target is zoom-independent: project each polyline vertex with `proxy.convert(coordinate, to: .local)` and run point-to-segment distance over consecutive vertex pairs.
3. Select the nearest leg within a **~22pt threshold**. If several legs are within threshold (overlapping at a transfer station), prefer the one whose nearest segment midpoint is closest.
4. If no leg is within threshold → this is a background tap → dismiss selection (Requirement 2.5). If nothing is selected, keep the existing long-press pin behavior (`ContentView.swift:117-120`) untouched; make sure the new tap gesture does not swallow it.

Put the geometry helpers (point-to-segment distance, nearest-leg search) in a small extension or helper struct — do not inline 60 lines into the gesture closure.

#### Camera zoom to a leg

Generalize `fitMap(to result:)` (`ContentView.swift:363-383`) — extract the bounding-region math into `fitRegion(for coords: [CLLocationCoordinate2D], paddingFactor: Double) -> MKCoordinateRegion` and reuse it for both the full route and a single leg. For a single leg use a slightly larger padding factor (~1.8) so short legs (interchange walks) don't zoom in absurdly close; keep the existing `0.02` minimum span. Use the **resolved** walk geometry (Requirement 1) when present. Animate with `withAnimation(.easeInOut(duration: 0.5))`, matching the existing fitMap animation.

#### Leg detail panel

New view `SelectedLegPanel` (can live in `ContentView.swift` next to `RouteLegRow`, or its own file):

- Shown via `safeAreaInset(edge: .bottom)` **replacing** `RouteResultCard` while a selection is active (swap with a `.transition(.move(edge: .bottom).combined(with: .opacity))`, same idiom as `ContentView.swift:96-102`).
- Content: mode icon + instruction (reuse the visual language of `RouteLegRow`), time / fare / arrival meta row, and the expandable stops list if `leg.stopCount > 1`.
- Chrome: `✕` dismiss button (top-right), `chevron.left` / `chevron.right` buttons to step prev/next. Stepping updates `selectedLegID` inside `withAnimation`, which drives the camera + opacity animations.
- Leg ordering for prev/next comes from `result.legs` (index of current id ± 1).

#### Cell tap in the route card

In `RouteResultCard`'s expanded list (`ContentView.swift:463-477`), wrap each `RouteLegRow` in a tap target that calls the same selection entry point as the map tap. `RouteResultCard` currently takes only `result:` (`ContentView.swift:446-448`) — add an `onSelectLeg: (RouteLeg) -> Void` closure parameter. Take care not to conflict with `RouteLegRow`'s internal "N stops" disclosure button (`ContentView.swift:716-733`); the row's tap surface should exclude that button (buttons already win over `onTapGesture` on the container, so a container-level tap gesture is fine).

#### Single entry point

One function owns the transition so map-tap, cell-tap, and arrows can't diverge:

```swift
private func select(leg: RouteLeg) {
    if selectedLegID == nil { savedCameraPosition = mapPosition }
    withAnimation(.easeInOut(duration: 0.5)) {
        selectedLegID = leg.id
        mapPosition = .region(fitRegion(for: coords(of: leg), paddingFactor: 1.8))
    }
}

private func dismissSelection() {
    withAnimation(.easeInOut(duration: 0.5)) {
        if let saved = savedCameraPosition { mapPosition = saved }
        selectedLegID = nil
    }
    savedCameraPosition = nil
}
```

---

## Project conventions (must follow — from CLAUDE.md)

- Every **new** `.swift` file starts with the Gora header (app name **Gora**, author **Oscar Allen Brioso**, creation date in `M/D/YY`, no leading zeros).
- ViewModels: `@Observable final class` + `@MainActor`; never `@StateObject`/`ObservableObject`.
- Never hardcode station names, mode strings, or line keys — `"walk"` must not appear as a literal in logic (use `isAlwaysAllowed` / `mkDirectionsTransportType`). `"ACCESS_WALK"` and `"INTERCHANGE"` already appear as literals in existing code; if you touch those sites, prefer lifting them into named constants.
- Animations: use `DesignTokens.Motion` constants where one fits; otherwise match the existing `.easeInOut(duration: 0.5)` map idiom.
- Build to verify: `xcodebuild -project CommuteBeh.xcodeproj -scheme CommuteBeh -destination 'platform=iOS Simulator,name=iPhone 16' build`

---

## Suggested implementation order

1. **Phase 1:** `WalkingDirectionsService` + view-model side dictionary + map view reads resolved geometry. Verify: Gil Puyat → Araneta Center-Cubao shows the Libertad→MRT walk following streets, not a straight line.
2. **Phase 2:** Selection state, opacity dimming, camera zoom, `SelectedLegPanel` with dismiss. Verify: tapping the LRT-1 Gil Puyat→Libertad polyline zooms to it, dims everything else; ✕ or background tap animates back to the pre-selection camera.
3. **Phase 3:** Cell tap in `RouteResultCard` + prev/next arrows. Verify: arrows step Walk → Board MRT-3 → … with animated camera and highlight each step; arrows disable at the ends.

## Acceptance checklist

- [ ] Walk legs (access **and** interchange) render real pedestrian paths; straight line only as fallback when MKDirections fails.
- [ ] Route appears instantly; walk geometry swaps in without flicker or list identity churn.
- [ ] Tap polyline → zoom + highlight + detail panel; other legs at reduced opacity (animated).
- [ ] Tap leg cell → identical behavior to polyline tap.
- [ ] Prev/next arrows step selection with camera + highlight animation; disabled at first/last leg.
- [ ] Map background tap or ✕ → animated restore to the exact pre-selection camera; opacities and `RouteResultCard` restore.
- [ ] Long-press pin-drop behavior still works when nothing is selected.
- [ ] New route search resets any active selection.
- [ ] Project builds with no warnings introduced; new files carry the Gora header.
