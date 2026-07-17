# Polyline & Admin Route-Editing Audit

**Date:** 2026-07-03 · **Scope:** route rendering (Commute + Explore tabs) and admin station editing.
**Method:** static trace of the full pipeline plus a numeric simulation of the engine's exact A* + stitching logic against `transit_graph_v3.json` (all 76 edges, two concrete multi-leg routes). No app run / no screenshots — everything below is code- and data-derived. All line numbers refer to the working tree as of this audit.

## Summary

The A* engine and its polyline stitching are **correct** — the "drop the first coordinate of each subsequent segment" rule works exactly as documented, verified numerically (0.00 m endpoint/junction error on traced multi-leg routes). The real problems are: **(1)** the *Explore* tab's runtime MKDirections road-snapping replaces each edge's polyline with a route whose endpoints are snapped to the nearest road, not to the station coordinates, so drawn lines visibly stop short of the station dots; two route-creation flows (RecordCommute, LoopCreator edge cases) write edges that violate the "polyline starts/ends at station coords" schema invariant, which produces the same cut-endpoint symptom for user-created routes. **(2)** "Doesn't follow the road" is a **data problem**: every bundled jeepney/bus/tricycle edge has only 2–9 polyline points with straight chords up to 3.14 km, and the Commute tab (`ContentView`) renders them raw — only the Explore tab snaps to roads at runtime, which is why the two tabs look different. On top of that, 9 LRT-1 stations are plotted 0.5–4 km east of their real positions (a synthetic diagonal), provably inconsistent with the edges' own `distanceKm` values. **(3)** The admin route-editing feature **exists** (`AdminRoutesView`, station lat/lng only) but is broken end-to-end: the server silently ignores the update (param-name mismatch), the client then fails to decode the response and reports "Save failed", the edit is never persisted to the local graph the maps/engine actually render from, the edit map shows no route context at all, and there is zero coordinate validation on either side. Even if all of that were fixed, moving a station does not update the edge polylines that embed its coordinate, so a successful admin edit would *reintroduce* symptom 1.

---

## Issue 1: Polylines cut at start/destination

### Root cause

**The prime suspect is innocent.** The engine-side stitching rule (`TransportMode.swift:808-815`, inside `consolidateLegs` → `flush`) is correct: each subsequent raw step's polyline begins with the shared junction station, and dropping its first coordinate loses nothing. The bundled data upholds the schema invariant perfectly — across **all 76 edges** the maximum offset between `polylineCoordinates[0]/[-1]` and the from/to station coordinates is **0.00 m**. `ContentView` renders `leg.polylineCoordinates` verbatim (`ContentView.swift:28-34`) with pins at `fromStation`/`toStation` coords (`ContentView.swift:36-59`), so with bundled data the Commute tab's polylines mathematically touch both endpoints.

The cut-endpoint symptom has three actual mechanisms:

**1a. Explore tab: runtime road-snapping detaches lines from station dots (main, affects every non-train line).**
`ExploreViewModel.load()` schedules an MKDirections `.automobile` snap for every non-train edge (`ExploreView.swift:132-142`). `roadPolyline(from:to:)` returns `MKRoute.polyline` coordinates **verbatim** (`ExploreView.swift:195-224`). MKDirections routes between the nearest *road-network* points, so when a station coordinate is off the drivable network (jeepney terminals inside compounds, e.g. `JEEP_CARTIMAR_TERM` "Cartimar Terminal", stops inside mall grounds like `STOP_BGC_MARKET_MARKET`), the snapped polyline starts/ends meters-to-tens-of-meters away from the station coordinate. `visiblePolylines` then **prefers** the snapped coords over the JSON coords (`ExploreView.swift:296-306`) while station dots are still drawn at the JSON station coordinates → visible gap at both ends of the line. The stitcher at `ExploreView.swift:181-192` never re-attaches the original endpoints. Its failure-fallback branch (lines 186-189) also appends `seg.to` directly after a snapped segment's road-snapped end, producing a chord discontinuity mid-edge when only some segments snap successfully.

