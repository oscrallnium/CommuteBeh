# CLAUDE-backend.md — CommuteBeh API Service

Backend service that exposes one write endpoint: add a new transit route to `transit_graph_v3.json`. Route-finding (A\*) is not part of this service yet.

All data models are derived directly from `CommuteBeh/CommuteBeh/TransportMode.swift` and `CommuteBeh/CommuteBeh/transit_graph_v3.json`.

## Project

**commutebeh-api** — TypeScript/Node.js REST API.

- Runtime: Node.js 20+
- Framework: [Hono](https://hono.dev)
- Language: TypeScript (strict)
- Data: reads and writes `transit_graph_v3.json` — no database

```
commutebeh-api/
├── src/
│   ├── index.ts          # Hono app, route registration, CORS
│   ├── graph.ts          # JSON loader + writer, TransitGraph types
│   ├── routes/
│   │   ├── addRoute.ts   # POST /routes
│   │   └── meta.ts       # GET /modes, GET /payments
│   └── types.ts          # shared TS interfaces
├── data/
│   └── transit_graph_v3.json   # symlink or copy from iOS bundle
├── package.json
├── tsconfig.json
└── .env.example
```

## Build & Run

```bash
npm install
npm run dev      # tsx watch src/index.ts
npm run build    # tsc
npm start        # node dist/index.js
```

```json
// package.json scripts
{
  "dev": "tsx watch src/index.ts",
  "build": "tsc",
  "start": "node dist/index.js"
}
```

```json
// tsconfig.json — key settings
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "strict": true,
    "outDir": "dist"
  }
}
```

## Data Source

Symlink `transit_graph_v3.json` from the iOS bundle so both the iOS app and this service share one file:

```bash
ln -s ../CommuteBeh/CommuteBeh/transit_graph_v3.json data/transit_graph_v3.json
```

The file is read on each request (not cached in memory) so changes made by `POST /routes` are visible immediately on the next read. Use `fs.promises.readFile` / `writeFile` with an async file lock to prevent concurrent write corruption.

## TypeScript Types

```typescript
// src/types.ts

export interface Coordinates { lat: number; lng: number; }

export interface Station {
  id: string;
  name: string;
  shortName: string;
  line: string;
  type: string;
  coordinates: Coordinates;
  isTerminal: boolean;
  isInterchange: boolean;
  amenities: string[];
  operatingHours: { open: string; close: string };
}

export interface TransitEdge {
  id: string;
  from: string;
  to: string;
  mode: string;
  line: string;
  travelTimeMinutes: number;
  distanceKm: number;
  baseFare: number;
  farePerKm: number;
  acceptedPayments: string[];
  isAirConditioned: boolean;
  crowdFactor: number;
  reliability: number;
  bidirectional: boolean;
  polylineCoordinates: Coordinates[];
  mkDirectionsTransportType: string;
  isRoadSnapped: boolean;
}

export interface TransportModeConfig {
  id: string;
  displayName: string;
  pluralName: string;
  colorHex: string;
  isUserSelectable: boolean;
  isAlwaysAllowed: boolean;
  lines: string[];
  defaultAcceptedPayments: string[];
}

export interface PaymentMethodConfig {
  id: string;
  displayName: string;
  colorHex: string;
  isDefault: boolean;
  acceptedByModes: string[];
}

export interface TransitGraph {
  version: string;
  stations: Station[];
  edges: TransitEdge[];
  peakHourMultipliers: unknown;
  transportModes: Record<string, TransportModeConfig>;
  paymentMethods: Record<string, PaymentMethodConfig>;
}

// Incoming payload from the web form

export interface StopInput {
  name: string;
  shortName: string;
  lat: number;
  lng: number;
}

export interface RoutePayload {
  displayName: string;
  lineID: string;
  mode: 'jeepney' | 'bus' | 'tricycle' | 'train';
  isAirConditioned: boolean;
  baseFare: number;
  farePerKm: number;
  acceptedPayments: string[];
  openTime: string;   // "HH:mm"
  closeTime: string;  // "HH:mm"
  crowdFactor: number;   // 0–1
  reliability: number;   // 0–1
  stops: StopInput[];    // min 2
}
```

## REST API

### `GET /modes`
Returns transport mode configs where `isUserSelectable: true`, sorted by `displayName`.
```json
{ "modes": [TransportModeConfig, ...] }
```

### `GET /payments`
Returns all payment method configs, sorted by `displayName`.
```json
{ "payments": [PaymentMethodConfig, ...] }
```

### `POST /routes`
Body: `RoutePayload`. Validates, builds stations + edges, appends them to `transit_graph_v3.json`, returns a summary.

**Response 200:**
```json
{
  "message": "Route added successfully.",
  "lineID": "JEEPNEY_QUIAPO_CUSTOM",
  "stops": 4,
  "edges": 3
}
```

**Response 400** — validation failure:
```json
{ "error": "At least 2 stops are required." }
```

**Response 409** — lineID already exists in the graph:
```json
{ "error": "Line ID 'JEEPNEY_QUIAPO_CUSTOM' already exists." }
```

## Route Generation Logic

Port the logic from `LoopCreatorView.swift:generateAndSave` and `RecordCommuteView.swift:generateAndSave`. The web form provides explicit stop coordinates so no RDP simplification or road-snapping is needed.

### Station IDs
```
{lineID}_STOP1, {lineID}_STOP2, …, {lineID}_STOPn
```

### Station shape
```typescript
{
  id:             `${lineID}_STOP${i + 1}`,
  name:           stop.name,
  shortName:      stop.shortName,
  line:           lineID,
  type:           mode,
  coordinates:    { lat: stop.lat, lng: stop.lng },
  isTerminal:     i === 0 || i === stops.length - 1,
  isInterchange:  false,
  amenities:      [],
  operatingHours: { open: openTime, close: closeTime }
}
```

### Edge IDs
```
{lineID}_SEG1, {lineID}_SEG2, …, {lineID}_SEG(n-1)
```
Edges are linear (stop[i] → stop[i+1]), not a closed loop. This matches `RecordCommuteView.swift:generateAndSave` (open/linear route, not `LoopCreatorView`'s wraparound).

### Edge shape
```typescript
{
  id:                       `${lineID}_SEG${i + 1}`,
  from:                     `${lineID}_STOP${i + 1}`,
  to:                       `${lineID}_STOP${i + 2}`,
  mode,
  line:                     lineID,
  travelTimeMinutes:        Math.round(travelTime * 10) / 10,
  distanceKm:               Math.round(dist * 100) / 100,
  baseFare,
  farePerKm,
  acceptedPayments,
  isAirConditioned,
  crowdFactor,
  reliability,
  bidirectional:            true,
  polylineCoordinates:      [{ lat: from.lat, lng: from.lng }, { lat: to.lat, lng: to.lng }],
  mkDirectionsTransportType: 'automobile',
  isRoadSnapped:            false
}
```

`polylineCoordinates` is a straight line between the two stop coordinates (no road-snapping on the backend — the iOS road-snap used MKDirections which is Apple-only). The ExploreView on iOS will display these as straight segments.

### Distance & travel time (port of iOS haversine)
```typescript
function haversine(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const R = 6371;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLng = (lng2 - lng1) * Math.PI / 180;
  const a = Math.sin(dLat/2)**2
    + Math.cos(lat1 * Math.PI/180) * Math.cos(lat2 * Math.PI/180) * Math.sin(dLng/2)**2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// Travel time: ~24 km/h average, minimum 2 minutes (matches iOS)
const travelTime = Math.max(2.0, distKm / 0.4);
```

### JSON write
1. Read current `transit_graph_v3.json`
2. Check `lineID` is not already in any `transportModes[mode].lines` array — 409 if duplicate
3. Append new stations to `graph.stations`
4. Append new edges to `graph.edges`
5. Append `lineID` to `graph.transportModes[mode].lines` if not present
6. Write back with `JSON.stringify(graph, null, 2)` — atomic write (write to `.tmp` then rename)

## Validation Rules (enforced in `POST /routes` before touching the file)

| Rule | Error |
|---|---|
| `stops.length < 2` | "At least 2 stops are required." |
| `displayName` empty | "Display name is required." |
| `lineID` empty or contains spaces | "Line ID must be non-empty and contain no spaces." |
| `lineID` already in graph | 409 "Line ID '...' already exists." |
| `crowdFactor` or `reliability` outside 0–1 | "crowdFactor and reliability must be between 0 and 1." |
| Any stop missing `name`, `lat`, or `lng` | "All stops must have a name, latitude, and longitude." |

## CORS

```typescript
import { cors } from 'hono/cors';
app.use('*', cors());   // restrict to web frontend origin in production
```

## Key Invariants

- Never hardcode mode strings or payment strings — all come from the JSON `transportModes` and `paymentMethods` keys.
- `isTerminal` is set server-side based on stop index (first and last), not trusted from the client.
- `bidirectional: true` on all edges (matches `RecordCommuteView` behaviour — linear routes are bidirectional).
- The JSON write must be atomic. Use `fs.promises.writeFile(tmpPath)` then `fs.promises.rename(tmpPath, targetPath)` to avoid a corrupt file if the process crashes mid-write.
- `lineID` uniqueness is checked against `transportModes[mode].lines` in the existing JSON before writing.
