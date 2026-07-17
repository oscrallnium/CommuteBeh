# CommuteBeh Backend & iOS Integration Audit

**Date:** 2026-07-02
**Auditor:** Claude (automated code + live-service audit)
**Live backend:** `https://commute-backend-a6lj.onrender.com` (Render, Singapore region)
**Backend source of truth:** `/Users/obiee/Desktop/proj/commutebeh-rails` (Rails 7.1 API-only)
**iOS app:** `/Users/obiee/Desktop/proj/CommuteBeh` (SwiftUI, iOS 26+)

---

## 0. Executive Summary

The backend is **deployed, healthy, and its database is connected** (verified live: `/health` returns `db: connected`, graph has 60 stations / 76 edges intact). Core read endpoints (`/graph`, `/graph/version`, `/stations`) work and are fast (~100–500 ms warm) with Brotli compression and caching in place.

However, there are **three confirmed production bugs** and several **security and cost issues** that need attention:

| Severity | Issue | Status |
|---|---|---|
| 🔴 Critical | `GET /api/v1/routes` returns **HTTP 500** (queries non-existent DB columns) | Confirmed live |
| 🔴 Critical | `GET /api/v1/routes/:line_id` returns **HTTP 500** (same root cause) | Confirmed live |
| 🔴 Critical | iOS admin "edit station" flow is **fully broken end-to-end** (3 independent defects) | Confirmed by code |
| 🟠 High | CORS is wide open (`Access-Control-Allow-Origin: *`) in production | Confirmed live |
| 🟠 High | `/api/v1/places` & `/api/v1/events` routed but **controllers don't exist** → 404/500 | Confirmed live |
| 🟠 High | iOS ↔ backend **response model mismatches** on stations, routes, incidents, graph version | Confirmed by code |
| 🟡 Medium | Default seeded admin password in repo; JWT lifetime 24h with no server-side expiry cleanup | Review |
| 🟡 Medium | `POST /analytics/route_plan` field-name mismatch between iOS and server | Confirmed by code |

**Two divergent backend copies exist on disk:** `commutebeh-rails` (the real, git-tracked, deployed service) and `commutebeh-merged` (an older/parallel copy). They differ in real ways (see §1.1). This audit treats **`commutebeh-rails` as authoritative** because it matches the deployed behavior and has git history.

---

## 1. Backend Architecture (as-built)

Single Rails 7.1 API-only service (the "merged" design in `CLAUDE.md` — Hono microservice was folded in). Stack as documented is accurate:

- **Framework:** Rails 7.1, API-only, Ruby ~> 3.4
- **Auth:** Devise + devise-jwt, JTI revocation via `jti` column on `users`
- **DB:** PostgreSQL (Supabase), UUID PKs (`pgcrypto`), TEXT PKs for graph tables
- **Storage:** Active Storage → Supabase S3 (`config.active_storage.service = :supabase` in production)
- **Cache/jobs:** Redis (`redis_cache_store`) + Sidekiq
- **Rate limiting:** Rack::Attack
- **Deploy:** Render (`render.yaml`, `plan: starter`, Singapore), `db:migrate` on boot

### 1.1 ⚠️ Two backend directories — reconcile before further work

`commutebeh-rails` and `commutebeh-merged` are **not** identical. Meaningful differences:

| Area | `commutebeh-rails` (deployed) | `commutebeh-merged` (stale copy) |
|---|---|---|
| Admin station edit | Has `admin/stations_controller.rb` + route | **Missing** |
| `BaseController` JTIMatcher | Removed (commit `975d02f`) | Still includes it |
| Active Storage (app.rb) | `:local` in `application.rb`, `:supabase` in prod env | `:supabase` in `application.rb` |
| HTTP 422 symbol | `:unprocessable_content` | `:unprocessable_entity` |
| Gems | adds `jsonapi-serializer`, `redis`, `rails_12factor` | no `redis` gem |

**Recommendation:** Delete or archive `commutebeh-merged` to prevent editing the wrong tree. All fixes below reference `commutebeh-rails`.

---

## 2. API Endpoint Reference