**1b. RecordCommuteView writes edges that violate the endpoint invariant.**
Station coordinates are taken from RDP-simplified **raw GPS points** (`RecordCommuteView.swift:135-136`, used at `:252-256`), but edge `polylineCoordinates` are sliced from the **MKDirections-snapped** path (`roadPolylineCoords`, built at `:162-166`; slice at `:274-286` via `nearestRoadIndex`, `:224-234`). A GPS fix recorded off-road (accuracy gate is 50 m, `:68`) has no exact match in the snapped path — `nearestRoadIndex` picks the closest road vertex, so `polylineCoordinates[0] != station.coordinates`. Any renderer of these edges shows the pin floating off the line's end — exactly symptom 1. (Mitigating fact: the output goes to `recorded_routes.json` (`:335-362`), which **no code reads back** — grep confirms zero consumers — so today this is latent, but it's a live trap for the planned import.)

**1c. LoopCreatorView wrap-around slice can produce a wrong-way polyline.**
Stations are picked from `simplifiedWaypoints` which *is* an exact subset of the road path (RDP keeps original points), so normal LoopCreator edges keep the invariant. But the slice logic at `LoopCreatorView.swift:261-277` treats **any** `fromRoad > toRoad` as a wrap-around and slices `tail + head` through the loop's seam. For a non-closing segment where `nearestRoadIndex` matches a later duplicate/near-duplicate point (loops pass near the same road point twice), the edge gets a polyline that circles the entire loop the wrong way. These edges *are* written into the Documents `transit_graph_v3.json` (`writeToGraph`, `:336-382`), which `GraphLoader` prefers over the bundle (`TransportMode.swift:947-964`) — so a bad slice corrupts routing display persistently until the Documents copy is deleted.

**Duplication check (the four `modeColor` sites):** only two of the four actually render map polylines — `ContentView` (Commute map) and `ExploreViewModel`/`ExploreView` (Explore map). `RouteResultCard` (`ContentView.swift:373-480`) and `RouteLegRow` (`ContentView.swift:486-599`) use `modeColor` for chips/list rows only; they cannot exhibit either symptom. The two map renderers have **different** bugs: ContentView = raw sparse chords (Issue 2), ExploreView = snapped-but-detached endpoints (this issue). The `modeColor` duplication itself is only trivially inconsistent (walk gray is `.opacity(0.6)` at `ContentView.swift:300` vs full opacity at `:467`/`:596`) — cosmetic, not a cause.

### Evidence

Simulated the engine's exact logic (adjacency incl. synthetic reversed edges with `polylineCoordinates.reversed()` per `TransportMode.swift:424`, off-peak cost formula, `consolidateLegs` merge + dropFirst stitching) on route **`JEEP_PARANAQUE_WEST` → `MRT_ARANETA_CUBAO`** (10 raw steps → 3 legs, jeepney → interchange walk → train):

| Leg | Line | Merged edges | Stitched pts | start offset | end offset |
|---|---|---|---|---|---|
| 1 jeepney | `JEEPNEY_CARTIMAR_LRT` | `E_JEEP_PARANAQUE_TO_CARTIMAR` + `E_JEEP_CARTIMAR_TO_LEVERIZA` + `E_JEEP_LEVERIZA_TO_TAFT` | 14 | **0.00 m** | **0.00 m** |
| 2 walk | `INTERCHANGE` | `INTERCHANGE_TAFT_PASAY_MRT_BUENDIA` | 2 | 0.00 m | 0.00 m |
| 3 train | `MRT-3` | 6 edges Buendia→Cubao (NB) | 11 | 0.00 m | 0.00 m |

Every junction between merged steps matched exactly (no dropped-point gap > 1 m). A second trace (`STOP_QUIAPO` → `MRT_AYALA`, 13 steps → 4 legs incl. two interchanges and 9 merged reversed LRT-1 edges) gave identical 0.00 m results. **Conclusion: with bundled data, the Commute tab cannot produce cut endpoints.** If the user observes symptom 1 on the Commute tab on a real device, the device's *Documents* graph copy has been modified (LoopCreator save, Explore line-delete, or a stale server sync) — check `Documents/transit_graph_v3.json` on-device against the invariant.

For 1a: `ExploreView.swift:195-224` (snapped coords returned verbatim) + `:296-306` (snapped coords preferred) + station dots at JSON coords (`:364-372`, rendered `:483-489`). For 1b: compare `RecordCommuteView.swift:256` (station coord = `simplifiedWaypoints[si]`, a raw GPS point) vs `:280` (polyline starts at `road[fromRoad]`, a snapped vertex).

### Proposed fix

