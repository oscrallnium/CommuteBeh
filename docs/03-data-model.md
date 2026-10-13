# 3. Data Model

The transit graph exists in two representations that must stay in lockstep:

- **Postgres**, normalised — the authoring source of truth, in `commutebeh-rails`.
- **JSON**, denormalised — one document assembled by `GraphService.assemble_graph`, served by
  `GET /api/v1/graph`, cached on device and decoded into Swift structs.

## Entity relationships (Postgres)

```mermaid
erDiagram
    GRAPH_META ||--o{ STATIONS : versions
    STATIONS ||--o{ STATION_ACCESS_POINTS : "has doors"
    STATIONS ||--o{ INCIDENTS : "reported at"
    STATIONS ||--o{ AR_WORLD_MAPS : "anchored at"
    STATIONS }o--|| LINES : "belongs to"
    EDGES }o--|| LINES : "belongs to"
    EDGES }o--|| STATIONS : from_station
    EDGES }o--|| STATIONS : to_station
    LINES }o--|| TRANSPORT_MODES : mode
    TRANSPORT_MODES ||--o{ PAYMENT_METHODS : accepts
    LINES ||--o| FARE_MATRIX : "fare rules"
    USERS ||--o{ SAVED_ROUTES : saves
    USERS ||--o{ ROUTE_PLAN_EVENTS : generates
    USERS ||--o{ AR_WORLD_MAPS : uploads
    USERS }o--o| STATIONS : home_station

    GRAPH_META {
        int version PK "bumped on every mutation"
        datetime last_modified
        string schema_version "3.0.0"
        string region "Metro Manila, Philippines"
        string currency "PHP"
        bool enforce_operating_hours
    }
    STATIONS {
        string station_id PK "TEXT — e.g. MRT_NORTH_AVE"
        string name
        string short_name
        string line FK
        string type "= mode id"
        decimal lat "precision 10, scale 7"
        decimal lng
        bool is_terminal
        bool is_interchange
        string_array amenities
        string open_time "HH:mm"
        string close_time "HH:mm"
    }
    STATION_ACCESS_POINTS {
        string access_point_id PK
        string station_id FK
        string name
        string kind "entrance | exit | both"
        string direction "northbound | southbound | NULL"
        decimal lat
        decimal lng
        int position
    }
    EDGES {
        string edge_id PK
        string from_station FK
        string to_station FK
        string mode
        string line FK
        decimal travel_time_minutes
        decimal distance_km
        decimal base_fare
        decimal fare_per_km
        string_array accepted_payments
        bool is_air_conditioned
        decimal crowd_factor "0–1"
        decimal reliability "0–1"
        bool bidirectional
        string direction "nullable"
        jsonb polyline_coordinates
        string mk_directions_transport_type
        bool is_road_snapped
    }
    TRANSPORT_MODES {
        string id PK "train | bus | jeepney | tricycle | walk"
        string display_name
        string plural_name
        string sf_symbol
        string color_hex
        decimal map_line_width_pt
        jsonb map_line_dash
        bool is_user_selectable
        bool is_always_allowed
        string_array lines
        string_array default_accepted_payments
        int position
    }
    PAYMENT_METHODS {
        string id PK "cash | beep_card | gcash | maya | card"
        string display_name
        string sf_symbol
        string color_hex
        bool is_default
        string_array accepted_by_modes
    }
    LINES {
        string id PK "MRT-3 | UPLB_KANAN | …"
        string display_name
    }
    FARE_MATRIX {
        string line_name PK
        string type "flat | distance"
        jsonb data
    }
    USERS {
        uuid id PK
        string email UK
        string encrypted_password
        string display_name
        int role "0 commuter | 1 admin"
        string jti "JWT revocation"
        string home_station_id FK
    }
    SAVED_ROUTES {
        uuid id PK
        uuid user_id FK
        string name
        string origin_station_id
        string destination_station_id
        jsonb legs
    }
    ROUTE_PLAN_EVENTS {
        uuid id PK
        uuid user_id FK
        string origin_station_id
        string destination_station_id
        jsonb legs
        int total_time_minutes
        string_array modes_used
        datetime occurred_at
    }
    AR_WORLD_MAPS {
        uuid id PK
        string station_id FK
        int version
        int status "pending | approved | rejected"
    }
```

### Primary key convention

`stations`, `edges`, `station_access_points`, `transport_modes`, `payment_methods`, `lines` and
`fare_matrix` all use **author-supplied TEXT primary keys**, not surrogate integers. This is
deliberate: the ID is part of the data contract with the client and appears in URLs, saved
routes and analytics rows.

Consequences worth knowing:

- Rails models declare `self.primary_key` explicitly (`app/models/station.rb:2`).
- `Station` and `Edge` set `self.inheritance_column = nil` because both have a real `type`
  column that has nothing to do with STI.