Base URL: `https://commute-backend-a6lj.onrender.com`
Auth header (when required): `Authorization: Bearer <jwt>` · `Content-Type: application/json`
All success responses are wrapped in `{ "data": ... }`. List endpoints add `{ "meta": {...} }`.

### 2.1 Auth (no `/api/v1` prefix)

| Method | Path | Auth | Body | Notes |
|---|---|---|---|---|
| POST | `/auth/register` | None | `{ user: { email, password, password_confirmation, display_name } }` | → 201 `{ data: { token, user } }` |
| POST | `/auth/sign_in` | None | `{ user: { email, password } }` | → 200 `{ data: { token, user } }`; 401 on bad creds |
| DELETE | `/auth/sign_out` | Bearer | — | Revokes JTI |
| POST | `/api/v1/auth/refresh` | Bearer | — | Rotates JTI, returns new token |
| DELETE | `/api/v1/auth/account` | Bearer | — | App Store account deletion |

**`user` payload shape (all auth responses):** `{ id, email, display_name, role }`. Note `role` is `"commuter"` or `"admin"` (the API doc `doc/api.md` incorrectly says `"user"`).

### 2.2 User

| Method | Path | Auth | Body |
|---|---|---|---|
| GET | `/api/v1/me` | Bearer | — → `{ id, email, display_name, role, home_station_id, created_at }` |
| PATCH | `/api/v1/me` | Bearer | `{ user: { display_name?, home_station_id? } }` |

### 2.3 Transit graph (public / no auth)

| Method | Path | Cache | Notes |
|---|---|---|---|
| GET | `/api/v1/graph/version` | 30 s | `{ data: { version:Int, lastModified, stationCount, edgeCount } }` |
| GET | `/api/v1/graph` | 5 min | Full graph JSON (same shape as `transit_graph_v3.json`); ~55 KB, Brotli-compressed |
| GET | `/api/v1/stations` | 1 h | Filters: `?line=`, `?type=`, `?interchange=true`, `?search=` |
| GET | `/api/v1/stations/:id` | — | Single station |
| 🔴 GET | `/api/v1/routes` | 30 min | **BROKEN — HTTP 500** (see §3.1) |
| 🔴 GET | `/api/v1/routes/:line_id` | — | **BROKEN — HTTP 500** (see §3.1) |

**Station API shape** (`Station#as_api_json`): `{ id, name, short_name, line, type, coordinates: {lat,lng}, is_terminal, is_interchange, amenities, operating_hours: {open,close} }`.

### 2.4 Authenticated user features

| Method | Path | Auth | Body |
|---|---|---|---|
| GET | `/api/v1/saved_routes` | Bearer | — |
| POST | `/api/v1/saved_routes` | Bearer | `{ saved_route: { name, origin_station_id, destination_station_id, legs:[{line_id,mode,from_station,to_station,travel_time_minutes}] } }` |
| DELETE | `/api/v1/saved_routes/:id` | Bearer | — |
| GET | `/api/v1/incidents` | Bearer | Active incidents, max 50 |
| POST | `/api/v1/incidents` | Bearer | `{ incident: { station_id, line_id?, category, description } }` |
| POST | `/api/v1/analytics/route_plan` | Bearer | `{ origin_id, destination_id, legs, total_time_minutes, modes_used }` — always 201 |
| GET | `/api/v1/ar_world_maps` | Bearer | Filters `?station_id=`, `?status=`; paginated |
| GET | `/api/v1/ar_world_maps/:id` | Bearer | Includes `download_url` |
| POST | `/api/v1/ar_world_maps` | Bearer | multipart: `station_id`, `map_file` (≤150 MB) |
| POST | `/api/v1/ar_world_maps/:id/relocalize` | Bearer | `{ accuracy, device }`; 100-event ring buffer |

### 2.5 Admin (role = `admin`)

