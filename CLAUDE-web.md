# CLAUDE-web.md — CommuteBeh Web: Add Route

Web form for adding a new transit route to `transit_graph_v3.json`. This is the only feature for now — no route-finding, no map search.

The form mirrors the metadata + stop-definition flow in `LoopCreatorView.swift` (`MetadataPhaseView` + `DefiningStopsPhaseView`) but collapses it into a single page. The iOS phases (Draw Loop → Simplify → Mark Stops → Metadata) are replaced by direct coordinate input since GPS recording and map-tap are iOS-only.

## Project

**commutebeh-web** — Next.js 14 + TypeScript, single-page route-creation form.

- Framework: Next.js 14 (App Router)
- Language: TypeScript (strict)
- Styling: Tailwind CSS
- Map preview: [Leaflet](https://leafletjs.com) via [react-leaflet](https://react-leaflet.js.org) (lightweight, no token required)
- API: `commutebeh-api` (see `CLAUDE-backend.md`)

```
commutebeh-web/
├── app/
│   ├── layout.tsx
│   ├── page.tsx              # renders <AddRouteForm />
│   └── globals.css
├── components/
│   ├── AddRouteForm.tsx      # root form — all sections in one page
│   ├── StopList.tsx          # dynamic list of stops with add/remove
│   ├── StopRow.tsx           # one stop: name + lat/lng inputs
│   └── RoutePreviewMap.tsx   # Leaflet map showing stops + polyline
├── hooks/
│   └── useAddRoute.ts        # form state + submit logic
├── lib/
│   └── api.ts                # typed fetch wrapper for POST /routes
├── types/
│   └── transit.ts            # RoutePayload and supporting types
├── .env.local.example
└── package.json
```

## Build & Run

```bash
npm install
npm run dev     # next dev
npm run build   # next build
npm start       # next start
```

```env
# .env.local
NEXT_PUBLIC_API_URL=http://localhost:3001
```

## Form Fields

These map exactly to the iOS `MetadataPhaseView` (in `LoopCreatorView.swift:856`) and `RecordedMetadataView` (in `RecordCommuteView.swift:661`).

### Route Identity
| Field | Type | iOS source | Notes |
|---|---|---|---|
| Display Name | text input | `routeDisplayName` | Required |
| Line ID | text input | `lineID` | Auto-generated from Display Name (uppercased, spaces → `_`, non-alphanum stripped); user can override |

Line ID auto-generation rule (matches `autoLineID` in both iOS VMs):
```typescript
function autoLineID(name: string): string {
  return name.toUpperCase()
    .split(/\s+/)
    .filter(Boolean)
    .join('_')
    .replace(/[^A-Z0-9_]/g, '');
}
```
Update Line ID automatically as the user types the Display Name, but stop auto-updating once the user manually edits Line ID.

### Transport
| Field | Type | Default | iOS source |
|---|---|---|---|
| Mode | select | `jeepney` | `selectedMode` — options: jeepney, bus, tricycle, train |
| Air Conditioned | checkbox | false | `isAirConditioned` |

### Fare
| Field | Type | Default | iOS source |
|---|---|---|---|
| Base Fare (₱) | number | 13 | `baseFare` |
| Per km (₱) | number | 1.8 | `farePerKm` |

### Accepted Payments
Checkboxes for: `cash`, `gcash`, `maya`, `beep_card`, `card`. Default: `cash` only.
Maps to `selectedPayments: Set<string>` in iOS.
Display labels: replace `_` with space, capitalize each word.

### Operating Hours
| Field | Type | Default | iOS source |
|---|---|---|---|
| Opens | text `HH:mm` | `05:00` | `openTime` |
| Closes | text `HH:mm` | `22:00` | `closeTime` |

### Quality
| Field | Type | Range | Step | Default | iOS source |
|---|---|---|---|---|---|
| Crowd Factor | range slider | 0–1 | 0.05 | 0.7 | `crowdFactor` |
| Reliability | range slider | 0–1 | 0.05 | 0.65 | `reliability` |

Display the current slider value as a decimal (e.g. `0.70`) next to each slider label.

### Stops
Dynamic list. Minimum 2 stops to enable submit. The first and last stop are automatically flagged `isTerminal: true`.

Each stop row has:
| Field | Type | Notes |
|---|---|---|
| Name | text input | Full station name, e.g. "Quiapo Church" |
| Short Name | text input | Auto-populated as first 2 words of Name; user can override |
| Latitude | number input | `step="0.0001"` |
| Longitude | number input | `step="0.0001"` |

Controls:
- **Add Stop** button — appends a blank row
- **Remove** button on each row (disabled when only 2 stops remain)
- Drag-to-reorder is optional for v1; ordered list is sufficient

## RoutePreviewMap

Renders below the stop list when ≥ 2 stops have valid coordinates (both lat and lng non-empty).

- Leaflet map centered on Metro Manila (`[14.5763, 121.0194]`, zoom 11)
- Circle marker at each stop (orange for terminals, blue for intermediate)
- Polyline connecting stops in order
- Map auto-fits to the bounding box of all stop coordinates
- Read-only — no click-to-place in v1 (coordinates are typed in StopRow)

## Form State (`useAddRoute` hook)

```typescript
interface StopEntry {
  name: string;
  shortName: string;
  lat: string;   // string so empty input is valid
  lng: string;
}

interface RouteFormState {
  displayName: string;
  lineID: string;
  lineIDManuallyEdited: boolean;  // stops auto-update once user edits lineID
  mode: 'jeepney' | 'bus' | 'tricycle' | 'train';
  isAirConditioned: boolean;
  baseFare: number;
  farePerKm: number;
  selectedPayments: Set<string>;
  openTime: string;
  closeTime: string;
  crowdFactor: number;
  reliability: number;
  stops: StopEntry[];
}
```

Initial state mirrors iOS defaults. `canSubmit` is true when:
- `displayName` is non-empty
- `lineID` is non-empty
- `stops.length >= 2`
- Every stop has `name`, `lat`, and `lng` filled in

## Submit Behaviour

On submit, `useAddRoute` calls `POST /routes` with a `RoutePayload` (see `CLAUDE-backend.md`). While the request is in-flight, disable the submit button and show a spinner. On success, show a success banner with the route name and stop count; reset the form. On error, show the error message inline above the submit button.

## `lib/api.ts`

```typescript
export async function addRoute(payload: RoutePayload): Promise<{ message: string }> {
  const res = await fetch(`${process.env.NEXT_PUBLIC_API_URL}/routes`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error(err.error ?? `Request failed: ${res.status}`);
  }
  return res.json();
}
```

## `types/transit.ts`

```typescript
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
  crowdFactor: number;
  reliability: number;
  stops: StopInput[];
}
```

## Layout

Single scrollable page. No tabs, no sidebar. Stack the sections vertically in this order:

1. Page heading: "Add Transit Route"
2. Route Identity section
3. Transport section
4. Fare section
5. Accepted Payments section
6. Operating Hours section
7. Quality section
8. Stops section + RoutePreviewMap below it
9. Submit button + error/success feedback

Each section is a `<fieldset>` with a `<legend>` label. Use Tailwind's `divide-y` or card-style `border rounded-lg p-4` to visually separate sections.

## Key Invariants

- Line ID auto-generation must match the iOS `autoLineID` function exactly (uppercase, spaces→`_`, strip non-alphanum).
- `isTerminal` is set by the backend based on stop index (first and last), not sent by the form.
- `selectedPayments` defaults to `["cash"]` — at least one payment must be selected.
- Do not hardcode mode or payment options — fetch them from `GET /modes` and `GET /payments` on mount to populate dropdowns/checkboxes. Fall back to the known set only if the API is unreachable.
- Crowd factor and reliability are `0–1` floats, `step 0.05` — validate before submit.
