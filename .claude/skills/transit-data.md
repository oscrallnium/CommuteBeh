# Transit Data — Graph Schema & Conventions

The app's transit network is defined entirely in `CommuteBeh/transit_graph_v3.json`. This file is the single source of truth for all routing data.

## Top-Level Structure

```jsonc
{
  "version": "3.0",
  "stations": [...],
  "edges": [...],
  "peakHourMultipliers": { "morningPeak": {...}, "eveningPeak": {...}, "trainPeak": {...} },
  "transportModes": { "train": {...}, "bus": {...}, ... },
  "paymentMethods": { "cash": {...}, "beep_card": {...}, ... }
}
```

## Station Schema

```jsonc
{
  "id": "MRT3_NORTH_AVE",        // Unique string ID — used as StationID throughout Swift code
  "name": "North Avenue",         // Full display name
  "shortName": "North Ave",       // Used in route instructions (shorter)
  "line": "MRT-3",                // Line key — must match an edge's "line" field
  "type": "train",                // Mode string: "train" | "bus" | "jeepney" | "tricycle"
  "coordinates": { "lat": 14.6521, "lng": 121.0319 },
  "isTerminal": true,             // First/last station of a line
  "isInterchange": false,         // Has a walk/interchange edge to another line
  "interchangesWith": ["LRT1_MONUMENTO"], // IDs of interchange partner stations (or null)
  "amenities": ["elevator", "aircon"],
  "operatingHours": { "open": "05:00", "close": "23:00" }
}
```

## Edge Schema

```jsonc
{
  "id": "MRT3_NORTH_AVE_TO_QUEZON_AVE",
  "from": "MRT3_NORTH_AVE",
  "to": "MRT3_QUEZON_AVE",
  "mode": "train",                // Must be a key in transportModes
  "line": "MRT-3",                // Used for leg consolidation — same-line consecutive edges merge
  "travelTimeMinutes": 2.5,
  "distanceKm": 1.2,
  "baseFare": 13.0,               // Flat fare component
  "farePerKm": 0.0,               // Per-km fare component (0 = flat only)
  "acceptedPayments": ["beep_card", "cash"],
  "isAirConditioned": true,
  "crowdFactor": 0.6,             // 0.0–1.0; influences A* cost (not ETA display)
  "reliability": 0.9,             // 0.0–1.0; influences A* cost (not ETA display)
  "bidirectional": false,         // true → engine generates a synthetic reverse edge automatically
  "direction": "northbound",      // "northbound" | "southbound" | null
  "polylineCoordinates": [
    { "lat": 14.6521, "lng": 121.0319 },  // Must start at "from" station coords
    { "lat": 14.6463, "lng": 121.0320 }   // Must end at "to" station coords
  ],
  "mkDirectionsTransportType": "transit"  // "transit" | "walking" | "automobile" — ETA hint only
}
```

## Interchange Edges

Walk/interchange connections between lines use a special line value:

```jsonc
{
  "id": "INTERCHANGE_ARANETA_LRT2_TO_MRT3",
  "from": "LRT2_ARANETA_CUBAO",
  "to": "MRT3_ARANETA_CUBAO",
  "mode": "walk",
  "line": "INTERCHANGE",          // This sentinel prevents leg consolidation
  "travelTimeMinutes": 3.0,
  "baseFare": 0.0,
  "farePerKm": 0.0,
  "bidirectional": true,
  ...
}
```

### Stopover-then-Walk Routing

The engine supports "alight here, walk to another line" instructions — this is how jeepney-to-train transfers work. The A* engine will naturally produce a route like:

> Ride jeepney → alight at stop X → walk to MRT station Y → board train

…**only if** an explicit `INTERCHANGE` walk edge exists between the jeepney stop and the train station in the JSON. No Swift changes are needed; adding the edge is sufficient.

**Currently defined jeepney ↔ train interchange (as of v3):**

| Jeepney stop | Walk edge | Train station |
|---|---|---|
| `JEEP_TAFT_PASAY` (Taft Ave Pasay, `JEEPNEY_CARTIMAR_LRT`) | `INTERCHANGE_TAFT_PASAY_MRT_BUENDIA` | `MRT_BUENDIA` (Buendia, MRT-3) |

All other INTERCHANGE edges in v3 are train ↔ train or train ↔ bus-hub connections.

**To add a new jeepney → MRT stopover**, add:
1. An INTERCHANGE edge (`mode: "walk"`, `line: "INTERCHANGE"`) between the jeepney stop node and the train station node.
2. Set `isInterchange: true` on both station nodes and populate `interchangesWith` with the partner's ID.

## Transport Mode Config Schema

Keyed by mode ID string in `transportModes`:

```jsonc
"train": {
  "id": "train",
  "displayName": "Train",
  "isUserSelectable": true,       // Show in mode filter UI
  "isAlwaysAllowed": false,       // If true, bypasses mode/payment filter in A*
  "lines": ["MRT-3", "LRT-1", "LRT-2"],
  "defaultAcceptedPayments": ["beep_card", "cash", "card"],
  ...
}
```

`walk` must have `isAlwaysAllowed: true` — this is what makes interchange edges bypass all filters.

## Peak Hour Multipliers

Applied lazily during A* edge cost calculation. Multipliers stack (max is taken, not summed):

```jsonc
"peakHourMultipliers": {
  "morningPeak": {
    "timeRange": { "start": "07:00", "end": "09:00" },
    "travelTimeMultiplier": 1.4,
    "modes": ["bus", "jeepney", "tricycle"]
  },
  "trainPeak": {
    "timeRange": { "start": "07:30", "end": "09:30" },
    "travelTimeMultiplier": 1.25,
    "modes": ["train"]
  }
}
```

## Naming Conventions

- Station IDs: `{LINE}_{STATION_SHORTNAME}` in SCREAMING_SNAKE_CASE, e.g. `MRT3_NORTH_AVE`
- Edge IDs: `{FROM_ID}_TO_{TO_ID}`, e.g. `MRT3_NORTH_AVE_TO_MRT3_QUEZON_AVE`
- Interchange edge IDs: `INTERCHANGE_{FROM_LINE}_TO_{TO_LINE}_{STATION}`, e.g. `INTERCHANGE_LRT2_MRT3_ARANETA`
- Line keys: Use official line names for trains (`MRT-3`, `LRT-1`, `LRT-2`); SCREAMING_SNAKE_CASE for others (`EDSA_BUS`, `JEEPNEY_MAKATI`)

## Validation Checklist When Editing the JSON

- [ ] Every `edge.from` and `edge.to` matches an existing station `id`
- [ ] Every `edge.mode` matches a key in `transportModes`
- [ ] Every `edge.line` matches a station's `line` field (or is `"INTERCHANGE"`)
- [ ] `polylineCoordinates[0]` == `fromStation.coordinates` (approx)
- [ ] `polylineCoordinates[-1]` == `toStation.coordinates` (approx)
- [ ] `bidirectional: true` edges do NOT also have a manually defined reverse edge (engine auto-creates it)
- [ ] Interchange edges use `"line": "INTERCHANGE"` and `"mode": "walk"`
- [ ] `acceptedPayments` values are keys in `paymentMethods`

## Version History

| Version | File | Notes |
|---|---|---|
| v2 | `transit_graph_v2.json` | Used by `ExploreView` for network visualization |
| v3 | `transit_graph_v3.json` | Active — used by `CommuteViewModel` / A* engine |