| Method | Path | Body |
|---|---|---|
| GET | `/api/v1/admin/users` | List |
| GET/DELETE | `/api/v1/admin/users/:id` | — |
| PATCH | `/api/v1/admin/stations/:id` | `{ station: { lat, lng } }` |
| GET/PATCH/DELETE | `/api/v1/admin/ar_world_maps[/:id]` | Approval workflow |
| GET/PATCH/DELETE | `/api/v1/admin/incidents[/:id]` | Moderation |
| POST | `/api/v1/admin/graph/routes` | RoutePayload (validates + inserts stations/edges) |
| DELETE | `/api/v1/admin/graph/routes/:line_id` | Removes a line |
| GET | `/api/v1/admin/analytics/summary` | DAU/WAU, top stations, mode share |
| GET | `/api/v1/admin/analytics/hotspots` | Top origins (30 d) |

### 2.6 Routed but NOT implemented (return 404/500)

- `GET /api/v1/places`, `GET /api/v1/places/:id`
- `GET /api/v1/events`, `GET /api/v1/events/:id`

`config/routes.rb` declares `resources :places` and `resources :events`, but **no `PlacesController` / `EventsController` exists**. Verified live: `/api/v1/places` → 404. Remove the routes or stub the controllers.

---

## 3. Confirmed Bugs

### 3.1 🔴 `/api/v1/routes` and `/api/v1/routes/:line_id` → HTTP 500

**Root cause (confirmed):** `RoutesController#index` runs:

```ruby
Edge.select(:line, :mode, :base_fare, :accepted_payments, :is_air_conditioned,
            :open_time, :close_time, :crowd_factor, :reliability)
    .group(:line, :mode, :base_fare, :accepted_payments, :is_air_conditioned,
           :open_time, :close_time, :crowd_factor, :reliability)
```

`open_time` and `close_time` **do not exist on the `edges` table** — per migration `009_create_graph_tables.rb` they are columns on **`stations`**. The query raises `PG::UndefinedColumn`, producing a 500. `#show` builds its response from `first_edge.open_time` / `first_edge.close_time` too, so it fails identically.

**Live proof:** `curl .../api/v1/routes` → `HTTP 500 (0 bytes)`; `curl .../api/v1/routes/MRT-3` → `HTTP 500`.

**Fix:** Remove `open_time`/`close_time` from the Edge select/group (they are station-level, not edge-level attributes). If route operating hours are wanted, join from `stations` or drop the fields. Also add a `rescue_from` for `ActiveRecord::StatementInvalid` in `ApplicationController` so DB errors return a JSON 500 instead of an empty body.

**Impact:** Any iOS/web feature calling `RouteService.routes()` fails. Currently the iOS app relies primarily on the bundled/`/graph` data, which is why the app still functions — but the endpoint is dead.

### 3.2 🔴 iOS admin "edit station coordinates" is broken 3 ways

The flow `AdminRoutesView → AdminService.updateStation → PATCH /api/v1/admin/stations/:id`:

1. **Server no-ops silently.** `Api::V1::Admin::StationsController#update` permits only `:lat, :lng` (`station_params`). But the iOS client (`APIEndpoint.updateStation`) sends `{ "station": { "latitude": ..., "longitude": ... } }`. `latitude`/`longitude` are not permitted params and there are no `lat`/`lng` keys → `@station.update({})` succeeds updating **nothing**. The pin move is discarded server-side.
2. **Client fails to decode the response.** `AdminService` decodes into `APIStation` (`stationId, name, latitude, longitude, lineIds, isTerminal`), but the server returns `Station#as_api_json` (`id, name, short_name, line, type, coordinates:{lat,lng}, ...`). Keys don't match → `APIError.decodingFailed` → the UI shows "Save failed."
3. **Local data never updates anyway.** Even on success, `updateStation` mutates only the in-memory `lineGroups`; it never writes back to the Documents `transit_graph_v3.json`, so the routing engine keeps the old coordinate.

**Fix:** (a) Align field names — either have iOS send `lat`/`lng` or have the controller permit `latitude`/`longitude` and map them. (b) Make `APIStation` match the server station shape (or introduce a dedicated decode type). (c) Persist the edit to the local graph file and post `TransitDataDidUpdate`.

### 3.3 🟠 iOS response models don't match server JSON (multiple)

`APIModels.swift` was written against a different (older/Hono) contract. With `APIClient`'s `.convertFromSnakeCase` decoder, several models will fail to decode real responses:

| Swift model | Expects | Server actually returns | Result |
|---|---|---|---|
| `APIStation` | `stationId, latitude, longitude, lineIds, isTerminal` | `id, coordinates:{lat,lng}, line, type, ...` | Decode failure |
| `APIRoute` | `lineId, name, color` | `line_id, mode, base_fare, stop_count, ...` (and endpoint is 500 anyway) | Decode failure |
| `Incident` | `stationId, description, category, reportedAt` | `station_id, ..., created_at` (no `reportedAt`) | Decode failure |
| `SavedRoute` | `lineIds:[String]` | `legs:[{...}]` (no `line_ids`) | Decode failure |
| `GraphVersion` | `version: String`, `updatedAt` | `version: Int`, `lastModified` (no `updatedAt`) | **Type mismatch — decode failure** |

**`GraphVersion` is especially important:** `version` is decoded as `String` but the server sends an integer (`"version":1`). This breaks `GraphService.currentVersion()` → `syncIfNeeded` silently returns on the `try?`, so **over-the-air graph updates never apply**. Additionally `syncIfNeeded` compares the remote integer version against the bundled graph's `version: "1.0.0"` string, which would never match even if decoding worked.

**Fix:** Regenerate `APIModels.swift` from the live `/graph` and endpoint responses. Standardize the graph version type (make the server emit a string, or the client decode an int) and make the bundled `transit_graph_v3.json` version comparable to the server's integer counter.

### 3.4 🟡 Analytics payload field mismatch

iOS `APIEndpoint.logRoutePlan` sends:
```json
{ "event": { "origin_station_id", "destination_station_id", "line_ids", "duration_seconds" } }
```
Server `AnalyticsController#route_plan` reads **top-level** `params[:origin_id]`, `params[:destination_id]`, `params[:legs]`, `params[:total_time_minutes]`, `params[:modes_used]`.

Because the controller rescues all errors and always returns 201 ("analytics never block"), **every logged event is written with null origin/destination/legs**. Analytics dashboards (DAU is fine, but top-origins / hotspots / mode-share) will be empty/garbage. Align the field names.

---

## 4. Security Vulnerabilities

| # | Severity | Finding | Detail & Fix |
|---|---|---|---|
| S1 | 🟠 High | **CORS wildcard in production** | Live response: `Access-Control-Allow-Origin: *`. `cors.rb` uses `ENV.fetch("ALLOWED_ORIGINS", "*")`, so `ALLOWED_ORIGINS` is unset on Render. Any website can call the API from a browser. **Fix:** set `ALLOWED_ORIGINS` to the web admin origin + the iOS custom scheme; never ship `*` with `expose: Authorization`. |
| S2 | 🟡 Med | **Default admin credentials in repo** | `db/seeds.rb` creates `admin@commutebeh.ph / Admin1234!`. Live sign-in with these returned 401 (good — either not seeded in prod or changed), but the credential is in git history. **Fix:** rotate; load admin password from ENV; never commit a real default. |
| S3 | 🟡 Med | **JWT lifetime 24 h, no rotation on read** | `jwt.expiration_time = 24.hours`. Tokens are single-JTI (one active token/user) which is good, but a leaked token is valid 24 h. iOS refreshes on launch only. **Fix:** shorten to ~1 h + rely on refresh; consider refresh-token rotation. |
| S4 | 🟡 Med | **SQL string interpolation in GraphService** | `array_append(lines, '#{line_id.gsub("'", "''")}')` builds raw SQL. `line_id` is regex-validated (`/\A[A-Z0-9_]+\z/`) so it's currently safe, but this is a fragile pattern. **Fix:** use parameterized `Arel`/bind values instead of manual quoting. |
| S5 | 🟡 Med | **`search` scope uses ILIKE string-interp** | `Station.search`: `where("name ILIKE :q ...", q: "%#{q}%")` — parameterized (safe from injection), but unbounded `%q%` with a trigram index is fine; no length cap on `q`. **Fix:** cap search length; already indexed via `gin_trgm_ops`. |
| S6 | 🟢 Low | **No email verification / password reset** | Devise mailer not configured (documented as not-built). Account takeover risk is low but registration is unverified. |
| S7 | 🟢 Low | **AR map `download_url` uses `rails_blob_url`** | Public-ish signed URL generation; ensure Supabase bucket is private and URLs are expiring. Verify `Rails.application.routes.default_url_options[:host]` is set in prod or URLs will be malformed. |
| S8 | 🟢 Low | **`request.parsed_body || params.to_unsafe_h`** in admin graph create | `to_unsafe_h` bypasses strong params, but the route is admin-gated and `GraphService.validate` sanitizes. Acceptable, but prefer explicit permitting. |