1. **`ExploreView.swift` — pin snapped polylines to station endpoints.** In `snapToRoads` (stitch loop, `:181-192`): after building `stitched` for an edge, force-prepend the edge's first original coordinate (`seg.from` of idx 0) if `stitched.first` differs from it, and force-append the last original coordinate (`seg.to` of the final segment) if `stitched.last` differs. Equivalently: prepend `seg.from` before each snapped segment's coords when they don't already match, and append the final `seg.to`. This guarantees every rendered edge still starts/ends at the station dot regardless of MKDirections snapping. Also fix the mixed-success fallback (`:186-189`) to bridge from the previous stitched endpoint rather than jumping straight to `seg.to`.
2. **`RecordCommuteView.swift` — restore the invariant at save time.** In `generateAndSave`, either (preferred) set each station dict's `coordinates` to `road[roadIdxForStop[i]]` (the on-road vertex the polyline actually starts/ends at) instead of `simplifiedWaypoints[si]` (`:252-256`), or prepend/append the station coordinate to `polySlice`. The straight-line fallback branch (`:281-286`) already uses the station coords on both ends, so it becomes consistent automatically with the "prepend/append" variant; with the preferred variant, change that fallback to use the same road vertices.
3. **`LoopCreatorView.swift` — remove the false wrap-around.** At `:261-277`, only take the `tail + head` wrap path for the actual closing segment (`i + 1 == count`). For a non-closing segment with `fromRoad > toRoad`, fall back to a direct two-point slice `[station_i, station_{i+1}]` (or search `nearestRoadIndex` constrained to indices `> fromRoad`).

Do **not** change `consolidateLegs` / the CLAUDE.md stitching rule — it is verified correct.

### How to verify

- Programmatic: re-run the invariant check (for every edge in the *effective* graph — Documents copy included — assert `haversine(polylineCoordinates[0], fromStation.coordinates) == 0` and same for the tail; ideally as a Swift Testing test against `GraphLoader.load()` output plus a check run after a simulated LoopCreator/RecordCommute save).
- Visual: Explore tab — every non-train line's stroke must touch every station dot on that line, including terminals set back from roads (Cartimar Terminal, Market Market). Commute tab — origin green dot and destination red pin sit exactly on the ends of the first/last leg polylines for a jeepney→walk→train route (e.g. Paranaque West Terminal → Araneta Center-Cubao).

---

## Issue 2: Polylines not following roads

### Root cause

**Primarily a data problem, exposed by a code asymmetry.** Per the schema (`.claude/skills/transit-data.md:55-59`), `polylineCoordinates` "intermediate points follow the physical alignment of the route". The bundled data does not honor this for road modes: all 11 bus/jeepney/tricycle edges have only 2–9 points total, with inter-point chords of 1–3 km that cut across the street grid. No bundled edge has `isRoadSnapped` set. The code split:

- `ContentView` (Commute tab) draws `leg.polylineCoordinates` **raw** (`ContentView.swift:28-34`) → chords visible.
- `ExploreViewModel` (Explore tab) replaces them at runtime with MKDirections `.automobile` snapping (`ExploreView.swift:132-142`, `152-193`) → looks road-following there (at the cost of Issue 1a and a per-launch MKDirections call for every segment of every road edge — currently ~40+ requests each time the tab loads, `fetchTotal` at `:141`).

So the coordinates that would make the line follow the road **do not exist in the data**; it is not a case of existing coordinates being ignored. Additionally, part of the *train* network is genuinely misplaced (below) — that is pure data corruption, no code involvement.

### Evidence

Density/chord analysis of `transit_graph_v3.json` (worst straight segment per edge, haversine):

| Edge | Line / mode | Points | Worst straight chord |
|---|---|---|---|
| `E_BUS_COMMONWEALTH_CUBAO` | `COMMONWEALTH_BUS` / bus | 5 | **3.14 km** — `(14.6511, 121.0489) → (14.6231, 121.0524)` |
| `E_JEEPNEY_QUIAPO_CUBAO` | `JEEPNEY_QUIAPO_CUBAO` / jeepney | 6 | **2.71 km** — `(14.6033, 120.9894) → (14.6111, 121.0133)` |
| `E_JEEPNEY_MAKATI_QUIAPO` | `JEEPNEY_MAKATI` / jeepney | 6 | 1.92 km |
| `E_BUS_EDSA_MEGAMALL_AYALA` | `EDSA_BUS` / bus | 5 | 1.64 km |
| `E_JEEP_AIRPORT_TO_PARANAQUE` | `JEEPNEY_CARTIMAR_LRT` / jeepney | 5 | 1.18 km |
| `E_EJEEPNEY_BGC_AYALA` | `EJEEPNEY_BGC` / jeepney | 4 | 1.08 km |
| `E_TRICYCLE_MANILA_QUIAPO` | `TRICYCLE_MANILA` / tricycle | 3 | 0.60 km |

