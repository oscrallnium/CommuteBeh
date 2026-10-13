# 10. Development Guide

## Prerequisites

| For | Need |
|---|---|
| iOS | macOS, Xcode 16+ (Swift 6 / Swift Testing), an iOS 26 simulator |
| Backend | Ruby 3.4, Postgres with `pg_trgm`, Redis (optional locally) |

## iOS

```bash
cd /Users/obiee/Desktop/proj/CommuteBeh

# Build
xcodebuild -project Gora.xcodeproj -scheme Gora \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# Run tests (see caveat below)
xcodebuild -project Gora.xcodeproj -scheme Gora \
  -destination 'platform=iOS Simulator,name=iPhone 17' test

# One test
xcodebuild -project Gora.xcodeproj -scheme Gora \
  -destination 'platform=iOS Simulator,name=iPhone 17' test \
  -only-testing:GoraTests/SuiteName/testMethodName
```

No SPM packages, no CocoaPods, no linter. Opening `Gora.xcodeproj` and pressing ⌘R is the
whole setup.

> **There is no `GoraTests` target in the project today** — `project.pbxproj` contains
> zero references to it. The `test` commands above will fail until someone adds it
> (File → New → Target → Unit Testing Bundle, Testing System = **Swift Testing**, not XCTest).
> `.claude/skills/swift-testing.md` documents the intended conventions.

### Pointing at a local backend

`Gora/Networking/APIConfig.swift`:

```swift
enum APIConfig {
    static let baseURL = "https://commute-backend-a6lj.onrender.com"
    // static let baseURL = "http://localhost:3000"
}
```

Swap the comment. Note that iOS blocks cleartext HTTP by default — a simulator hitting
`localhost` works, but a device needs an ATS exception.

### Clearing device state

The graph, station cache, profile and token all persist. To simulate a first launch:

- **Simulator** → Device → Erase All Content and Settings, or delete the app.
- Targeted: the graph is `Documents/transit_graph_v3.json`, the search cache is
  `Documents/stations_cache.json`, the profile is `UserDefaults` key
  `com.banaueinc.gora.userProfile`, the token is in the Keychain.

A corrupt graph cache is *not* fatal — `GraphLoader.ensureLoaded()` treats a decode failure the
same as a missing file and re-downloads. But with no network there is no bundle to fall back to.

### Logging

```bash
# Graph OTA sync
log stream --predicate 'subsystem == "com.banaueinc.gora" AND category == "GraphSync"'

# Walk refinement / MKDirections — why a walk leg lost its geometry
log stream --predicate 'category == "Directions"'
```

The `Directions` category exists specifically because walk refinement is invisible when it works
and leaves a bare gap when it doesn't. It logs which happened, per leg.

## Backend

```bash
cd /Users/obiee/Desktop/proj/commutebeh-rails

bundle install
bin/rails db:create db:migrate
bin/rails server                 # → http://localhost:3000

bundle exec rspec                # request + service specs
bundle exec rubocop              # rubocop-rails
```

`.env` (via `dotenv-rails`, development/test only):

```
DATABASE_URL=postgres://localhost/commutebeh_development
DEVISE_JWT_SECRET_KEY=<any long random string>
REDIS_URL=redis://localhost:6379/0     # optional — cache degrades gracefully
ALLOWED_ORIGINS=http://localhost:3000
```

### Seeds do not run on deploy — and shouldn't be relied on locally either

Render's pipeline runs `db:migrate` only. Anything the app requires to *function* must live in a
migration. Migration `011_bootstrap_admin_and_graph_meta.rb` exists because production shipped
with an empty `graph_meta` and no admin user.

Bootstrapped accounts (development convenience — rotate anything reused in production):

| Email | Role |
|---|---|
| `admin@commutebeh.ph` | admin |
| `oscar@agiledigital.com.ph` | admin (developer account) |

### Test suites present

```
spec/requests/api/v1/routes_spec.rb
spec/requests/api/v1/analytics_spec.rb
spec/requests/api/v1/admin/{edges,graph_routes,stations}_spec.rb
spec/services/graph_service_insert_stop_polyline_spec.rb
spec/services/graph_service_stop_editing_spec.rb
spec/support/auth_helpers.rb
```

The two `graph_service` service specs are the ones to read first — they encode the stop
insert/remove rules described in [9](09-authoring-and-admin.md#insert--remove-stop--the-three-rules).

## Conventions

### Swift file header

Line 1 of every new `.swift` file, before any `import`, with the **actual creation date** in
`M/D/YY` and no leading zeros:

```swift
//
//  FileName.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/10/26.
//
```

App name is **Gora**, author is **Oscar Allen Brioso**.

### Architecture

- ViewModels: `@Observable @MainActor final class`, held as `@State private var vm = …`.
  Never `ObservableObject` / `@StateObject` / `@Published`.
- Models: immutable `Codable` value types.
- Heavy CPU work belongs behind an `actor`.
- The domain layer (`Domain/TransportMode.swift`) imports `Foundation` and `CoreLocation` only —
  **never MapKit, never the networking layer**.
- Use `TransportMode.color` / `.icon` / `.lineWidth` from `Design/DesignTokens.swift`. Don't
  re-derive mode styling locally.

### Data

- No hardcoded station names, fares, coordinates, mode strings or payment strings in Swift.
- Never hardcode `"walk"` in routing logic — derive from `isAlwaysAllowed` in the graph.
- New graph fields: `decodeIfPresent` with a safe default, and bump the server graph version.
- Watch the case boundary: the graph document is camelCase, every other endpoint is snake_case.

## Adding things — quick recipes

### A new API endpoint

1. Rails: route in `config/routes.rb` (add the `GRAPH_ID` constraint + `format: false` if the
   path carries a graph ID), controller action, `json_response`.
2. iOS: a case in `APIEndpoint` with its `path` / `method` / `body`.
3. iOS: a DTO in `APIModels.swift` if the response shape is new.
4. iOS: a method on the relevant service in `Services/`.
5. If it mutates the graph: call `bust_graph_cache!` and bump the version.

### A new transport mode

Entirely data. Insert a `transport_modes` row (`id`, `display_name`, `color_hex`,
`is_user_selectable`, `is_always_allowed`, `default_accepted_payments`, …) and bump the graph
version. The engine picks it up on the next sync — **unless** it needs bespoke SwiftUI styling,
in which case add cases to the `TransportMode` extension in `DesignTokens.swift`.

### A field on `Station` or `TransitEdge`

1. Rails migration.
2. `as_api_json` on the model (snake_case) **and** `GraphService#station_json` / `#edge_json`
   (camelCase). Both, or the field silently vanishes on OTA sync — this has happened before with
   `interchangesWith`.
3. Swift struct in `Domain/TransportMode.swift`, decoded with `decodeIfPresent` + default.
4. Migration bumping the graph version so clients re-pull.

## Repository state

The iOS repo root holds a large collection of `FEATURE_*.md`, `BUG_*.md`, `FINDINGS_*.md`,
`HOWTO_*.md` and `*_AUDIT.md` working documents, plus `.claude/audits/`. They are point-in-time
investigation notes, not maintained specifications — useful for archaeology, unreliable as
current truth. This `docs/` directory is the maintained set.
