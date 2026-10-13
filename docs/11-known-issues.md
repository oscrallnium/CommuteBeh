# 11. Known Issues & Documentation Drift

Written 2026-08-10 against branch `feature/route-search-result-ui-v2`. Items marked
**unverified** come from earlier audit documents and were not re-tested while writing this
set — check before acting on them.

## Documentation drift

Stale guidance that will actively mislead you.

| Where | Says | Actually |
|---|---|---|
| `CLAUDE.md` | "A\* engine on a **bundled** JSON graph"; "Active data: `transit_graph_v3.json`"| `Gora/Resources/` is **empty**. The graph is downloaded and cached in `Documents/`. There is no bundled copy and no bundle fallback. |
| `CLAUDE.md` | `TransportMode.swift` contains `CommuteViewModel` | The view model is `RouteStore` (`Domain/TransportMode.swift:1691`). No `CommuteViewModel` exists. |
| `CLAUDE.md` | "Consolidate `modeColor(_:)` into `extension TransportMode { var color }` before adding more call sites"| **Already done.** `DesignTokens.swift:128` is the single source; no `modeColor` function remains anywhere. |
| `CLAUDE.md` | "Everything else is UI: `ContentView.swift`, `ExploreView.swift`"| The tree has since grown `Admin/`, `Networking/`, `Services/`, `Design/`, `Debug/`, `Views/CommuteMode/`, `Views/Record/`, `Views/Auth/`, `Views/Settings/`. |
| `CLAUDE.md` | `transit_graph_v2.json` is loaded by `ExploreView` | Neither v2 nor v3 JSON is present in the repo. |
| `CLAUDE-backend.md` | Backend is **Hono / TypeScript**, reads and writes a JSON file, no database | Backend is **Rails 7.1 + Postgres**. This document describes a design that was not built. |
| `CLAUDE-web.md` | A Next.js 14 admin form at `commutebeh-web` | No such project exists on disk. Route authoring happens in the iOS Record and Admin tabs. |
| `CLAUDE.md` transit-lines table | Lists 6 jeepney lines and `TRICYCLE_MANILA` | Lines now live in a `lines` DB table and include UPLB/Los Baños routes. The table is a snapshot, not a source of truth. |

**Recommendation:** rewrite `CLAUDE.md`'s Project / Critical File Layout / Map Styling sections
against this `docs/` set, and either delete `CLAUDE-backend.md` and `CLAUDE-web.md` or move them
to an `archive/` folder with a header saying they were never built.

## Structural

### `Domain/TransportMode.swift` is 2011 lines

It holds every model type, the A\* actor, the main view model, the graph loader, the station
cache, the location fetcher, `MinHeap` and `AccessPolicy`. The filename describes roughly 1% of
its contents. Splitting it into `Models/`, `Engine/`, `Stores/` is the highest-value refactor
available and is purely mechanical.

`ContentView.swift` (2631 lines) and `app/services/graph_service.rb` (1141 lines) have the same
problem at smaller scale.

### No iOS test target

`project.pbxproj` has zero references to `GoraTests`. Every `xcodebuild … test` command in
`CLAUDE.md` and in [10. Development](10-development.md) currently fails. The routing engine is
pure, deterministic, dependency-free logic — it is close to ideal for unit testing, and none
exists.

The backend does have RSpec coverage, concentrated on `GraphService` stop editing and the admin
endpoints.

### Working documents in the repo root

Fifteen-plus `FEATURE_*.md` / `BUG_*.md` / `FINDINGS_*.md` / `HOWTO_*.md` / `*_AUDIT.md` files
sit at the repository root, most untracked. They are investigation notes frozen at their writing
date. Recommend moving them to `docs/archive/` so the maintained set is unambiguous.

## Operational

### Render cold starts

The `starter` plan spins down on idle; a cold request takes roughly **44 seconds**. First launch
after a quiet period looks like a hang. Worth an explicit loading state, and worth remembering
before debugging a "network bug" that is just a cold dyno.

### First launch requires network

No bundled graph means no offline first run. Once cached, the app routes fully offline. A
bundled seed graph as a fallback would close this gap.

### Analytics may not be wired

**unverified.** An audit dated 2026-07-04 found `AnalyticsService.logRoutePlan` had zero call
sites, and that the payload contract disagreed with the server in three ways (envelope, field
names, seconds vs minutes) — while the server returned 201 regardless, because it rescues every
failure. The server side has since been aligned with the iOS body shape
(`analytics_controller.rb` reads `params[:event]` and converts `duration_seconds` → minutes), but
whether anything calls it client-side was not re-checked.

Because the endpoint always returns 201, **a silent total failure here looks exactly like
success**. Verify with a server-side row count, not a response code.

### CORS

**unverified.** The same audit found `rack-cors` configured with `*` in production.
`ALLOWED_ORIGINS` is wired through `render.yaml`, so this may already be fixed — confirm in
`config/initializers/cors.rb`.

### Routes with no controllers

`config/routes.rb:58` declares `resources :places` and `resources :events` for the Explore tab.
No corresponding controllers exist. Requests to them raise a routing/uninitialised-constant
error rather than 404.

## Data quality

**unverified**, from the polyline audit of 2026-07-03:

- Nine LRT-1 stations had misplaced coordinates. Migration
  `016_correct_rail_station_coordinates.rb` addresses rail coordinates and may cover this.
- Road-mode polyline data is sparse — many edges are two-point straight lines. Migrations 013
  and 015 added `is_road_snapped` and backfilled it for dense edges, which is what lets Explore
  target its snapping pass. The underlying gap is a surveying backlog, not a code defect.
- Edge polyline stitching in the engine was verified **correct**; the visible artefacts traced to
  Explore's runtime road-snapping and to the sparse source data.

## Design constraints, not bugs

Recorded here so nobody "fixes" them:

| Behaviour | Why it's deliberate |
|---|---|
| Stop renumbering can orphan IDs in `saved_routes`, `route_plan_events`, `ar_world_maps`, `incidents` | Renumbering was chosen over stable IDs. No DB-level FK exists. `graph_service.rb:344`. |
| Insert/remove stop refuses trains and closed loops | Asymmetric-graph and unrepairable-geometry risks respectively. |
| Analytics always returns 201 | An analytics failure must never block a commute. |
| `bust_graph_cache!` swallows all errors | A Redis blip must not turn a committed DB write into a client-visible 500. Worst case is briefly stale cache until TTL. |
| Walk legs are wrong when first shown, then corrected | Results appear at engine speed and sharpen a moment later; blocking on MKDirections would add seconds to every search. |
| Fewer than three route options is normal | Strategies frequently converge on the same path and are deduplicated. |
| Commute Mode's 3D camera doesn't follow heading | `RouteStore.userLocation` carries no course. Documented future work. |
| Jeepney and bus share the `bus.fill` icon | `car.fill` read as a private car; the green/orange split distinguishes them. |

## Suggested priority

1. Update `CLAUDE.md`; archive or delete `CLAUDE-backend.md` / `CLAUDE-web.md`. Cheap, and the
   drift is actively misleading — particularly the bundled-graph claim.
2. Add the `GoraTests` target and cover the engine: leg consolidation, fare computation,
   access-walk policy boundaries, polyline stitching.
3. Verify the analytics path end to end from a server row count.
4. Confirm the production CORS origin list.
5. Split `Domain/TransportMode.swift`.
6. Remove or implement the `places` / `events` routes.
