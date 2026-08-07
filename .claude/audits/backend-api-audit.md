# Backend API / Data-Contract Audit — Login, Routing, Data Analytics

**Date:** 2026-07-04 · **Scope:** data contract between the iOS app and the deployed Rails backend for three endpoint categories: login (auth), routing, and data analytics. UI/UX is explicitly out of scope. Route *rendering* (polylines, station placement, admin edit flow) was audited separately in `.claude/audits/polyline-audit.md` (2026-07-03) — cross-referenced below, not duplicated.

**Backend:** Rails 7.1 API at `/Users/obiee/Desktop/proj/commutebeh-rails` (authoritative copy — do **not** use `/Users/obiee/Desktop/proj/commutebeh-merged`, it is stale). Deployed at `https://commute-backend-a6lj.onrender.com` (Render starter plan, spins down on idle, ~44 s cold start). iOS points there via `APIConfig.baseURL` (`CommuteBeh/APIConfig.swift:4`). All live responses quoted below were captured against the deployed server on 2026-07-04.

---

## Summary

**The data layer is not trustworthy, but mostly because it is disconnected or silently broken — not because the UI mis-renders good data.**

- **Login: works on the happy path, lies on the failure paths.** Sign-in with valid credentials decodes correctly and the token lifecycle (JWT + JTI rotation) is sound. But a *wrong password* shows the user "Session expired. Please sign in again." (the 401 handler assumes token expiry), the server's actual error message is discarded, and a mid-session token revocation never signs the user out because the `.sessionExpired` notification is **defined but never posted** — the app keeps rendering a cached profile with a dead session. `homeStationId` is silently `nil` forever because the sign-in/refresh payloads omit it.
- **Routing: the UI never renders backend routing data at all** — routes come from the local A* engine over the bundled JSON. The only live backend dependency is OTA graph sync, and it is broken in **two stacked ways**: (1) `GraphVersion` decode fails (server sends `version` as Int + `lastModified`; iOS expects String + `updatedAt`), so sync silently aborts on every launch and the UI renders bundled data as if it were current; (2) **if (1) is fixed naively, the next step bricks the app** — `fetchGraph()` writes the server's `{"data": {...}}`-wrapped, Int-versioned payload raw to Documents, and `GraphLoader` prefers Documents with *no fallback to the bundle on decode failure*, so the app would fail to load transit data on every subsequent launch until reinstall. The server-side routing endpoints (`/api/v1/routes` 500s in production; `APIRoute`/`APIStation` models don't match server JSON) are dead code in the app today but are traps for whoever wires them up.
- **Data Analytics: nothing is ever sent.** `AnalyticsService.logRoutePlan` has zero call sites. Even if it were called, the payload contract is wrong three ways (envelope key, field names, units: seconds vs minutes), and the server would 201 anyway while persisting a row of NULLs — so the dashboard-facing data would be silently garbage. Any "analytics look wrong" symptom is a backend-contract problem, not a UI problem.

Bottom line for the UI/UX pass: **login error text and any "stale map data" complaints are data-layer bugs, not UI bugs.** Fix the contract first or the UI audit will chase ghosts.

---

## Login

### Exists?

**Yes.** Full flow: `LoginView.signIn()` (`CommuteBeh/LoginView.swift:83-96`) → `AuthService.signIn` (`CommuteBeh/AuthService.swift:19-26`) → `POST /auth/sign_in` (`CommuteBeh/APIEndpoint.swift:55,104-105`) → JWT saved to Keychain (`CommuteBeh/Keychain.swift`) → `UserSession.login` publishes `isLoggedIn`/`currentUser` (`CommuteBeh/UserSession.swift:34-38`) → `CommuteBehApp` swaps `LoginView` for `MainTabView` (`CommuteBeh/CommuteBehApp.swift:9-15`). Server side: `api/v1/auth/sessions_controller.rb` (Devise + devise-jwt, JTI revocation).

