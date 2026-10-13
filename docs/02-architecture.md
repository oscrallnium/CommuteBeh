# 2. Architecture

## System context

```mermaid
graph TB
    subgraph Device["iOS device"]
        UI["SwiftUI views<br/>Commute · Explore · Record · Admin · Settings"]
        VM["RouteStore<br/><i>@Observable @MainActor</i>"]
        ENG["TransitGraphEngine<br/><i>actor · A* search</i>"]
        CACHE[("Documents/<br/>transit_graph_v3.json<br/>stations_cache.json")]
        KC[("Keychain<br/>JWT")]
        GW["DirectionsGateway<br/><i>actor · rate limiter</i>"]
    end

    subgraph Apple["Apple platform services"]
        MK["MKDirections<br/>MKLocalSearch"]
        CL["CoreLocation"]
    end

    subgraph Render["Render — Singapore"]
        API["commutebeh-rails<br/>Rails 7.1 API · Puma"]
        RC[("Redis<br/>cache")]
    end

    SB[("Supabase Postgres<br/>graph + users + events")]
    S3[("Supabase S3<br/>AR world maps")]

    UI <--> VM
    VM <--> ENG
    VM --> GW
    ENG -.reads at init.-> CACHE
    GW --> MK
    VM --> CL
    VM -->|HTTPS + Bearer JWT| API
    KC -.->|token| API
    API --> SB
    API --> RC
    API --> S3
    API -->|graph JSON| CACHE

    style ENG fill:#1f7a4d,color:#fff
    style API fill:#8b2635,color:#fff
    style SB fill:#3a3a6b,color:#fff
```

Two things to internalise from this diagram:

1. **Routing is entirely client-side.** The server never computes a path. It is a graph
   authoring and distribution service plus an identity provider. This is why the app still
   routes with no connectivity once the graph is cached.
2. **The graph is not bundled.** `Gora/Resources/` is empty. The only copy on device is
   the one downloaded into `Documents/` (see [8. Graph Sync](08-graph-sync.md)).
   **Drift:** `CLAUDE.md` still describes a bundled `transit_graph_v3.json`.

## Cold start

```mermaid
sequenceDiagram
    autonumber
    participant App as GoraApp
    participant S as UserSession
    participant KC as Keychain
    participant API as Rails API
    participant GL as GraphLoader
    participant GS as GraphService
    participant E as TransitGraphEngine

    App->>S: init()
    S->>KC: load() token
    alt token + cached profile exist
        S-->>App: isLoggedIn = true (optimistic)
        S->>API: POST /api/v1/auth/refresh
        API-->>S: new token + user (JTI rotated)
    else no token
        S-->>App: show LoginView
    end

    App->>E: RouteStore.setupEngine()
    E->>GL: ensureLoaded("transit_graph_v3")
    alt Documents cache present & decodable
        GL-->>E: TransitGraph
    else missing or corrupt
        GL->>GS: fetchGraph()
        GS->>API: GET /api/v1/graph
        API-->>GS: { data: {...} }
        GS-->>GL: re-encoded camelCase Data
        GL->>GL: write to Documents
        GL-->>E: TransitGraph
    end
    E->>E: build adjacency (O(E)), synthesise reverse edges
    Note over E: isEngineReady = true
    E->>GS: syncIfNeeded(loadedVersion:)
```

Note the optimistic login at step 3: the UI shows the cached profile immediately and refreshes
the token behind it. If the refresh comes back 401, `UserSession.clearSession()` drops the user
back to `LoginView`.

## Concurrency model

Swift Concurrency throughout. No Combine, no `ObservableObject`.

| Type | Isolation | Why |
|---|---|---|
| `RouteStore` | `@MainActor` `@Observable final class` | Drives SwiftUI directly |
| `TransitGraphEngine` | `actor` | Immutable adjacency, but serialises search; keeps CPU work off main |
| `DirectionsGateway` | `actor` | Owns a single shared clock + cache for all MKDirections calls |
| `AccessPolicy` | `nonisolated enum` | Pure constants read from inside the engine's actor |
| Models (`Station`, `TransitEdge`, `RouteResult`, …) | immutable `Codable` structs | Freely `Sendable` across boundaries |

The three cost strategies are dispatched as concurrent child tasks:

```swift
async let r1 = engine.findRoute(req1)   // .fastest
async let r2 = engine.findRoute(req2)   // .cheapest
async let r3 = engine.findRoute(req3)   // .balanced
let (fr, cr, br) = await (r1, r2, r3)
```

They serialise through the actor's executor but the caller suspends once for all three
(`Domain/TransportMode.swift:1834`).

## The refinement pass

The single most distinctive piece of the runtime design: results are published *before* they
are accurate, then sharpened.

```mermaid
sequenceDiagram
    participant U as User
    participant VM as RouteStore
    participant E as Engine
    participant GW as DirectionsGateway
    participant MK as MKDirections

    U->>VM: tap Search
    VM->>E: findRoute × 3 strategies
    E-->>VM: RouteResults (straight-line walks)
    VM-->>U:  routes on screen (engine speed)
    VM->>VM: Task { refineWalkLegs() }
    loop each walk leg
        VM->>GW: path(from:to:urgency:.interactive)
        GW->>GW: cache hit? → return
        GW->>MK: MKDirections (paced ≥300 ms apart)
        MK-->>GW: real pedestrian polyline
    end
    VM-->>U:  legs redrawn with true distance/duration
    Note over VM: an access walk exceeding<br/>AccessPolicy.hardCeilingKm<br/>drops its entire route
```

Why it exists, from `Services/WalkRouteRefiner.swift:18`: a stop 400 m away across a river or a
walled campus is *a 400 m estimate and a 1.8 km reality*. Straight lines are fine as search
input, useless as walking instructions.

Why the gateway exists, from `Services/DirectionsGateway.swift:12`: Apple rate-limits
MKDirections at roughly 50/60 s per app, and once exceeded it reports
`MKError.directionsNotFound` — indistinguishable from "there is genuinely no path here".
Explore's road-snapping pass could burn the whole quota in seconds and silently strip geometry
off every walk leg in a search the user was waiting on. One actor now paces every caller, with
`.interactive` (300 ms spacing) prioritised over `.background` (1200 ms).

## Server request pipeline

```mermaid
graph LR
    R[Request] --> CORS[rack-cors]
    CORS --> RA[rack-attack<br/>rate limit]
    RA --> RT[Rails router<br/>GRAPH_ID constraint]
    RT --> AC{authenticate_user!}
    AC -->|public: graph, stations, routes| CTRL
    AC -->|401| E401[Unauthorized]
    AC -->|valid JWT| ADM{require_admin!}
    ADM -->|403| E403[Forbidden]
    ADM -->|ok| CTRL[Controller]
    CTRL --> CACHE{Rails.cache}
    CACHE -->|hit| RESP
    CACHE -->|miss| GS[GraphService]
    GS --> PG[(Postgres)]
    PG --> RESP["{ data: …, meta: … }"]

    style E401 fill:#8b2635,color:#fff
    style E403 fill:#8b2635,color:#fff
```

The `GRAPH_ID = /[^\/]+/` router constraint deserves a note. Graph IDs are author-supplied and
can contain dots — the line `STACRUZ.LRT_BUENDIA`, for instance. Rails' default dynamic segment
stops at a dot and hands the rest to `:format`, so
`DELETE /admin/graph/routes/STACRUZ.LRT_BUENDIA` arrived as `line_id: "STACRUZ"`,
`format: "LRT_BUENDIA"` — deleting nothing while reporting success. Every route carrying a
graph ID now uses this constraint plus `format: false` (`config/routes.rb:15`).

## Layering rules

```mermaid
graph TD
    V["Views<br/><i>SwiftUI only</i>"] --> VMs["RouteStore / ExploreViewModel"]
    VMs --> D["Domain<br/><i>TransportMode.swift</i>"]
    VMs --> SVC["Services<br/><i>Auth · Graph · Route · Admin · Analytics</i>"]
    SVC --> NET["Networking<br/><i>APIClient · APIEndpoint</i>"]
    D -.->|never| NET
    D -.->|never| MK[MapKit]
    SVC --> MK

    style D fill:#1f7a4d,color:#fff
```

The domain layer imports `Foundation` and `CoreLocation` only. MapKit is deliberately kept out
of it — this is why walk refinement lives in `Services/WalkRouteRefiner.swift` as an extension
on `RouteStore` rather than inside the engine.
