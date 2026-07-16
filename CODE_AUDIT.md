# CommuteBeh — Complete Code & Data Audit

**Date:** 2026-07-16
**Scope:** iOS app (`oscrallnium/commutebeh`, all Swift sources + `transit_graph_v3.json`), project docs (`CLAUDE.md`, `.claude/skills/*.md`, `CLAUDE-backend.md`, `CLAUDE-web.md`), and backend integration surface (`commute-backend`, as targeted by `APIEndpoint.swift`).
**How findings were verified:** every data claim was checked programmatically against `transit_graph_v3.json` (haversine distances, connectivity/reachability sweeps, polyline endpoint checks). The A* suboptimality claim was verified by re-implementing the exact Swift algorithm (same cost function, same closed-set behavior, same heuristic) and comparing against Dijkstra over all 3,540 station pairs.

---

## How to use this document (instructions for the implementing model)

- Findings have stable IDs (`CB-01` …). Work in the phase order given in [Implementation Plan](#implementation-plan) unless told otherwise.
- Each finding lists: **Severity · Component · Location · Defect · Failure scenario · Fix · Acceptance criteria.**
- `file:line` references are against the repo state at commit `72ae7af` ("Add networking layer and project documentation"). Line numbers may drift as you edit — anchor on the quoted symbols, not raw line numbers.
- **Key invariants to preserve** (from `CLAUDE.md`, all confirmed still valid):
  - Never hardcode station names, fares, coordinates, mode strings, or payment strings in Swift — all come from `transit_graph_v3.json`.
  - `alwaysAllowedModes` is derived from `isAlwaysAllowed: true` in JSON; never hardcode `"walk"` in A* logic.
  - When stitching `polylineCoordinates` across merged edges, drop the first coordinate of each subsequent segment.
  - Fare is computed once per `RouteLeg` (single boarding), not summed per edge.
  - `"line": "INTERCHANGE"` prevents leg consolidation and skips fare/operating-hours checks.
  - Every edge's `polylineCoordinates` must start at the `from` station's coordinates and end at the `to` station's coordinates.
- **Testing note:** there is no `CommuteBehTests` target yet (`.claude/skills/swift-testing.md` describes how to create one). Several acceptance criteria below assume you create it. The graph-data checks in [Appendix A](#appendix-a--graph-validation-script) can run without Xcode.

---

## Part 1 — The reported polyline bug (last-mile rendering)

### CB-01 · Route has no origin/destination "last mile" — missing feature, not a rendering defect
- **Severity:** High (headline user-reported issue) · **Component:** iOS — engine + ContentView
- **Location:** `CommuteBeh/TransportMode.swift:183-204` (`RouteRequest`), `CommuteBeh/ContentView.swift:24-90` (map content), `ContentView.swift:198-238` (origin/destination input)
- **Defect:** The rendered polyline runs first-station → last-station because the app has **no concept of a true origin/destination coordinate anywhere**:
  - `RouteRequest` takes `originID`/`destinationID` — station IDs only. No lat/lng fields exist.
  - The From/To fields are station-name autocomplete only. There is no GPS in the Commute tab (`CLLocationManager` exists only in `RecordCommuteView`), no map-tap origin, no address search.
  - The origin pin is drawn at `result.legs.first.fromStation` (`ContentView.swift:36-47`), the destination pin at `result.legs.last.toStation` (`ContentView.swift:49-59`).
- **What is NOT broken (do not "fix"):** the mid-section stitching is correct and verified:
  - Bidirectional edges get a synthetic reverse edge with `polylineCoordinates.reversed()` at graph build (`TransportMode.swift:408-428`), so edges traversed backwards render in the right direction.
  - Leg consolidation drops the duplicated junction point of each subsequent step (`TransportMode.swift:807-814`).
  - All 76 edges' polyline first/last coordinates match their from/to stations within 30 m (verified against the JSON).
- **ETA has the same gap (part of this finding):** `totalTimeMinutes` / `totalDistanceKm` (`TransportMode.swift:749-751`) cover only the station-to-station path. Access/egress walking time and distance are excluded, so displayed trip time understates reality by the full first/last-mile walk.
- **Fix (feature implementation):**
  1. Add `originCoordinate: Coordinates?` and `destinationCoordinate: Coordinates?` to `RouteRequest` (nil = origin/destination is exactly a station, preserving current behavior).
  2. UI input: add "Use my location" (requires `NSLocationWhenInUseUsageDescription` + a `CLLocationManager` in the Commute flow — reuse patterns from `RecordCommuteView`), and long-press-on-map to set origin/destination. Searched stations keep working as today.
  3. Entry/exit station selection: do **not** naively snap to the single nearest station. Preferred approach: introduce two virtual A* nodes (`__ORIGIN__`, `__DEST__`) with synthetic walk edges to the K nearest stations (K≈3–5, within a walkable radius, e.g. ≤1.5 km), cost = haversine × detour factor (≈1.3) ÷ walk speed (≈4.5 km/h → 75 m/min). Let A* pick the globally best entry/exit. The synthetic edges must use the JSON-derived always-allowed walk mode id, not a hardcoded `"walk"` string (look it up via `alwaysAllowedModes` / `transportModes`).
  4. Result assembly: synthesize a leading and trailing walk `RouteLeg` (`line: "ACCESS_WALK"` or reuse `"INTERCHANGE"` semantics — pick one and keep `consolidateLegs` from merging it) whose `polylineCoordinates` are `[origin, firstStation]` / `[lastStation, destination]`. Include their time/distance in `totalTimeMinutes` / `totalDistanceKm`.
  5. Rendering: in `ContentView`, draw these legs as dashed gray polylines (mode config already carries `mapLineDash` in `TransportModeConfig` — use it), move the origin/destination pins to the true coordinates, and include the new coordinates in `fitMap(to:)`'s bounding box.
- **Acceptance criteria:**
  - Route from an arbitrary tapped point to an arbitrary tapped point renders: dashed walk segment → transit polylines → dashed walk segment, with pins at the tapped points.
  - `totalTimeMinutes` increases by the walk time of both segments; a route between two exact station coordinates is unchanged vs today.
  - No regression in the station→station flow (existing behavior when both inputs are stations).

---

## Part 2 — Transit graph data corruption (`CommuteBeh/transit_graph_v3.json`)

> These are the most user-visible bugs in the app today. Routes and the rendered map are wrong **right now** because of the data, independent of any Swift changes. The backend serves the same graph (`GET /api/v1/graph`), so fix the canonical copy and propagate to both repos.

### CB-02 · ~10 LRT-1 stations are mislocated (up to ~4 km off) — map and heuristic corrupted
- **Severity:** Critical · **Component:** Data
- **Defect:** Stations from Libertad northward drift progressively east off the real Taft Ave corridor; the drift is internally provable: `E_LRT1_UNAVENUE_CENTRAL` stores `distanceKm: 1.58` but its endpoints are **4.87 km apart straight-line** — physically impossible (track distance ≥ straight-line distance). Same class of violation on `E_LRT1_5THAVE_MONUMENTO` (stored 1.53 vs 2.79 straight), `E_LRT1_DOROTEO_QUIAPO` (0.15 vs 0.83), `E_MRT_NORTH_SMNORTH` (0.25 vs 0.56), and others — full list in Appendix A output.
- **Affected stations (JSON coords → approximate real coords; VERIFY against an authoritative source before committing):**

  | Station id | JSON (wrong) | Approx. real |
  |---|---|---|
  | `LRT1_LIBERTAD` | 14.5437, 121.0028 | 14.5477, 120.9982 |
  | `LRT1_GIL_PUYAT` | 14.5504, 121.0079 | 14.5542, 120.9971 |
  | `LRT1_VITO_CRUZ` | 14.5567, 121.0122 | 14.5636, 120.9945 |
  | `LRT1_QUIRINO` | 14.5628, 121.0156 | 14.5702, 120.9917 |
  | `LRT1_PEDRO_GIL` | 14.5681, 121.0194 | 14.5765, 120.9880 |
  | `LRT1_UN_AVE` | 14.5741, 121.0231 | 14.5826, 120.9847 |
  | `LRT1_BAMBANG` | 14.6100, 120.9889 | 14.6111, 120.9820 |
  | `LRT1_TAYUMAN` | 14.6161, 120.9922 | 14.6167, 120.9827 |
  | `LRT1_BLUMENTRITT` | 14.6222, 120.9956 | 14.6226, 120.9830 |
  | `LRT1_ABAD_SANTOS` | 14.6283, 120.9989 | 14.6306, 120.9814 |
  | `LRT1_R_PAPA` | 14.6344, 121.0022 | 14.6360, 120.9824 |
  | `LRT1_5TH_AVE` | 14.6406, 121.0056 | 14.6444, 120.9835 |

  (Baclaran, EDSA, Central, Carriedo, Doroteo Jose, Monumento, Balintawak, Roosevelt look correct.)
- **Fix:** correct `stations[].coordinates`, then **regenerate `polylineCoordinates` of every edge touching a moved station** (the invariant "polyline starts/ends at station coords" currently holds against the *wrong* coords, so polylines must move with the stations). Recompute each affected edge's `distanceKm` (path length along the polyline) and sanity-check `travelTimeMinutes`.
- **Acceptance criteria:** the Appendix A validator reports zero edges where straight-line distance exceeds `distanceKm` by >15%; LRT-1 renders as a contiguous line along Taft Ave in ExploreView.

### CB-03 · Teleport edge `E_LRT1_EDSA_EDSABUS` — 3.2 km "5-minute free walk" that routes exploit
- **Severity:** Critical · **Component:** Data
- **Defect:** INTERCHANGE walk edge from `LRT1_EDSA` (EDSA/Taft) to `STOP_EDSA_AYALA` (EDSA-Ayala) with `travelTimeMinutes: 5`, `distanceKm: 0.1` — but the endpoints are **3.17 km apart**. Verified exploited: shortest path Baclaran → BGC High Street comes out at 24.2 effective minutes via `E_LRT1_BACLARAN_EDSA → E_LRT1_EDSA_EDSABUS → E_EJEEPNEY_BGC_AYALA(rev)`, i.e. the router thinks you can walk from Taft to Ayala in 5 minutes for free.
- **Fix:** either delete this edge, or repoint it to a genuinely adjacent stop (an EDSA-Taft carousel stop — which does not exist in the dataset yet), or convert it into a proper `bus`-mode edge on `EDSA_BUS` with realistic time/fare. Do not leave it as a walk interchange.
- **Acceptance criteria:** no INTERCHANGE/walk edge in the graph spans more than ~800 m straight-line (validator check); Baclaran→BGC route uses the bus/jeepney network with a plausible total time.

### CB-04 · `STOP_BGC_MARKET_MARKET` is orphaned (zero edges)
- **Severity:** High · **Component:** Data
- **Defect:** The station exists in `stations[]` but no edge references it. Any route to/from it returns "No route found". It also shows as an isolated dot in ExploreView.
- **Fix:** add the missing `EJEEPNEY_BGC` (or appropriate) edges connecting it to `STOP_BGC_HIGH_STREET`, or remove the station.
- **Acceptance criteria:** validator reports zero degree-0 stations.

### CB-05 · `E_BUS_COMMONWEALTH_CUBAO` is one-way — Tandang Sora is unreachable from everywhere
- **Severity:** High · **Component:** Data
- **Defect:** The only edge touching `STOP_COMMONWEALTH_TANDANG_SORA` is `STOP_COMMONWEALTH_TANDANG_SORA → MRT_ARANETA_CUBAO` with `bidirectional: false`. Directed reachability sweep confirms all 59 other stations cannot reach it (it can only be an origin, never a destination).
- **Fix:** set `bidirectional: true` (the bus runs both ways) with an appropriate reverse `direction` label if needed.
- **Acceptance criteria:** validator reports full mutual reachability for all stations except intentionally one-way cases (currently: none).

### CB-06 · Duplicate reverse pair `E_EJEEPNEY_BGC_AYALA` / `E_EJEEPNEY_AYALA_BGC`
- **Severity:** Low · **Component:** Data
- **Defect:** Both explicit directions exist AND both are `bidirectional: true`, so the engine's synthetic-reverse logic creates 4 edges for 2 directions. Harmless for cost (identical weights) but violates transit-data.md's own checklist ("bidirectional edges do NOT also have a manually defined reverse edge") and doubles A* edge expansions there.
- **Fix:** keep one edge with `bidirectional: true`, delete the other.

### CB-07 · Missing interchange edge: `STOP_EDSA_AYALA` ↔ `MRT_AYALA`
- **Severity:** High · **Component:** Data
- **Defect:** `STOP_EDSA_AYALA.interchangesWith` lists `MRT_AYALA`, but no INTERCHANGE edge exists between them — so bus/e-jeepney riders can never transfer to/from MRT-3 at Ayala, one of the busiest transfer points in the network.
- **Fix:** add a bidirectional `mode: "walk"`, `line: "INTERCHANGE"` edge between them (~350 m, ~5 min), per the "Stopover-then-Walk Routing" recipe in `.claude/skills/transit-data.md`. Set `isInterchange`/`interchangesWith` symmetrically on both stations.
- **Acceptance criteria:** validator reports zero `interchangesWith` entries lacking a corresponding INTERCHANGE edge; a route STOP_EDSA_MEGAMALL → MRT_MAGALLANES can transfer at Ayala.

---

## Part 3 — A* engine correctness (`CommuteBeh/TransportMode.swift`)

### CB-08 · Heuristic is inadmissible → provably suboptimal routes
- **Severity:** High · **Component:** iOS — engine
- **Location:** `TransportMode.swift:654-658` (`heuristic`), comment at `650-652`
- **Defect:** The heuristic assumes 30 km/h and claims it "never overestimates". False: 20 edges cross their endpoints' straight-line distance faster than 30 km/h. This is not only the bad-coordinates problem — e.g. `E_MRT_SANTOLAN_ORTIGAS_*` covers its **stored** 3.06 km in 5 min = 36.7 km/h. Because the implementation uses a closed set with no re-expansion (`TransportMode.swift:569-570`), an inadmissible heuristic yields suboptimal results.
- **Failure scenario (measured, exact replication of the Swift algorithm vs Dijkstra over all 3,540 pairs):** 18 pairs return suboptimal routes. Worst: `MRT_ORTIGAS → LRT1_CENTRAL` returns 44.8 effective min vs true optimum 39.7 (+5.1 min, a different path). Others include `MRT_NORTH_AVE → LRT1_UN_AVE` (54.1 vs 50.4) and `STOP_EDSA_MEGAMALL → LRT1_CENTRAL` (50.0 vs 44.9).
- **Fix (pick one):**
  1. **Simplest and recommended at this scale (60 stations):** drop the heuristic (h = 0 → Dijkstra). Remove the misleading comment.
  2. Keep A*: compute the max observed straight-line speed across edges at engine init (`maxSpeed = max(haversine(from,to) / travelTimeMinutes)`) and use that as the heuristic divisor. Recompute if the graph reloads. Note the cost function adds only positive penalties to `rawMinutes`, so straight-line-distance ÷ maxSpeed is admissible.
- **Acceptance criteria:** a test replicating the Dijkstra comparison (can be a Swift Testing parameterized test over all pairs) shows zero suboptimal pairs.

### CB-09 · Operating hours: opening time is never checked; no midnight wrap; origin never validated
- **Severity:** High · **Component:** iOS — engine
- **Location:** `TransportMode.swift:528-536` (`stationOpen`), `:621-630` (edge-expansion check), `:544-547` (departure minutes)
- **Defect:**
  1. `stationOpen` only tests `arrivalMinutes < close`. A 03:00 departure routes happily through stations that open at 04:30/05:00 (dataset hours range 04:30–06:00 open, 21:30–23:00 close).
  2. `arrivalMinutes = departureMinutes + Int(tentativeG)` never wraps at 1440, so trips crossing midnight compare nonsense values.
  3. The origin station's own operating hours are never checked (only neighbors during expansion), and neither is the destination as a boarding constraint.
- **Failure scenario:** request a route at 03:30 between two MRT-3 stations → the app returns a normal train route although the whole line is closed.
- **Fix:** in `stationOpen`, also require `arrivalMinutes >= open` (keep the existing overnight `close < open` escape); wrap `arrivalMinutes % 1440` before comparing; in `findRoute`, validate the origin station is open at `departureTime` for non-walk boarding and surface a distinct error ("Station closed at this time") instead of the generic "No route found".
- **Acceptance criteria:** unit tests: (a) 03:00 train request returns nil/closed error; (b) 12:00 request unchanged; (c) 23:50 departure arriving 00:20 at a 23:00-close station is pruned.

### CB-10 · Displayed times are penalty-inflated (ranking cost leaks into user-facing ETA)
- **Severity:** Medium · **Component:** iOS — engine
- **Location:** `TransportMode.swift:615-617` (penalties), `:732-734` (per-step time & `estimatedArrival` from gScore), `:749` (`totalTimeMinutes`)
- **Defect:** Reliability/crowd penalties (up to +30% minutes) are correct as A* *ranking* costs but flow unmodified into `effectiveTravelMinutes`, `totalTimeMinutes`, and `estimatedArrival` — so the UI shows phantom minutes and a wrong wall-clock arrival.
- **Fix:** track two accumulators: `effectiveCost` (for A* ordering, unchanged) and `scheduledMinutes` (= `rawMinutes × peakMultiplier`, no penalties). Build `RawStep.effectiveTravelMinutes`, `estimatedArrival`, and all `RouteResult` totals from `scheduledMinutes`. Keep penalties out of anything user-visible.
- **Acceptance criteria:** for a single edge with `reliability: 0.5, crowdFactor: 1.0`, displayed leg minutes == `travelTimeMinutes × peakMultiplier` exactly.

### CB-11 · Peak multiplier evaluated at departure time for every edge
- **Severity:** Low · **Component:** iOS — engine
- **Location:** `TransportMode.swift:608` (`peakMultiplier(for:at: request.departureTime)`)
- **Defect:** A 06:45 departure into the 07:00–09:00 peak pays no multiplier on any edge of a 60-minute trip; conversely a 08:55 departure pays peak on edges traversed at 09:40.
- **Fix:** compute each edge's entry time as `departureTime + gScore[currentID] minutes` and evaluate the multiplier at that time. (Note: this makes edge cost time-dependent, which is fine for Dijkstra/A* since costs remain positive.)
- **Acceptance criteria:** unit test with a synthetic 2-edge graph straddling a peak boundary shows the second edge picking up the multiplier.

### CB-12 · `computeLegFare` uses the first edge's fare rate for the whole leg
- **Severity:** Low · **Component:** iOS — engine
- **Location:** `TransportMode.swift:872-888`
- **Defect:** `hasPerKm` checks whether **any** merged edge has `farePerKm > 0` but then multiplies total distance by `first.edge.farePerKm` — if the first edge's rate is 0 the per-km component silently vanishes. Safe with today's data (same-line edges share fare structure) but fragile against data edits, which LoopCreator makes user-reachable.
- **Fix:** either assert/log when merged edges disagree on `(baseFare, farePerKm)`, or use `steps.map(\.edge.farePerKm).max() ?? 0`. Keep the single-boarding invariant (one `baseFare` per leg).

### CB-13 · Minor engine/VM issues (bundle into one cleanup pass)
- **Severity:** Low · **Component:** iOS
- `TransportMode.swift:290-315` — `AStarNode.parent` / `edgeFromParent` are stored but never used for reconstruction (`cameFrom` is). Delete the fields.
- `TransportMode.swift:975` — `CommuteViewModel` is **not** annotated `@MainActor` (only individual methods are), contradicting `.claude/skills/architecture-mvvm.md`. Annotate the class, remove per-method annotations.
- `TransportMode.swift:1004-1011` and `ExploreView.swift:97-104` — block-based `NotificationCenter.addObserver` tokens are never removed; every re-created VM leaks a live observer that keeps firing. Store the token and remove in `deinit`, or switch to `NotificationCenter.default.notifications(named:)` in a cancellable task.
- `TransportMode.swift:1053-1055` and `CLAUDE.md` — `Task.detached { await engine.findRoute(...) }` is cargo cult: the A* body executes on the engine actor's executor regardless of the caller's task. Plain `await engine.findRoute(request)` is equivalent. Fix the code, `CLAUDE.md`, and `architecture-mvvm.md` together (they all repeat the misconception).
- `TransportMode.swift:1013-1025` — `GraphLoader.load()` performs synchronous file IO + JSON decode on the main actor at launch. Move to a background task; matters as the graph grows.
- `TransportMode.swift:468-477` — `allStations()` re-sorts on every call; `stations(matching:)` calls it per keystroke. Cache the sorted array at init.
- `CommuteViewModel.searchQuery` / `filteredStations` / `searchStations(query:)` are dead — `ContentView` filters `vm.allStations` locally (`ContentView.swift:198-222`). Delete one of the two implementations.
- `ContentView.swift:575-579` — `DateFormatter` allocated per render of every leg row. Make it a `static let`.
- `findRoute` with `originID == destinationID` returns an empty-legs `RouteResult` (`TransportMode.swift:454-457`), which renders a "Route Found — 0 min" card with no polyline. Treat as a validation error in the VM instead.

---

## Part 4 — Networking layer & backend integration

### CB-14 · The entire networking layer is dead code — graph versioning and analytics are NOT implemented
- **Severity:** High · **Component:** iOS + backend contract
- **Location:** `APIClient.swift`, `APIEndpoint.swift`, `APIModels.swift`, `APIConfig.swift`, `APIError.swift`, `GraphService.swift`, `RouteService.swift`, `AnalyticsService.swift`, `IncidentService.swift`, `AuthService.swift`, `Keychain.swift` — **zero call sites outside the layer itself** (verified by grep).
- **Defect / consequences:**
  1. **Graph versioning:** `GraphService.currentVersion()` (`GET /api/v1/graph/version`) and `fetchGraph()` (`GET /api/v1/graph`) exist but are never called. The app ships the bundled `transit_graph_v3.json` forever (or a Documents copy written by LoopCreator). It neither refetches on version change nor ever contacts the backend. The review question "does the client check the version endpoint correctly?" — answer: **the check does not exist.**
  2. **Analytics:** `POST /api/v1/analytics/route_plan` is never sent, so the backend's stated purpose (logging completed route plans) is unmet.
- **Fix (iOS):**
  - On app launch (and/or foreground), call `GraphService.currentVersion()`; compare against a persisted `(version, updatedAt)`; on change, `fetchGraph()`, validate it decodes as `TransitGraph`, write atomically to a **separate** cache file (do NOT overwrite the LoopCreator's Documents file — see CB-19 interaction), then post `TransitDataDidUpdate`. On network failure, fall back silently to the current copy (stale-but-working beats broken).
  - Decide the precedence explicitly: server graph vs user-authored Documents graph. Recommended: keep user-created lines in a separate overlay file and merge at load, so a server refresh can't clobber user data and vice versa. Document the decision in `CLAUDE.md`.
  - In `CommuteViewModel.calculateRoute()`, after a successful result call `AnalyticsService.logRoutePlan(origin:destination:lineIds:durationSecs:)` (fire-and-forget). `lineIds` = the distinct non-INTERCHANGE `leg.line` values; `durationSecs` = `Int(totalTimeMinutes * 60)`.
- **Fix (backend):** confirm response shapes match the iOS decoder, which uses `.convertFromSnakeCase` and an `APIResponse<T>` wrapper — i.e. `GET /api/v1/graph/version` must return `{"data": {"version": "...", "updated_at": "..."}}`, and `GET /api/v1/graph` must return the raw graph JSON in the exact `TransitGraph` schema (note `GraphService.fetchGraph()` bypasses `APIClient` and returns raw `Data` with **no auth header and no snake_case conversion** — either the endpoint must serve the camelCase iOS schema verbatim, or `fetchGraph` must be rewritten to use `APIClient`). The analytics endpoint must accept the body shape in `APIEndpoint.swift:113-115` (`{"event": {"origin_station_id", "destination_station_id", "line_ids", "duration_seconds"}}`).
- **Acceptance criteria:** launching with a bumped server version replaces the routing graph without reinstalling; analytics events appear server-side after each successful route calculation; version endpoint unreachable → app still routes with the cached/bundled graph.

### CB-15 · `APIClient.send` fires a garbage request on encoding failure
- **Severity:** Low · **Component:** iOS — networking
- **Location:** `APIClient.swift:53-62`
- **Defect:** the fire-and-forget path falls back to `URLRequest(url: baseURL)` when `endpoint.urlRequest()` throws — sending a meaningless GET to the API root instead of aborting.
- **Fix:** `guard let urlRequest = try? endpoint.urlRequest() else { return }`.

### CB-16 · Keychain service id doesn't match the bundle id
- **Severity:** Low · **Component:** iOS — networking
- **Location:** `Keychain.swift:5` (`com.commutebeh.app`) vs bundle id `com.banaueinc.commutebeh.CommuteBeh`
- **Fix:** cosmetic; align the service string (note this invalidates any stored token — acceptable, nothing calls it yet).

---

## Part 5 — LoopCreator / Record / Explore tabs

### CB-17 · Saving a loop with a duplicate `lineID` permanently bricks the app
- **Severity:** Critical · **Component:** iOS — LoopCreator + Explore
- **Location:** `LoopCreatorView.swift:353-357` (`writeToGraph`), `ExploreView.swift:335` (`buildLayers`)
- **Failure scenario:** save the same route twice (or two routes whose display names normalize to the same auto `lineID`) → the Documents `transit_graph_v3.json` contains duplicate station IDs → `Dictionary(uniqueKeysWithValues:)` traps on every subsequent launch. Because the corrupt file shadows the bundle (GraphLoader prefers Documents, `TransportMode.swift:946-954`), the crash is **persistent until the app is deleted**.
- **Fix:** in `writeToGraph`, reject or replace when the `lineID`/generated station IDs already exist; make `buildLayers` use `Dictionary(_:uniquingKeysWith:)` defensively; write the JSON atomically (`.atomic` write options).
- **Acceptance criteria:** saving the same loop twice either updates in place or shows an error; a hand-corrupted Documents graph (duplicate ids) still launches (defensive dictionary) with an error surfaced.

### CB-18 · Swipe-to-delete can permanently destroy built-in transit lines
- **Severity:** Critical · **Component:** iOS — Explore
- **Location:** `ExploreView.swift:601-607` (swipe action on every layer), `:233-242` (`catch {}` swallows errors), `:244-283` (`removeFromGraph`)
- **Failure scenario:** one accidental swipe deletes MRT-3 from the Documents graph, which permanently shadows the bundle. No confirmation, no undo, write errors silently discarded.
- **Fix:** restrict deletion to user-created lines (lines absent from the bundle copy — load the bundle graph once to compute the built-in line set); add a confirmation dialog; surface write failures via `errorMessage`.

### CB-19 · LoopCreator's road-index slicing corrupts persisted polylines, distances, and fares
- **Severity:** High · **Component:** iOS — LoopCreator
- **Location:** `LoopCreatorView.swift:184-193` (`nearestRoadIndex` — global first-nearest match), `:259-277` (slice building), `:281-286` (haversine distance sum)
- **Failure scenario:** an out-and-back loop (common for jeepneys) traverses the same street twice; a later stop snaps to an *earlier* road index, so `fromRoad > toRoad` and the code builds `tail + head` — a polyline that travels the entire loop the wrong way. `distanceKm`/`travelTimeMinutes` inflate by up to the full loop length, and `farePerKm × distance` corrupts fares in persisted JSON. `fromRoad == toRoad` (two stops on the same snapped point) produces a 1-point polyline that ExploreView silently drops.
- **Fix:** search for the nearest road index **at or after the previous stop's index** (monotonic scan), and handle the equal-index degenerate case (insert both stop coordinates).

### CB-20 · Recorded routes break the polyline↔station invariant and mislabel `isRoadSnapped`
- **Severity:** High · **Component:** iOS — Record
- **Location:** `RecordCommuteView.swift:247-285` (station coords from raw GPS vs polylines from road path), `:279` (non-monotonic index guard), `:310` (`isRoadSnapped: true` written even for straight-line fallback)
- **Fix:** snap station coordinates onto the road polyline (`road[roadIdxForStop[i]]`); use monotonic index search; set `isRoadSnapped` only when the road slice was actually used.

### CB-21 · Background recording silently stops
- **Severity:** High · **Component:** iOS — Record
- **Location:** `RecordCommuteView.swift:33-42` — `allowsBackgroundLocationUpdates` and `pausesLocationUpdatesAutomatically` are never set, although the Info.plist keys exist and `.claude/skills/swiftui-mapkit.md:172` claims they are.
- **Failure scenario:** user locks the phone mid-commute → GPS delivery stops → the trace has a giant gap that RDP bridges with a straight line and MKDirections snaps to an arbitrary road.
- **Fix:** set both properties in init (guard `allowsBackgroundLocationUpdates` behind authorization status); consider `activityType = .otherNavigation`. Also fix `didUpdateLocations` keeping only `locations.last` (`RecordCommuteView.swift:67-71`) — append the whole accuracy-filtered batch in a single `@MainActor` hop.

### CB-22 · Assorted view-layer bugs (medium)
- **Severity:** Medium · **Component:** iOS
- `LoopCreatorView.swift:115-124` + `:625` — rapid taps interleave `addWaypoint` across its `await`; `roadSegments` land in completion order, desynced from `rawWaypoints`; `undoLast` then removes mismatched pairs. Fix: reserve the segment slot synchronously before awaiting (`roadSegments.append([])`, fill by index), or guard re-entrancy before the first suspension.
- `ExploreView.swift:108-142` — `load()` never cancels the previous fire-and-forget `snapToRoads` task; re-entrant loads (every `TransitDataDidUpdate`) mix stale snapped polylines into the new state and `fetchProgress` can exceed `fetchTotal`. Fix: store the task, cancel at top of `load()`, check `Task.isCancelled` before applying.
- `ExploreView.swift:132-142, 164-179` — unbounded MKDirections fan-out: one concurrent request per coordinate pair across the whole network → Apple throttling (`MKError.loadingThrottled`) swallowed by `try?` at `:208` → silent straight-line fallbacks. Fix: window the task group to ≤4–8 in flight and RDP-simplify coordinates before snapping (the skill doc's own invariant, currently violated).
- `RecordCommuteView.swift:51-55` + `:402-407` — swipe-dismissing the completion sheet strands the tab in `.processing` with no buttons. Fix: reset state in `.sheet(isPresented:onDismiss:)` or `.interactiveDismissDisabled()`.
- `LoopCreatorView.swift:520-536` — `drawRoadPolyline`/`drawSimplified` unconditionally append `coords.first`, closing the loop even for linear recorded routes (`isLoopClosed` is received but never read) and duplicating the seam point for real loops. Fix: append only when `isLoopClosed && coords.last != coords.first`.
- `LoopCreatorView.swift:488-489` — `updateUIView` removes and re-adds all overlays/annotations on every SwiftUI invalidation, including every keystroke in stop-name fields. Fix: diff, or gate on data change.
- Low: duplicate default stop names after unmark/remark (`LoopCreatorView.swift:162`, `RecordCommuteView.swift:205`); `lineID` auto-sync heuristic only survives single-character appends (`LoopCreatorView.swift:166-171`); `transportModes` line registration silently no-ops when the mode entry is missing (`LoopCreatorView.swift:361-370`); nothing ever reads `recorded_routes.json` back — recorded routes are write-only today.

---

## Part 6 — Documentation corrections (`CLAUDE.md`, `.claude/skills/*.md`, `CLAUDE-backend.md`)

Apply these edits verbatim-ish; they are all confirmed-stale claims.

### CB-23 · `CLAUDE.md`
1. **"Active data"** section claims `transit_graph_v2.json` "is loaded only by ExploreView" — **false**: `ExploreView.swift:115` loads `transit_graph_v3`; v2 is referenced nowhere in Swift (dead 55-station file still shipped in the bundle). Either delete v2 from the target or fix the sentence.
2. **Critical File Layout** omits `RecordCommuteView.swift` (Record tab), `LoopCreatorView.swift`, and the nine networking files. "Everything else is UI: ContentView, ExploreView" is false. Rewrite the layout section listing all current files and their roles (note the networking layer's wired/unwired status per CB-14).
3. Document the **Documents-override behavior**: `GraphLoader` prefers `Documents/transit_graph_v3.json` (written by LoopCreator/Explore-delete) over the bundle. This is load-bearing for CB-17/CB-18 and currently undocumented.
4. **Transit Lines table**: jeepney line keys are wrong. Actual keys: `JEEPNEY_QUIAPO_CUBAO`, `JEEPNEY_MAKATI`, `JEEPNEY_CARTIMAR_LRT`, `EJEEPNEY_BGC`. Remove `JEEPNEY_QUIAPO`, `JEEPNEY_NORTH`.
5. Remove/replace the `Task.detached` claim ("so it doesn't block the actor's executor queue") per CB-13.
6. Note the app tab set is now Commute / Explore / Record (`CommuteBehApp.swift:14-21`).

### CB-24 · `.claude/skills/transit-data.md`
1. Top-level `version` example says `"3.0"`; the file's actual value is `"1.0.0"`.
2. **Naming conventions section does not match the data**: real station IDs use `MRT_`/`LRT1_`/`LRT2_`/`STOP_`/`JEEP_` prefixes (e.g. `MRT_NORTH_AVE`, not `MRT3_NORTH_AVE`); real edge IDs are `E_<LINE>_<FROM>_<TO>[_NB|_SB]` (e.g. `E_MRT_AYALA_MAGALLANES_SB`), not `{FROM_ID}_TO_{TO_ID}`. Rewrite the section from the actual data.
3. Edge schema omits `isRoadSnapped` (optional Bool) and `direction`'s interaction with synthetic reverse edges (engine flips northbound/southbound, `TransportMode.swift:401-407`). Add both.
4. Document the Documents-override + `TransitDataDidUpdate` reload mechanism.
5. Add: "Run the validation script (Appendix A of CODE_AUDIT.md / `scripts/validate_graph.py`) after every edit" — and commit that script (CB-27).

### CB-25 · `.claude/skills/swift-testing.md` and `architecture-mvvm.md`
1. swift-testing.md's example station IDs (`MRT3_NORTH_AVE`, `MRT3_AYALA`, `LRT2_SANTOLAN`) **do not exist** in the data — tests copied from the doc would assert against nil routes. Replace with real IDs (`MRT_NORTH_AVE`, `MRT_AYALA`, `LRT2_RECTO`, `LRT1_BACLARAN`, `LRT1_ROOSEVELT`).
2. architecture-mvvm.md: `CommuteViewModel` example shows `@MainActor` on the class — make the code match (CB-13) rather than weakening the doc; remove the `Task.detached` justification (same fix as CB-23.5).
3. swiftui-mapkit.md: the background-location claims (line ~172) describe properties the code never sets — after CB-21 lands the doc becomes true; land them together. Same for the "RDP before snapping" invariant vs `ExploreViewModel` (CB-22).

### CB-26 · `CLAUDE-backend.md` describes a different backend than the one the app calls
- **Severity:** High (doc) · The file describes **"commutebeh-api"** — a Hono/TypeScript service with `POST /routes`, `GET /modes`, `GET /payments`, file-based storage. The shipped iOS code (`APIConfig.swift`, `APIEndpoint.swift`) targets **`https://commute-backend-a6lj.onrender.com`** with a Rails-style `/api/v1/...` surface (auth register/sign_in/refresh, me, graph + graph/version, stations, routes, saved_routes, incidents, analytics/route_plan). One of these is obsolete. Rewrite `CLAUDE-backend.md` (or replace it) to document the real `commute-backend` contract — endpoint list, `{"data": ...}` envelope, snake_case, bearer auth — so the backend repo and this doc agree with `APIEndpoint.swift`. Same check for `CLAUDE-web.md` (it targets the Hono API too).

---

## Part 7 — General quality / refactors (non-blocking)

### CB-27 · Add a graph validation script + CI check
Commit Appendix A as `scripts/validate_graph.py` and run it in CI / as a pre-commit step. Every data bug in Part 2 (impossible distances, orphan stations, one-way traps, duplicate reverses, missing interchange edges, polyline endpoint drift) is mechanically detectable.

### CB-28 · Split `TransportMode.swift`
1,094 lines containing the entire domain layer under a misleading name (CLAUDE.md itself apologizes for it). Split into `Models.swift` (Codable types), `TransitGraphEngine.swift` (actor + MinHeap + haversine), `GraphLoader.swift`, `CommuteViewModel.swift`. Update `CLAUDE.md`'s layout section in the same change.

### CB-29 · Consolidate `modeColor(_:)`
Duplicated in `ContentView`, `RouteResultCard`, `RouteLegRow`, `ExploreViewModel`. `TransportModeConfig.colorHex` already exists in the JSON — the right end state is `extension TransportMode`/config-driven color sourced from the graph (respects the "no hardcoded strings/colors" invariant), falling back to the current switch. CLAUDE.md already tracks this; do it before adding call sites.

### CB-30 · Error handling hygiene
Empty `catch {}` / `try?` swallowing in write paths (`ExploreView.swift:241`, `LoopCreatorView` write path, `APIClient.send`). Surface user-visible failures via each VM's `errorMessage`.

### CB-31 · Create the test target
`CommuteBehTests` does not exist. Create it per `.claude/skills/swift-testing.md` (after CB-25 fixes its station IDs). Priority tests, in order: CB-08 optimality sweep, CB-09 operating hours, CB-10 displayed-time purity, leg consolidation + polyline junction dedup, `computeLegFare`, graph decode of both bundle and a synthetic Documents override.

---

## Implementation Plan

**Phase 0 — stop the bleeding (data only, no Swift):**
CB-02, CB-03, CB-04, CB-05, CB-06, CB-07 in `transit_graph_v3.json` (both iOS bundle and the backend's served copy), validated with CB-27's script.

**Phase 1 — user-safety critical Swift:**
CB-17 (bricking save), CB-18 (destructive delete), CB-21 (background GPS).

**Phase 2 — engine correctness:**
CB-08, CB-09, CB-10, CB-12 (+ CB-11 if cheap), with CB-31 tests alongside.

**Phase 3 — the reported feature:**
CB-01 (last-mile origin/destination), including ETA integration.

**Phase 4 — backend integration:**
CB-14 (version check + graph refresh + analytics), CB-15, backend contract verification, CB-26 doc rewrite.

**Phase 5 — view-layer correctness & docs:**
CB-19, CB-20, CB-22, CB-23, CB-24, CB-25.

**Phase 6 — refactors:**
CB-13, CB-28, CB-29, CB-30.

---

## Appendix A — Graph validation script

Run with `python3 scripts/validate_graph.py CommuteBeh/transit_graph_v3.json`. All checks must pass after Phase 0.

```python
#!/usr/bin/env python3
"""Validate transit graph invariants. Exit code 1 on any violation."""
import json, math, sys
from collections import defaultdict

path = sys.argv[1] if len(sys.argv) > 1 else "CommuteBeh/transit_graph_v3.json"
g = json.load(open(path))
stations = {s["id"]: s for s in g["stations"]}
edges = g["edges"]
errors = []

def hav(a, b):
    R = 6371.0
    dlat = math.radians(b["lat"] - a["lat"]); dlng = math.radians(b["lng"] - a["lng"])
    x = (math.sin(dlat/2)**2 + math.cos(math.radians(a["lat"]))
         * math.cos(math.radians(b["lat"])) * math.sin(dlng/2)**2)
    return R * 2 * math.atan2(math.sqrt(x), math.sqrt(1 - x))

seen_edge_ids, seen_station_ids = set(), set()
for s in g["stations"]:
    if s["id"] in seen_station_ids: errors.append(f"duplicate station id {s['id']}")
    seen_station_ids.add(s["id"])

deg = defaultdict(int)
pair_bidir = {}
for e in edges:
    if e["id"] in seen_edge_ids: errors.append(f"duplicate edge id {e['id']}")
    seen_edge_ids.add(e["id"])
    for endpoint in (e["from"], e["to"]):
        if endpoint not in stations: errors.append(f"{e['id']}: unknown station {endpoint}")
    if e["mode"] not in g["transportModes"]: errors.append(f"{e['id']}: unknown mode {e['mode']}")
    f, t = stations.get(e["from"]), stations.get(e["to"])
    if not f or not t: continue
    deg[e["from"]] += 1; deg[e["to"]] += 1
    straight = hav(f["coordinates"], t["coordinates"])
    # 1. Physically impossible: straight-line distance exceeds stored track distance
    if straight > e["distanceKm"] * 1.15 and straight - e["distanceKm"] > 0.15:
        errors.append(f"{e['id']}: straight {straight:.2f} km > stored {e['distanceKm']:.2f} km "
                      "(mislocated station or wrong distanceKm)")
    # 2. Teleport walks: interchange edges must be short
    if e["line"] == "INTERCHANGE" and straight > 0.8:
        errors.append(f"{e['id']}: INTERCHANGE walk spans {straight*1000:.0f} m")
    # 3. Polyline endpoints must match stations (within 30 m)
    pc = e.get("polylineCoordinates") or []
    if len(pc) < 2:
        errors.append(f"{e['id']}: polylineCoordinates has {len(pc)} points")
    else:
        if hav(pc[0], f["coordinates"]) * 1000 > 30:
            errors.append(f"{e['id']}: polyline start != from-station coords")
        if hav(pc[-1], t["coordinates"]) * 1000 > 30:
            errors.append(f"{e['id']}: polyline end != to-station coords")
    # 4. Duplicate reverse pairs where either side is bidirectional
    key, rkey = (e["from"], e["to"], e["line"]), (e["to"], e["from"], e["line"])
    if rkey in pair_bidir and (e["bidirectional"] or pair_bidir[rkey]):
        errors.append(f"{e['id']}: explicit reverse of an edge that is also bidirectional")
    pair_bidir[key] = e["bidirectional"]
    # 5. Payments must be known
    for p in e["acceptedPayments"]:
        if p not in g["paymentMethods"]: errors.append(f"{e['id']}: unknown payment {p}")

# 6. Orphan stations
for sid in stations:
    if deg[sid] == 0: errors.append(f"{sid}: no edges reference this station (orphan)")

# 7. Directed reachability: every station must reach every other
adj = defaultdict(list)
for e in edges:
    adj[e["from"]].append(e["to"])
    if e["bidirectional"]: adj[e["to"]].append(e["from"])
def reach(o):
    seen, st = {o}, [o]
    while st:
        c = st.pop()
        for n in adj[c]:
            if n not in seen: seen.add(n); st.append(n)
    return seen
connected = {sid for sid in stations if deg[sid] > 0}
for o in connected:
    missing = connected - reach(o)
    if missing:
        errors.append(f"{o}: cannot reach {sorted(missing)[:5]}{'…' if len(missing) > 5 else ''}")

# 8. interchangesWith must have a matching INTERCHANGE edge
iedges = set()
for e in edges:
    if e["line"] == "INTERCHANGE":
        iedges.add((e["from"], e["to"]))
        if e["bidirectional"]: iedges.add((e["to"], e["from"]))
for s in g["stations"]:
    for other in (s.get("interchangesWith") or []):
        if (s["id"], other) not in iedges:
            errors.append(f"{s['id']}: interchangesWith {other} but no INTERCHANGE edge")

# 9. Heuristic admissibility guard (informational until CB-08 lands, hard error after)
worst = max((hav(stations[e["from"]]["coordinates"], stations[e["to"]]["coordinates"])
              / (e["travelTimeMinutes"] / 60.0), e["id"])
            for e in edges if e["travelTimeMinutes"] > 0)
print(f"max straight-line speed: {worst[0]:.1f} km/h ({worst[1]}) — "
      "A* heuristic divisor must be >= this")

if errors:
    print(f"\n{len(errors)} violation(s):")
    for msg in errors: print("  -", msg)
    sys.exit(1)
print("graph OK")
```

## Appendix B — Reference measurements (pre-fix baseline)

- Graph: 60 stations, 76 edges (44 bidirectional), version string `"1.0.0"`.
- 20 edges exceed 30 km/h straight-line speed (max: `E_LRT1_UNAVENUE_CENTRAL` at 97.4 km/h — coordinate bug; max with plausible coords: `E_MRT_SANTOLAN_ORTIGAS_*` at 36.7 km/h on stored distance).
- Swift-equivalent A* vs Dijkstra over 3,540 ordered pairs: **18 suboptimal**, worst `MRT_ORTIGAS → LRT1_CENTRAL` 44.8 vs 39.7 effective min. 176 unreachable pairs (118 from the `STOP_BGC_MARKET_MARKET` orphan, 58 from the one-way `STOP_COMMONWEALTH_TANDANG_SORA` trap + the missing Ayala interchange).
- Distinct operating hours in data: 04:30–21:30, 05:00–22:00, 05:00–23:00, 05:30–22:00, 06:00–22:00 (no overnight service — the `close < open` branch in `stationOpen` is currently dead code, keep it anyway).
- All 76 edges currently satisfy the polyline-endpoint invariant (within 30 m) — against the *wrong* station coordinates, so CB-02's fix must move polylines together with stations.