On the traced route above, Leg 1 (jeepney, 14 stitched points over ~8.4 km) has three ~0.95 km straight chords — the drawn line cuts across Pasay blocks instead of following the jeepney's streets. The `JEEPNEY_CARTIMAR_LRT` edges have polyline-length ≈ `distanceKm` (ratio 1.00), meaning `distanceKm` was *computed from the chords*, so travel times/fares for these are also slightly short.

**Separate train-data corruption (also renders as "cuts straight across"):**

- **9 LRT-1 stations are misplaced** on a synthetic diagonal east of the real Taft Avenue corridor: `LRT1_EDSA`, `LRT1_LIBERTAD`, `LRT1_GIL_PUYAT`, `LRT1_VITO_CRUZ`, `LRT1_QUIRINO`, `LRT1_PEDRO_GIL`, `LRT1_UN_AVE` (drift growing to ~4 km at UN Ave, `lng 121.0231` vs real ≈ `120.9846`), plus `LRT1_R_PAPA` and `LRT1_5TH_AVE`. Provable *without* external geography: `E_LRT1_UNAVENUE_CENTRAL` declares `distanceKm: 1.58` but its own polyline is **5.20 km** long, including a single **4.15 km** chord `(14.5828, 121.0194) → (14.5928, 120.9822)` snapping back to the correctly-placed `LRT1_CENTRAL`; it also contains a duplicated consecutive point (index 2 == 3). `E_LRT1_5THAVE_MONUMENTO`: polyline 2.98 km vs declared 1.53 km.
- **`E_LRT1_EDSA_EDSABUS`** (INTERCHANGE walk, `LRT1_EDSA → STOP_EDSA_AYALA`) declares `distanceKm: 0.1` / 5 min, but the two stations are **3.17 km** apart — rendered as a 3 km thin gray "walk" chord and treated by A* as a 5-minute transfer, distorting route choice, not just rendering.

### Proposed fix