Note: `.register` exists in `APIEndpoint` and `AuthService`, and the server implements it, but **there is no registration screen** — `LoginView` is sign-in only. Not audited further; flagged in Open Questions.

### Findings

**L1 — Wrong password shows "Session expired. Please sign in again." (root cause: status-code-only error mapping + server message discarded).**
`APIClient.request` maps every 401 to `APIError.unauthorized` (`CommuteBeh/APIClient.swift:36-37`), whose `userMessage` is hardcoded to *"Session expired. Please sign in again."* (`CommuteBeh/APIError.swift:15`) — written for the token-expiry case, shown verbatim by `LoginView.swift:92` for a first-time bad-credentials failure. The response body is never read on 401. Additionally, the server's 401 body for bad credentials is **plain text, not JSON** (Devise/warden failure app intercepts before `SessionsController#respond_with`'s JSON error path runs), so even body-parsing code would need to handle text.

**Evidence (live, 2026-07-04):**
```
POST https://commute-backend-a6lj.onrender.com/auth/sign_in
{"user":{"email":"audit-nonexistent@example.com","password":"wrongpassword"}}
→ HTTP 401, body (text/plain): Invalid email or password.
```
iOS renders: *"Session expired. Please sign in again."* — factually wrong for this user.

**L2 — Mid-session 401 never signs the user out: `.sessionExpired` is defined but never posted.**
`UserSession.init` subscribes to `.sessionExpired` and its comment claims *"Any 401 from the API layer broadcasts this"* (`CommuteBeh/UserSession.swift:24-31`), but nothing in the codebase ever posts it — `APIClient.swift:36-37` just throws. The notification name is declared at `CommuteBeh/APIEndpoint.swift:128-130` and referenced nowhere else. Consequence: if the token is revoked server-side mid-session (e.g. refresh raced, account deleted, JTI rotated elsewhere), the UI keeps showing the cached `UserProfile` from UserDefaults as if logged in; every API call fails individually. The only recovery is the *next app launch*, where `refreshSession()` catches `APIError.unauthorized` and clears the session (`UserSession.swift:47-58`). This is exactly the "silently render stale state as if the request succeeded" failure mode.

**L3 — `homeStationId` is always nil (server omits it from auth payloads).**
iOS `UserProfile` has `homeStationId: String?` (`CommuteBeh/APIModels.swift:18-24`), but the server's `user_payload` for sign_in **and** refresh returns only `id, email, display_name, role` (`commutebeh-rails/app/controllers/api/v1/auth/sessions_controller.rb`, `user_payload`). Since `UserSession` only ever populates `currentUser` from sign_in/refresh (never from `GET /api/v1/me`, which *does* return `home_station_id`), the field silently decodes to `nil` forever. Optional-typed, so no decode error — pure silent data loss. (`registrations_controller.rb#create` has the same omission.)

**What works (verified in code):** success payload `{"data":{"token":…,"user":{"id":<uuid string>,"email":…,"display_name":…,"role":"commuter"|"admin"}}}` decodes cleanly into `APIResponse<AuthPayload>` via `.convertFromSnakeCase` (`APIClient.swift:8`); `users.id` is a Postgres uuid (schema.rb line 202), so the String type matches. Token lifecycle is sound: refresh rotates JTI before encoding the new token (old token revoked atomically, `sessions_controller.rb#refresh`); iOS saves the new token (`AuthService.swift:29-36`). Sign-out tolerates failure and always clears the Keychain (`AuthService.swift:38-41`). Register-validation 422s match: server sends `{error:, errors:[]}` which `ErrorResponse` decodes (`APIError.swift:27-30`, `APIClient.swift:42-44`).

**Edge case worth noting:** Render cold start is ~44 s; `URLSession.shared` default request timeout is 60 s. Sign-in on a cold backend will sit on a spinner for ~45 s and can plausibly time out → "Check your internet connection." — misleading but rare. No retry/keep-warm exists.

### Proposed fix (describe only — do not apply in this pass)