**Good security practices already present:** JTI-based token revocation; Keychain storage on iOS with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; Rack::Attack throttles (auth 10/20s, per-email 5/5min, API 60/min, analytics 30/min); admin endpoints gated by `require_admin!`; `.env` gitignored; parameterized queries for user-facing search.

---

## 5. Cost & Runtime Optimization

Current warm graph latency is good (~100–500 ms, Brotli, ETag, Redis caching). Observations and opportunities:

### 5.1 Cold starts (biggest cost/UX lever)
- Live `/health` took **44 s** on first hit — the Render **`starter` plan spins down on idle**. First request after idle is very slow.
- **Options:** (a) keep-warm ping (UptimeRobot every 5–10 min — cheap/free); (b) upgrade to a plan without spin-down if user traffic warrants; (c) since the graph is bundled in the app, the iOS app already works offline-first, so cold starts mainly hurt auth/saved-routes. Prioritize keep-warm for `/health`.

### 5.2 Reduce redundant full-graph transfers
- iOS is *supposed* to poll `/graph/version` (cheap) and only fetch `/graph` (55 KB) on change — but §3.3 shows the version check is broken, so either the app never syncs or (if fixed naively) could re-fetch. **Fix the version comparison** so `/graph` is fetched only on actual version bumps. Add `ETag`/`If-None-Match` handling on the client to get 304s (server already emits ETags).
- `/graph` cache is 5 min and busted on admin writes — good. Consider raising to 30–60 min since writes already bust it.

### 5.3 Query efficiency
- `RoutesController#index` (once fixed) does **N+1**: `Station.where(line: e.line).count` inside a `.map` over grouped edges. Precompute stop counts with a single `Station.group(:line).count`. (CLAUDE.md lists "N+1 is a bug" as an invariant — this violates it.)
- `assemble_graph` loads all stations + edges every cache-miss; fine at 60/76 rows, revisit only if the graph grows large.
- Admin analytics `mode_share` does `.pluck(:modes_used).flatten.tally` in Ruby over all 7-day events — fine now, but will not scale. Consider a SQL `unnest` aggregation or a daily rollup table if event volume grows.

### 5.4 Right-sizing
- `RAILS_MAX_THREADS` defaults to 5; ensure DB `pool` ≥ threads (it reads the same ENV, OK).
- Sidekiq + Redis are provisioned but **no jobs exist** (`app/jobs` has only `ApplicationJob`). If nothing is enqueued, you're paying for a Redis instance and a worker dyno for nothing. **Either** remove the worker/Redis to cut cost, **or** move analytics writes and graph-cache warming into Sidekiq. Redis is still used as the Rails cache store + Rack::Attack store, so keep Redis but consider dropping the idle `worker` process until a real job exists.

### 5.5 Payload
- Station/edge JSON includes `polyline_coordinates` (can be large). `/graph` is only 55 KB today so fine. If polylines grow, offer a `?fields=` slim variant for the version/summary use case.

---

## 6. iOS App — Can It Fulfill Its Purpose?

**Core purpose (offline multimodal routing): YES.** Routing runs fully on-device via the A* engine over the bundled `transit_graph_v3.json`. The app does not depend on the backend to compute or display routes, so the primary feature works even with the backend down. `GraphLoader` correctly prefers the Documents copy over the bundle, enabling OTA graph updates *in principle*.

**Backend-dependent features: PARTIALLY BROKEN.** Summary of the iOS↔backend contract:

| Feature | iOS path | Works? | Blocker |
|---|---|---|---|
| Login / register / refresh / logout | `AuthService` → `/auth/*` | ✅ Yes | Contract matches (`{data:{token,user}}`) |
| Session persistence + silent refresh | `UserSession` | ✅ Yes | Keychain + refresh on launch OK |
| Session-expired auto-logout | `.sessionExpired` notification | ⚠️ Dead code | Notification is **never posted** anywhere; `APIClient` throws `.unauthorized` but nothing broadcasts `.sessionExpired`. 401s won't force logout. |
| Fetch stations | `RouteService.stations()` | ❌ No | `APIStation` decode mismatch (§3.3) |
| Fetch routes | `RouteService.routes()` | ❌ No | Endpoint 500 (§3.1) + decode mismatch |
| Saved routes | `RouteService.saveRoute/…` | ❌ Likely no | `SavedRoute` model expects `line_ids`; server returns `legs`; create payload uses `line_ids` but server permits `legs` |
| Incidents | `IncidentService` | ❌ No | `Incident` decode mismatch (`reportedAt` vs `created_at`) |
| Analytics logging | `AnalyticsService` (fire-and-forget) | ⚠️ Silently wrong | Writes null fields (§3.4); never surfaces error by design |
| OTA graph sync | `GraphService.syncIfNeeded` | ❌ No | `GraphVersion.version` type mismatch (Int vs String) + version format mismatch (§3.3) |
| Admin edit station | `AdminService.updateStation` | ❌ No | Triple bug (§3.2) |

**Net:** authentication and on-device routing are solid; **nearly every data-exchange feature that parses a server response is broken by model drift**, and two of them (routes, admin station edit) are also broken server-side. The app "works" today mainly because it leans on bundled data and fire-and-forget analytics that swallow errors.

---

## 7. Prioritized Fix List

**P0 — Production-breaking, fix first**
1. `/api/v1/routes[/:line_id]` 500 — remove `open_time`/`close_time` from Edge query (§3.1).
2. Regenerate `APIModels.swift` to match live responses; fix `GraphVersion` type so OTA sync works (§3.3).
3. Fix admin station edit end-to-end (param names, decode type, local persistence) (§3.2).

**P1 — Security & correctness**
4. Set `ALLOWED_ORIGINS` in Render; stop shipping CORS `*` (§S1).
5. Fix analytics field names so dashboards get real data (§3.4).
6. Post `.sessionExpired` on 401 in `APIClient` so auto-logout works (§6).
7. Remove or implement `places`/`events` routes (§2.6).

**P2 — Cost, hygiene, hardening**
8. Add keep-warm ping to `/health`; fix N+1 in routes index (§5.1, §5.3).
9. Decide on Sidekiq/worker: use it or drop the idle worker to cut cost (§5.4).
10. Rotate seeded admin credential; move to ENV; shorten JWT TTL (§S2, §S3).
11. Delete the stale `commutebeh-merged` tree to avoid editing the wrong backend (§1.1).
12. Add `rescue_from ActiveRecord::StatementInvalid` for JSON 500s (§3.1).

---

## 8. Verification Evidence (live, read-only)

```
GET /health                → 200  {"status":"ok","db":"connected","env":"production"}  (44s cold, then fast)
GET /api/v1/graph/version  → 200  {"version":1,"stationCount":60,"edgeCount":76}
GET /api/v1/graph          → 200  55,841 bytes, Brotli, ETag present, x-runtime 1.77s (miss) / ~0.1–0.5s (hit)
GET /api/v1/stations       → 200  15,670 bytes
GET /api/v1/routes         → 500  (0 bytes)                ← BUG §3.1
GET /api/v1/routes/MRT-3   → 500                            ← BUG §3.1
GET /api/v1/places         → 404                            ← §2.6
GET /api/v1/incidents      → 401 (auth required)            ← correct
POST /auth/sign_in (seed)  → 401 (default creds rejected)   ← good
CORS Origin: evil.example  → Access-Control-Allow-Origin: * ← BUG §S1
```

Graph data integrity check (live `/graph`): no stations at (0,0), no zero-fare non-walk lines, no empty polylines, every edge `line` present in `transportModes.lines`, fareMatrix covers MRT-3/LRT-1/LRT-2. **Database content is healthy.**