1. **Data (`CommuteBeh/transit_graph_v3.json`) — the substantive fix:**
   - Densify `polylineCoordinates` for all 11 bus/jeepney/tricycle edges with road-following intermediate points (target: no inter-point chord > ~150 m). Generate them once, offline (MKDirections/OSRM trace along each line's actual streets), and bake them into the JSON with `isRoadSnapped: true` — this is deterministic, keeps the app offline-first, and lets ExploreView's existing `isRoadSnapped == true` short-circuit (`ExploreView.swift:121-126`) skip its runtime snapping (also largely eliminating Issue 1a and the ~40 MKDirections calls per Explore load).
   - Correct the 9 misplaced LRT-1 station coordinates **and** every polyline that embeds them (all LRT-1 edges between EDSA and Central, `E_LRT1_5THAVE_MONUMENTO` neighborhood, and the interchange/walk edges touching those stations), keeping the `polylineCoordinates[0]/[-1] == station coords` invariant. Recompute those edges' `distanceKm`. Remove the duplicated point in `E_LRT1_UNAVENUE_CENTRAL`.
   - Fix `E_LRT1_EDSA_EDSABUS`: either re-anchor the interchange to a bus stop actually adjacent to LRT1 EDSA (preferred; the `EDSA_BUS` line currently has no stop there, so add one) or set honest `distanceKm`/`travelTimeMinutes` so A* stops treating a 3.17 km walk as a 5-minute hop.
2. **Code — none required in `ContentView`** once the data is dense; keep rendering raw JSON polylines. Do *not* copy ExploreView's runtime snapping into ContentView (nondeterministic, slow, quota-bound, and the source of Issue 1a).
3. Add the chord check to the data-validation checklist in `.claude/skills/transit-data.md` (polyline length within ~±20% of `distanceKm`; no segment > 150 m without an intermediate point) so regressions are caught when lines are added.

### How to verify

- Programmatic: for every non-walk edge, `sum(haversine(p[i], p[i+1])) ≈ distanceKm` (±20%) and max inter-point chord ≤ 150 m; every LRT-1 station within the Taft/Rizal/EDSA corridor bbox; polyline endpoint invariant still 0 m everywhere.
- Visual: Commute tab route Quiapo → Cubao — the green jeepney stroke follows streets (no diagonal across Sampaloc); LRT-1 line in Explore hugs Taft Avenue; no 3 km gray walk chord at LRT1 EDSA.

---

## Issue 3: Admin editing doesn't reliably reflect live map state

### Feature location

**Exists.** `CommuteBeh/AdminRoutesView.swift` — tab shown only for `role == "admin"` (`CommuteBehApp.swift:31-34`, `UserSession.isAdmin` at `UserSession.swift:9`). Scope is **station lat/lng only** (no edge/polyline editing exists anywhere). Flow: `AdminRoutesView` lists lines→stations from the **local** graph (`GraphLoader.load()`, `AdminRoutesView.swift:18-31`) → `EditStationMapView` full-screen pan-map picker (`:148-268`) → `AdminRoutesViewModel.updateStation` (`:33-50`) → `AdminService.updateStation` (`AdminService.swift:9-15`) → `PATCH /api/v1/admin/stations/:id` (`APIEndpoint.swift:73`, body at `:120-121`) against the deployed Rails backend (`https://commute-backend-a6lj.onrender.com`, Supabase Postgres). **Persistence is remote-only** — "editing" does *not* write to `transit_graph_v3.json`; the CLAUDE.md claim of "no external dependencies" predates the networking layer and is stale.

### Root cause

Broken at five points (first three independently confirmed in code here and in the Rails repo; matches `BACKEND_AUDIT.md` §3.2):

1. **Server silently no-ops.** iOS sends `{"station": {"latitude": …, "longitude": …}}` (`APIEndpoint.swift:120-121`); the controller permits only `:lat, :lng` (`commutebeh-rails/app/controllers/api/v1/admin/stations_controller.rb`, `station_params`). `@station.update({})` succeeds updating nothing → HTTP 200 with the **unchanged** station.
2. **Client can't decode the response.** `AdminService` decodes `APIResponse<APIStation>` where `APIStation` expects `stationId/latitude/longitude/lineIds/isTerminal` (`APIModels.swift:29-37`), but the server returns `as_api_json` — `id, short_name, line, type, coordinates:{lat,lng}, …` (`station.rb`). With `.convertFromSnakeCase` (`APIClient.swift:8`) the keys still don't match → decode throws → `EditStationMapView.confirm()` shows "Save failed" (`AdminRoutesView.swift:255-267`). Net UX: *the admin is told the save failed; the server said 200-but-changed-nothing.*
3. **The map the admin (and every user) sees never updates.** (a) `updateStation` mutates only in-memory `lineGroups` (`AdminRoutesView.swift:37-49`); the Documents graph file is never written and `TransitDataDidUpdate` is never posted, so the A* engine, Commute map, and Explore map keep the old coordinate. (b) `vm.load()` re-reads the *local* graph on every `.onAppear` (`:83`), clobbering the optimistic in-memory update — the admin sees the old value again just by navigating away and back. (c) The OTA path that would eventually deliver the server value is itself dead: `GraphVersion.version` is decoded as `String` but the server sends an Int (`APIModels.swift:63-66` vs live `{"version":1}`), so `GraphService.syncIfNeeded` (`GraphService.swift:27-36`) silently aborts on `try?`; and even comparing "1" to the bundle's `"1.0.0"` would never work. (d) Server-side, the admin update busts only the `stations*` cache — **not** `full_graph`/`graph_version` — and `bump_graph_version!` is called only from `add_route`/`remove_route` (`graph_service.rb:129,160,341-343`), so a station edit never changes the version clients poll. The edit is unreachable by design, four times over.
4. **The edit map shows no route context.** `EditStationMapView` renders a bare `Map` with a fixed center pin (`AdminRoutesView.swift:174-191`) — no line polyline, no connected edges, no sibling stations. The coordinate readout updates live (`onMapCameraChange`, `:175-177`), but the admin cannot see where the station sits relative to the route they're editing, i.e. the map does not reflect what they're working on.
5. **No validation anywhere.** Client: `confirm()` sends whatever the map center is — no Metro Manila bounds check, no "you moved it 12 km" sanity check. Server: `Station` model validates only presence of `station_id/name/line/type` (`station.rb`) — no lat/lng range or type validation; a PATCH could set a station to the middle of the sea. (Duplicate-ID and dangling-edge validation are N/A for this endpoint since it can only move an existing station — but nothing prevents a move that makes its edges geometrically absurd.)

**Coupling back to Issues 1–2:** yes, edited coordinates flow into the exact pipeline audited above — `stations[].coordinates` drives pins/dots and A*'s heuristic, while the *old* coordinate remains baked into every touching edge's `polylineCoordinates` endpoints (both in the server DB and in any synced JSON). Nothing regenerates polylines on a station move. So the first admin edit that actually lands will violate the endpoint invariant and **reintroduce Symptom 1** (line ends at the old spot, pin at the new spot) on every edge touching that station.

### Evidence

- Param mismatch: `APIEndpoint.swift:120-121` (`latitude`/`longitude`) vs `stations_controller.rb` `params.require(:station).permit(:lat, :lng)`.
- Decode mismatch: `APIModels.swift:29-37` vs `Station#as_api_json` in `commutebeh-rails/app/models/station.rb`.
- No local persistence / stale reload: `AdminRoutesView.swift:33-50` (in-memory only), `:83` (`onAppear { vm.load() }` re-reads local JSON).
- Dead OTA: `APIModels.swift:63-66` (`version: String`) vs live `GET /api/v1/graph/version → {"version":1,…}`; `graph_service.rb:205-213` + bump call sites `:129/:160` only.
- No polyline regeneration: `stations_controller.rb#update` touches only the station row; contrast with the invariant check in Issue 1 (all edges embed station coords at polyline ends).
- Corroborated by `BACKEND_AUDIT.md` §3.2/§3.3 (2026-07-02).

### Proposed fix

Client (this repo):

1. `APIEndpoint.swift` `.updateStation` body: send `{"station": {"lat": …, "lng": …}}`.
2. `APIModels.swift`: replace `APIStation` with a type matching `as_api_json` (`id, name, short_name, line, type, coordinates:{lat,lng}, is_terminal, is_interchange, amenities, operating_hours`) — snake_case handled by the existing decoder; also change `GraphVersion` to `version: Int` + `lastModified: String` and make `GraphService.syncIfNeeded` compare against a server-comparable version (requires storing the server version alongside the graph, since the bundle's `"1.0.0"` string is not comparable — simplest: persist last-synced Int in UserDefaults).
3. `AdminRoutesViewModel.updateStation`: on success, also rewrite the station's coordinates **and the endpoints of every edge whose `from`/`to` is that station** in the Documents `transit_graph_v3.json` (same read-modify-write pattern as `ExploreViewModel.removeFromGraph`, `ExploreView.swift:244-286`), then post `TransitDataDidUpdate` so `CommuteViewModel`/`ExploreViewModel` reload. This keeps the endpoint invariant and prevents the Symptom-1 regression.
4. `EditStationMapView`: overlay the station's line — `MapPolyline` for each edge touching the station (from the loaded graph) plus dots for the adjacent stations — so the admin sees the route they're editing; recompute the touched edges' first/last polyline point from the live `centerCoordinate` for a true live preview. Add a client-side bounds check (Metro Manila bbox, approx lat 14.3–14.9, lng 120.9–121.2) and a confirm step when the move exceeds ~500 m.
5. Remove the `onAppear`-reload clobber: reload from disk only when data actually changed (e.g. listen to `TransitDataDidUpdate`), not on every navigation.

Server (`/Users/obiee/Desktop/proj/commutebeh-rails` — separate repo, listed for scope): permit/validate lat (-90..90)/lng (-180..180) plus a service-area check; update touching edges' polyline endpoints in the same transaction; call `bump_graph_version!` and bust `full_graph`/`graph_version` caches on station update so clients can ever see the change.

### How to verify

After fixes, as an admin: move a station ~100 m → UI confirms success (no "Save failed") → `GET /api/v1/stations/:id` returns the new coords → the Admin list shows the new value after navigating away/back → Commute tab route through that station shows pin *and* polyline endpoints at the new location (zero gap) → fresh install (or cleared Documents) receives the change via `syncIfNeeded` because `/graph/version` incremented. Attempting to save a coordinate outside Metro Manila is rejected on both client and server.

---

## Files a fix will touch

**This repo (iOS):**

| File | Why |
|---|---|
| `CommuteBeh/transit_graph_v3.json` | Densify 11 road-mode edge polylines; fix 9 LRT-1 station coords + affected LRT-1/interchange edge polylines & `distanceKm`; fix `E_LRT1_EDSA_EDSABUS`; remove duplicate point (Issue 2) |
| `CommuteBeh/ExploreView.swift` | Pin snapped polylines to station endpoints; fix mixed-success stitch fallback (Issue 1a) |
| `CommuteBeh/RecordCommuteView.swift` | Make station coords consistent with polyline slice endpoints (Issue 1b) |
| `CommuteBeh/LoopCreatorView.swift` | Restrict wrap-around slice to the closing segment (Issue 1c) |
| `CommuteBeh/APIEndpoint.swift` | `lat`/`lng` body keys (Issue 3) |
| `CommuteBeh/APIModels.swift` | `APIStation` shape; `GraphVersion.version: Int` (Issue 3) |
| `CommuteBeh/AdminService.swift` | Decode type change follows `APIModels` (Issue 3) |
| `CommuteBeh/AdminRoutesView.swift` | Local persistence + edge-endpoint rewrite + `TransitDataDidUpdate`; route-context overlay + validation in `EditStationMapView`; remove onAppear clobber (Issue 3) |
| `CommuteBeh/GraphService.swift` | Version comparison logic for OTA sync (Issue 3) |
| `.claude/skills/transit-data.md` | Add chord-density & length-vs-distance validation rules (Issue 2) |
| `CLAUDE.md` | Doc drift only: ExploreView loads **v3** (not v2; `transit_graph_v2.json` is referenced by nothing and can be dropped from the bundle); "no external dependencies" is outdated |
| *(new)* `CommuteBehTests/…` | Invariant tests: polyline endpoints == station coords; chord density; length≈distanceKm (target doesn't exist yet — see `.claude/skills/swift-testing.md`) |

**Separate repo (`/Users/obiee/Desktop/proj/commutebeh-rails` — out of scope here but required for Issue 3 end-to-end):** `app/controllers/api/v1/admin/stations_controller.rb` (params/validation/cache/version-bump), `app/services/graph_service.rb` (bump on station update, edge polyline endpoint rewrite), `app/models/station.rb` (range validation).

## Open questions / assumptions

- **No runtime verification.** Nothing here was confirmed on a simulator/device; Issue 1a's visual gap size depends on how far each station sits from the road network (code guarantees the mechanism, not the magnitude). The numeric traces used a Python re-implementation of the engine's cost/stitching logic — faithful to the Swift line-by-line, but not the Swift binary itself.
- **Which tab the user saw Symptom 1 in.** With bundled data the Commute tab provably cannot cut endpoints. If it was observed on Commute on a real device, inspect that device's `Documents/transit_graph_v3.json` — a LoopCreator save, an Explore line-delete, or a historic sync will have modified it (mechanisms 1b/1c). Explore tab exhibits 1a with pristine data.
- **LRT-1 real-world positions** are asserted from general geography; the *internal* proof (polyline length 5.20 km vs declared 1.58 km on `E_LRT1_UNAVENUE_CENTRAL`, 4.15 km chord, 3.17 km "0.1 km" walk) stands on the data alone. Correct coordinates must be sourced when fixing the JSON.
- **Server DB constraints** were checked only at the Rails model layer (no lat/lng validation found); a DB-level CHECK constraint may exist in migrations — not inspected.
- **Server graph content vs bundle**: assumed equivalent (audit of 2026-07-02 reported 60 stations / 76 edges, healthy). If the DB polylines have drifted from the bundled JSON, the Issue 2 data fixes must be applied to the DB (via the admin graph routes) as well, not just the bundle.
- **`recorded_routes.json` import** is presumed planned (RecordCommute is a full feature writing to a file nothing reads). Fix 1b before building that import, or every recorded route arrives pre-broken.
- **`ExploreViewModel.removeFromGraph`** (`ExploreView.swift:244-286`) deletes a line's stations/edges but leaves INTERCHANGE edges referencing the deleted stations dangling in the Documents JSON. The engine tolerates them (lookups are guarded), so it's not part of the three issues — flagged here as adjacent hygiene for the same file.