1. In `APIClient.request`, on 401/403 attempt to decode `ErrorResponse` (and fall back to `String(data:encoding:)` for plain-text bodies) and carry the server message in the error, e.g. `case unauthorized(String?)`. `LoginView` then shows "Invalid email or password." on bad credentials. Alternatively (server side) configure Devise's failure app to respond JSON so the body shape is uniform.
2. Post `NotificationCenter.default.post(name: .sessionExpired, …)` from `APIClient.request`'s 401 branch — **except** for the `.signIn`/`.register` endpoints (a login 401 must not trigger the sign-out path). Distinguish via the endpoint case or a flag on the request.
3. Server: add `home_station_id: user.home_station_id` to `user_payload` in `sessions_controller.rb` and to the register payload in `registrations_controller.rb` (the `users` table has the column; `GET /api/v1/me` already returns it).

### How to verify

- Wrong password on the login screen → message reads "Invalid email or password." (not "Session expired…").
- Sign in on device A, sign in on device B (rotates JTI), make any request on device A → device A lands back on `LoginView` without needing an app restart.
- Set a home station via `PATCH /api/v1/me`, sign out and back in → `session.currentUser?.homeStationId` is non-nil.
- Regression: valid sign-in still lands on `MainTabView`; register-validation errors still show the field messages.

---

## Routing

### Exists?

**Yes, but split-brained — and the UI consumes almost none of it.** Route calculation shown to the user is 100 % local: `CommuteViewModel.calculateRoute` → `TransitGraphEngine` A* over the bundled/cached `transit_graph_v3.json` (`CommuteBeh/TransportMode.swift`). The backend's routing surface is:

- `GET /api/v1/graph/version` + `GET /api/v1/graph` — **live**, used by `GraphService.syncIfNeeded` (`CommuteBeh/GraphService.swift:27-36`), fired in the background after every engine load (`TransportMode.swift:1023-1026`).
- `GET /api/v1/stations`, `/api/v1/routes`, `/api/v1/saved_routes` — network layer exists (`RouteService.swift`) but has **zero call sites** in any view or view model. Dead code today.
- `PATCH /api/v1/admin/stations/:id` — live via the Admin tab; **fully audited as Issue 3 of `.claude/audits/polyline-audit.md`** (server no-ops the update due to `latitude/longitude` vs `lat/lng` param mismatch; client can't decode the `as_api_json` response; edit never reaches the rendered map). Not re-audited here.

So "does the route data structure the backend returns match what route-rendering consumes?" — the route-rendering pipeline (polylines, legs, fares) never touches the backend; its data bugs are local-JSON bugs already documented in the polyline audit. The routing *contract* bugs below all concern the OTA sync channel that is supposed to keep that local JSON fresh.

### Findings

**R1 — OTA graph sync is dead: `GraphVersion` cannot decode the server's version payload (root cause: Int vs String type + wrong field name).**
iOS model (`CommuteBeh/APIModels.swift:63-66`):
```swift
struct GraphVersion: Decodable {
    let version: String
    let updatedAt: String
}
```
**Evidence (live, 2026-07-04):**
```
GET https://commute-backend-a6lj.onrender.com/api/v1/graph/version
→ HTTP 200
{"data":{"version":1,"lastModified":"2026-06-27T01:06:41+08:00","stationCount":60,"edgeCount":76}}
```
Two independent decode failures: `version` is an Int (server column is `t.integer "version"`, `commutebeh-rails/db/schema.rb:97-103`; serialized in `graph_service.rb#graph_version`), and there is no `updatedAt`/`updated_at` key (server sends `lastModified`; `.convertFromSnakeCase` doesn't help because the source key has no underscore). `GraphService.syncIfNeeded` swallows this with `try?` (`GraphService.swift:29`) and returns — **every launch, silently**. The UI then renders bundled `"1.0.0"` data as if it were current: stale-state-as-success, precisely the failure class this audit was asked to find. Note the *semantic* mismatch too: even with matching types, comparing server `1` against the bundle's `"1.0.0"` (`transit_graph_v3.json` top: `"version": "1.0.0"`) would always report "different" — the two sides don't share a versioning scheme. *(Cross-ref: polyline-audit.md Issue 3 root-cause item (c) records this same bug as the reason admin edits can never propagate; item (d) records that station edits don't bump the version even server-side. This section is the canonical write-up; the fix list below supersedes/absorbs those two items.)*

**R2 — Latent app-bricking bug: a "fixed" sync would poison the local graph cache (root cause: `/graph` response envelope + schema drift vs `TransitGraph`, combined with GraphLoader's Documents-first, no-fallback load).**
The pipeline: `GraphService.fetchGraph()` returns the **raw response bytes** (`GraphService.swift:18-22`) and `syncIfNeeded` writes them verbatim to `Documents/transit_graph_v3.json` (`GraphService.swift:30-32`). But:

- The server wraps the graph: `GraphController#show` → `json_response(graph)` → `{"data": {…}}` (`commutebeh-rails/app/controllers/api/v1/graph_controller.rb`, `base_controller.rb#json_response`). The bundle file has no wrapper.
- Inside the payload, `version:` is the same **Int** (`graph_service.rb#assemble_graph`), while `TransitGraph.version` is `String` (`TransportMode.swift:171`).
- `TransitGraph` requires `peakHourMultipliers.morningPeak/eveningPeak/trainPeak` (`TransportMode.swift:165-179`); the server emits `peak&.data || {}` — an unvalidated jsonb blob that is `{}` if `peak_hour_configs` is empty (shape unverified — see Open Questions).
- `GraphLoader.load()` prefers the Documents copy and **returns `.failure` with no bundle fallback** if that file exists but fails to decode (`TransportMode.swift:947-964`).

Consequence: today, R1 makes this path unreachable. The moment someone fixes only the `GraphVersion` model, the very next sync writes an undecodable file into Documents, and **every subsequent launch fails with "Failed to load transit data"** (`TransportMode.swift:1027-1029`) until the app is deleted. Any fix for R1 **must** land together with the envelope/schema fix and a GraphLoader fallback. (Positives: the server's inner `stations[]`/`edges[]` serializers in `graph_service.rb#station_json/#edge_json` are camelCase and field-compatible with the iOS `Station`/`TransitEdge` structs — `interchangesWith` and `isRoadSnapped` are optional on the iOS side, so their absence is fine; `direction` is conditionally included, matching `String?`. `polyline_coordinates` jsonb element shape is assumed `{lat,lng}` — unverified, see Open Questions.)

**R3 — `GET /api/v1/routes` 500s in production (root cause: query selects columns that don't exist on `edges`).**
`RoutesController#index` does `Edge.select(:line, :mode, :base_fare, …, :open_time, :close_time, …)` (`commutebeh-rails/app/controllers/api/v1/routes_controller.rb`), but `open_time`/`close_time` exist only on `stations` — the `edges` table has no such columns (`db/schema.rb:63-88` vs `:162-181`) → Postgres `UndefinedColumn` → 500.

**Evidence (live, 2026-07-04):**
```
GET https://commute-backend-a6lj.onrender.com/api/v1/routes
→ HTTP 500, empty body
```
Impact is limited *today* because nothing in iOS calls `RouteService.routes()` — but the trap is double-layered: even with the 500 fixed, the response rows (`line_id, mode, base_fare, accepted_payments, …, stop_count`) cannot decode into iOS `APIRoute`, which requires a `name: String` and expects `color: String?` (`APIModels.swift:40-44`) — neither key is ever sent. Same class of drift for `APIStation` (`APIModels.swift:29-37`: flat `latitude`/`longitude`/`lineIds: [String]`) vs the server's `as_api_json` (nested `coordinates: {lat,lng}`, single `line` string, and `id` rather than `station_id` — `commutebeh-rails/app/models/station.rb`); that decode failure is already evidenced live in polyline-audit.md Issue 3 (root-cause item 2) via the admin PATCH response, which uses the same serializer.

### Proposed fix (describe only)

Decide the canonical version scheme first (recommend: keep the server's monotonically-increasing Int, as `bump_graph_version!` already does `version = version + 1`), then:

1. **iOS `APIModels.swift`**: `GraphVersion` → `version: Int`, `lastModified: String` (rename or add `CodingKeys`). `GraphService.syncIfNeeded(loadedVersion:)` compares Ints; `TransitGraph.version` becomes `Int` — which requires migrating the bundled JSON's `"version": "1.0.0"` to an Int (or a custom decoder accepting both during transition).
2. **Graph download**: either server adds an unwrapped endpoint (or `GraphController#show` renders the bare graph), or `GraphService.fetchGraph` decodes `APIResponse`-style and re-serializes only the inner object before writing to Documents. Validate before persisting: decode the downloaded bytes as `TransitGraph` **first**, and only write to Documents on success.
3. **`GraphLoader.load()`**: on Documents decode failure, delete the corrupt file and fall back to the bundle instead of returning `.failure`. This single change removes the bricking scenario permanently.
4. **Surface sync failures**: `syncIfNeeded` should at minimum `os_log` decode/network errors instead of `try?`-swallowing, so "stale data" is diagnosable; optionally expose a `lastSyncError`/`lastSyncedAt` for the Settings screen.
5. **Server `routes_controller.rb#index`**: drop `:open_time, :close_time` from the `Edge.select`/`group` lists (or source them from stations); align `APIRoute` with the actual row shape (or delete `RouteService`/`APIRoute`/`SavedRoute` dead code until a feature needs it — flagging, not deciding here).
6. Admin-PATCH param/serializer fixes and version-bump-on-station-edit: **see polyline-audit.md Issue 3 proposed fixes** — implement there, don't duplicate.

### How to verify

- Launch app with bundled data older than server: `syncIfNeeded` downloads, Documents file decodes, `TransitDataDidUpdate` fires, station count in the UI matches server (60 stations / 76 edges as of audit date).
- Corrupt `Documents/transit_graph_v3.json` by hand → app still boots from the bundle (no "Failed to load transit data").
- `curl …/api/v1/routes` → 200 with `data[]`; if `RouteService` is kept, a unit test decodes a captured response into `[APIRoute]`.
- End-to-end with the polyline-audit fix: admin moves a station → `/graph/version` increments → a second device picks it up via sync.

---

## Data Analytics

### Exists?

**Half.** The transmit path exists end-to-end in code — `AnalyticsService.logRoutePlan` (`CommuteBeh/AnalyticsService.swift:9-16`) → fire-and-forget `APIClient.send` (`APIClient.swift:53-62`) → `POST /api/v1/analytics/route_plan` (`APIEndpoint.swift:37,72,117-119`) → `AnalyticsController#route_plan` persisting a `RoutePlanEvent` (`commutebeh-rails/app/controllers/api/v1/analytics_controller.rb`, table at `db/schema.rb:134-146`). Admin read-side endpoints exist (`admin/analytics#summary/#hotspots`). There is **no third-party analytics SDK**; this one event is the entire analytics surface.

### Findings

**A1 — No analytics event is ever sent: `logRoutePlan` has zero call sites.**
Repo-wide grep: `AnalyticsService` is referenced only inside `AnalyticsService.swift`. The natural emit point — `CommuteViewModel.calculateRoute` after a successful A* result (`TransportMode.swift:1035+`) — never calls it. The server comment even says *"iOS calls this after a successful A\* run"* — it does not. So `route_plan_events` receives nothing from the app; any dashboard built on `admin/analytics` will read an empty (or manually-seeded) table. **This is the first, dominant root cause** — the contract mismatches below are latent behind it.

**A2 — The payload contract is wrong three ways (envelope, field names, units), and the server masks it by always returning 201.**
What iOS would send (`APIEndpoint.swift:117-119`):
```json
{"event": {"origin_station_id": "MRT_NORTH_AVE",
           "destination_station_id": "LRT1_BACLARAN",
           "line_ids": ["MRT-3", "LRT-1"],
           "duration_seconds": 2640}}
```
What the server reads (`analytics_controller.rb#route_plan`): **top-level** `params[:origin_id]`, `params[:destination_id]`, `params[:legs]`, `params[:total_time_minutes]`, `params[:modes_used]`. Mismatches:
1. **Envelope**: fields are nested under `"event"`; the controller reads them at the top level (no `wrap_parameters` initializer exists in the Rails app to bridge this, and even Rails wrapping would wrap under the controller-derived key, not unwrap `event`). Every read is `nil`.
2. **Names**: `origin_station_id` ≠ `origin_id`; `line_ids` matches neither `legs` (expected: leg objects) nor `modes_used` (expected: mode strings like `"train"` — line IDs like `"MRT-3"` are the wrong vocabulary even semantically).
3. **Units**: iOS sends `duration_seconds` (Int seconds); the column is `total_time_minutes` (Int minutes) — a 60× error waiting even after a naive rename.

Resulting row if the call were wired up: `origin_station_id: NULL, destination_station_id: NULL, legs: [], total_time_minutes: NULL, modes_used: []` — it **inserts successfully** because `RoutePlanEvent` validates only `occurred_at` (`app/models/route_plan_event.rb`), and the controller `rescue`s everything and returns `201 {"message":"Logged"}` regardless (deliberate — "never block the user's commute" — but it means the sender can never learn the payload is garbage). Combined with iOS's fire-and-forget `send()` discarding the response entirely (`APIClient.swift:60`), there is **no layer at which this mismatch could ever surface**. Intended data: which O/D pairs and modes people actually plan. Actual data: timestamped empty rows attributable to a user ID and nothing else.

**A3 (minor) — `APIClient.send` failure fallback is nonsense.** If `endpoint.urlRequest()` ever threw, the fallback issues a bare `GET https://commute-backend-a6lj.onrender.com/` (`APIClient.swift:55`) — a pointless request. Harmless today (the throw is unreachable for this endpoint) but should be a silent return.

### Proposed fix (describe only)

Pick one side as the contract and align the other; recommend fixing the **server** to accept what iOS already constructs (nested `event`, station-ID names) since the iOS shape is closer to the DB columns, plus one client rename:

1. Server `analytics_controller.rb`: read `event = params.require(:event)` (permit `origin_station_id, destination_station_id, line_ids: [], duration_seconds`); map `origin_station_id`→column, `destination_station_id`→column, `duration_seconds / 60`→`total_time_minutes` (or better: migrate the column to `total_time_seconds` and keep raw units). Decide `line_ids` vs `modes_used`: either add a `line_ids` string-array column (recommended — modes are derivable from lines via `transport_modes.lines`) or have iOS send `modes_used` derived from `RouteResult` legs.
2. iOS: call `AnalyticsService.shared.logRoutePlan(…)` from `CommuteViewModel.calculateRoute` on the success path, sourcing origin/destination IDs, the legs' line IDs, and `RouteResult` total time (mind its unit — the engine computes **minutes**; convert deliberately, don't guess).
3. Keep 201-always if desired, but log validation failures server-side at `warn` **with the raw params** so garbage payloads are diagnosable; add model-level presence validations on `origin_station_id`/`destination_station_id` so bad rows can't silently accumulate.
4. `APIClient.send`: replace the fallback-URL hack with `guard let urlRequest = try? endpoint.urlRequest() else { return }`.

### How to verify

- Plan a route in the app → exactly one new `route_plan_events` row with non-NULL origin/destination matching the picked stations, plausible minutes (a 44-min route stores 44, not 2640), and the right lines/modes.
- `admin/analytics/summary` and `hotspots` reflect the new event.
- Unit test: encode `.logRoutePlan(…)` body and assert it against a fixture of the server's permitted params (contract test pinning both sides).
- Negative: POST a deliberately malformed payload → row is *not* created and a warn log with params appears (while still returning 201 if that behavior is kept).

---

## Files a fix will touch

**iOS (`/Users/obiee/Desktop/proj/CommuteBeh/CommuteBeh/`):**
- `APIModels.swift` — `GraphVersion` (Int + `lastModified`), `UserProfile` (no change if server adds field), `APIRoute`/`APIStation` (align or delete with dead `RouteService`)
- `APIClient.swift` — 401 body parsing (JSON + plain-text), post `.sessionExpired`, `send()` guard
- `APIError.swift` — carry server message in `unauthorized`/error cases
- `GraphService.swift` — Int version compare, unwrap `data` envelope, validate-before-write, error logging
- `TransportMode.swift` — `GraphLoader.load()` bundle fallback + corrupt-file cleanup; `TransitGraph.version` type; `CommuteViewModel.calculateRoute` analytics call
- `AnalyticsService.swift` / `APIEndpoint.swift` — payload field/unit alignment (whichever side moves)
- `LoginView.swift` — display the carried server message (text change only; no layout work in this pass)
- `transit_graph_v3.json` — `version` migrated to the canonical scheme (only if Int is chosen)

**Rails (`/Users/obiee/Desktop/proj/commutebeh-rails/` — separate repo, authoritative copy):**
- `app/controllers/api/v1/analytics_controller.rb` — accept the `event` envelope, correct field names/units, warn-log with params
- `app/models/route_plan_event.rb` (+ migration if `line_ids`/seconds column added)
- `app/controllers/api/v1/routes_controller.rb` — remove nonexistent `open_time`/`close_time` from the Edge query
- `app/controllers/api/v1/auth/sessions_controller.rb` + `registrations_controller.rb` — add `home_station_id` to payloads; optionally JSON failure app config in `config/initializers/devise.rb`
- `app/controllers/api/v1/graph_controller.rb` and/or `app/services/graph_service.rb` — unwrapped graph payload (if server-side unwrap chosen); version/peak-hour payload shape
- `app/controllers/api/v1/admin/stations_controller.rb`, `app/models/station.rb` — **already specified in polyline-audit.md Issue 3**; implement from there

---

## Open questions / assumptions

- **`peak_hour_configs.data` shape in the production DB is unverified** (schema check was not completed in this session). If it isn't exactly `{morningPeak, eveningPeak, trainPeak}` each with `{timeRange:{start,end}, travelTimeMultiplier, modes}`, the `/graph` payload fails `TransitGraph` decode even after the R2 envelope fix. Verify with one `curl …/api/v1/graph | jq '.data.peakHourMultipliers'` before shipping the sync fix. Same caveat for `edges.polyline_coordinates` jsonb element shape (assumed `[{lat,lng}]`, seeded from the bundle) and for `transport_modes.notes`/`extra` and `payment_methods.notes` columns feeding non-optional iOS `notes: String` fields.
- **Live sign-in success payload not captured** (no test credentials used); the success shape is asserted from controller code, which is unambiguous, but a captured pair would harden the L1 fix's test fixture.
- **Rails param wrapping** was reasoned from the absence of `config/initializers/wrap_parameters.rb`, not runtime-verified; it does not change A2's conclusion (the controller reads keys iOS never sends under any wrapping behavior).
- **Dead code intent**: `RouteService` (stations/routes/saved-routes), `IncidentService`, and the `register`/`updateMe`/`me`/`deleteAccount` endpoints have no UI call sites. This audit assumes they're future features, not orphans — fixes above only cover what blocks their eventual wiring (R3); deciding to delete them is a product call.
- **Versioning scheme decision** (Int counter vs semver string) is the one genuine fork in the routing fix; this audit recommends the server's Int counter but either works if applied to *both* sides and the bundle.
- The deployed server was assumed to match the authoritative repo at audit time (live 500 on `/routes` and Int `version` both match the code, supporting this).
- Cold-start latency (~44 s) vs the 60 s default URLSession timeout is flagged under Login but applies to every endpoint; a keep-warm ping or raised timeout is an ops decision outside this contract audit.