- IDs can contain dots — hence the `GRAPH_ID` router constraint (see
  [2. Architecture](02-architecture.md#server-request-pipeline)).
- There is **no DB-level FK** from `saved_routes` / `route_plan_events` / `ar_world_maps` /
  `incidents` to a station ID. Stop renumbering can therefore orphan those references — an
  accepted tradeoff documented at `app/services/graph_service.rb:344`.

## The JSON document

`GET /api/v1/graph` returns this shape (assembled at `app/services/graph_service.rb:626`,
decoded by `TransitGraph` at `Domain/TransportMode.swift:292`):

```jsonc
{
  "version": 42,                       // Int from server; String once re-encoded locally
  "lastModified": "2026-08-10T09:12:33Z",
  "enforceOperatingHours": true,
  "metadata": {
    "region": "Metro Manila, Philippines",
    "currency": "PHP",
    "schemaVersion": "3.0.0",
    "polylineNote": "polylineCoordinates define the static display shape of each edge…"
  },
  "transportModes": { "train": { …TransportModeConfig }, "walk": { … } },
  "paymentMethods": { "cash": { …PaymentMethodConfig } },
  "lines":          { "MRT-3": { "id": "MRT-3", "displayName": "MRT-3"} },
  "peakHourMultipliers": {
    "morningPeak": { "startHour": 6, "endHour": 9, "multiplier": 1.4, "appliesTo": ["bus","jeepney"] },
    "eveningPeak": { … },
    "trainPeak":   { … }
  },
  "fareMatrix": { "MRT-3": { … } },
  "stations": [{ …Station } ],
  "edges":    [{ …TransitEdge } ]
}
```

### Decoding tolerances

`TransitGraph.init(from:)` is deliberately forgiving, because a cached graph on a user's device
may predate a schema addition:

| Field | Tolerance | Reason |
|---|---|---|
| `version` | `Int` **or** `String` | Server emits Int; local re-encode emits String |
| `lines` | missing → `[:]` | Added after the first shipped graphs; missing entry falls back to the raw line ID |
| `enforceOperatingHours` | missing → `true` | Backwards-compatible default |

Add new graph fields the same way — `decodeIfPresent` with a safe default. A required field
added carelessly bricks every cached graph in the field, because `GraphLoader` has no bundle
fallback to recover to.

### Key naming

The server emits **camelCase inside the graph document** (`GraphService#station_json` /
`#edge_json`), so `GraphLoader` decodes it with a plain `JSONDecoder`. Every *other* endpoint
is snake_case and goes through `APIClient`'s `.convertFromSnakeCase` decoder. Both conventions
are live simultaneously — check which side of the line you're on before adding a field.

## Swift domain types

```mermaid
classDiagram
    class TransitGraph {
        +String version
        +[Station] stations
        +[TransitEdge] edges
        +PeakHours peakHourMultipliers
        +[String:TransportModeConfig] transportModes
        +[String:PaymentMethodConfig] paymentMethods
        +[String:LineConfig] lines
        +Bool enforceOperatingHours
    }
    class Station {
        +StationID id
        +String name
        +String line
        +Coordinates coordinates
        +Bool isTerminal
        +Bool isInterchange
        +OperatingHours operatingHours
        +[StationAccessPoint] accessPoints
        +accessPoint(kind:direction:near:)
    }
    class StationAccessPoint {
        +String id
        +String name
        +Kind kind
        +String? direction
        +Coordinates coordinates
    }
    class TransitEdge {
        +String id
        +StationID from
        +StationID to
        +String mode
        +String line
        +Double travelTimeMinutes
        +Double distanceKm
        +Double baseFare
        +Double farePerKm
        +Bool bidirectional
        +String? direction
        +[Coordinates] polylineCoordinates
        +Bool isRoadSnapped
    }
    class RouteResult {
        +[RouteLeg] legs
        +Double totalTimeMinutes
        +Double totalFare
        +Double totalDistanceKm
        +Int transfers
        +[TransportMode] modes
    }
    class RouteLeg {
        +UUID id
        +Station fromStation
        +Station toStation
        +TransportMode mode
        +String line
        +[Station] stops
        +Double fare
        +[Coordinates] polylineCoordinates
        +String instruction
        +[RawStep] rawSteps
    }
    class RouteOption {
        +UUID id
        +RouteResult result
        +Label label
    }

    TransitGraph "1" *-- "many" Station
    TransitGraph "1" *-- "many" TransitEdge
    Station "1" *-- "many" StationAccessPoint
    RouteResult "1" *-- "many" RouteLeg
    RouteOption "1" *-- "1" RouteResult
```

`RouteLeg.id` is a transient `UUID()` generated per search — **every other ID in the system
comes from the data**. `RouteOption.id` is likewise a `UUID`, but it is deliberately *carried
through* the walk-refinement rebuild so that selection state and card layout survive
(`Domain/TransportMode.swift:489`).

## Reserved line identifiers

Two line values are control flags rather than real services:

| Value | Meaning | Behaviour |
|---|---|---|
| `INTERCHANGE` | A recorded transfer walk between two stations | Never merged into a ride leg; skips fare and operating-hours checks |
| `ACCESS_WALK` | Synthetic walk from a coordinate endpoint to a stop | Generated at search time, never stored; cost is multiplied by `AccessPolicy.discomfortFactor` |

## Invariants

These hold across both tiers. Breaking one produces subtle, hard-to-trace bugs.

1. **No hardcoded transit data in Swift.** Station names, fares, coordinates, mode strings and
   payment strings all come from the graph.
2. **`alwaysAllowedModes` is derived from data**, not from the literal `"walk"` — the engine
   reads `isAlwaysAllowed: true` out of `transportModes` at init
   (`Domain/TransportMode.swift:723`).
3. **Polyline stitching drops the first coordinate of each subsequent segment** — it duplicates
   the shared junction point.
4. **A stitched leg's polyline endpoints are pinned to the boarding/alighting station
   coordinates**, overriding whatever the stored geometry said. Live data drifts, and the map
   draws pins from station coordinates; a mismatch renders as a visible gap.
5. **Fare is computed once per leg** (single boarding), never summed per edge — that is what
   makes distance-bracketed rail fares come out right.
6. **`isTerminal` is assigned server-side** from stop index, never trusted from a client.
7. **Reverse edges are synthetic.** A `bidirectional` edge produces one stored row and one
   in-memory reverse at engine init, with the polyline reversed and the direction label
   flipped (`northbound` ⇄ `southbound`).
