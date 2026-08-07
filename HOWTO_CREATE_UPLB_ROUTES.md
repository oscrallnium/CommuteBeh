# How to Create the UPLB Kaliwa & Kanan Routes

**Date:** 2026-07-29
**Background:** `FEATURE_UPLB_BRANCHING_ROUTE_AUDIT.md` (why this shape) · `FEATURE_UPLB_JEEPNEY_ROUTES_REVISION_PLAN.md` (what changed and why)

These two routes are authored **by hand via the API**, not through the in-app Loop Creator. The recorder sorts stops by projecting them onto the recorded path, which scrambles the order on a route that doubles back along the same road — which this one does.

**Prerequisite:** the backend must include commit `a3fe2ae` ("Let a pass declare bidirectional independently of direction"). Without it, `"bidirectional": false` is ignored on a direction-less pass and every edge comes out two-way — the exact defect these routes must avoid.

---

## The shape you are building

One line ID per branch. Each is a **single open, one-way chain** covering the whole circuit — out to campus, around, and back:

```
UPLB_KALIWA_STOP1    Calamba Crossing Terminal          ← board here going to UPLB
UPLB_KALIWA_STOP2…   trunk stops, to-UPLB side of the road
UPLB_KALIWA_STOP…    UPLB Gate (entering)
UPLB_KALIWA_STOP…    kaliwa campus stops
UPLB_KALIWA_STOP…    UPLB Gate (leaving)
UPLB_KALIWA_STOP…    trunk stops, to-Calamba side of the road
UPLB_KALIWA_STOPn    Calamba Crossing Terminal          ← alight here coming back
```

Two rules that matter more than anything else here:

1. **A stop on the to-UPLB side and a stop on the to-Calamba side are two different stops**, even if they face each other across the same road. Give each its own entry with its own coordinates. This is what stops the app from telling a homebound rider to wait on the outbound side.
2. **The gate and the terminal each appear twice** — once entering, once leaving. That is correct and intended; they become separate stations.

---

## Step 1 — Collect the stops

For each branch, list every stop **in the order the jeepney passes it**, all the way around the circuit, with a latitude/longitude for each.

Getting coordinates: long-press a spot in Apple Maps and read off the coordinate, or use Google Maps (right-click → the lat/lng at the top of the menu). Six decimal places is plenty (~0.1 m).

Name stops so the direction is obvious in search results and in "get off at…" instructions:

| Good | Bad |
|---|---|
| `Freedom Park (to UPLB)` | `Freedom Park` |
| `Freedom Park (to Calamba)` | `Freedom Park 2` |

Both branches share the trunk stops between Calamba and the gate — list them in **both** payloads. They will exist as separate rows per line; that is expected and harmless.

---

## Step 2 — Get an admin token

```bash
curl -s -X POST https://commute-backend-a6lj.onrender.com/auth/sign_in \
  -H 'Content-Type: application/json' \
  -d '{"user":{"email":"YOUR_ADMIN_EMAIL","password":"YOUR_PASSWORD"}}'
```

The response is `{"data":{"token":"eyJ…","user":{…}}}`. Confirm `user.role` is `"admin"` — the graph endpoints reject anything else with 403. Export it:

```bash
export TOKEN='eyJ…'
export API=https://commute-backend-a6lj.onrender.com
```

The service sleeps when idle, so the first call may take ~45 s. That is a cold start, not a failure.

---

## Step 3 — Write the payload

One file per branch. `uplb_kaliwa.json`:

```jsonc
{
  "displayName": "UPLB Kaliwa",
  "lineID": "UPLB_KALIWA",
  "mode": "jeepney",
  "openTime": "05:00",
  "closeTime": "22:00",
  "baseFare": 13.0,
  "farePerKm": 1.8,
  "acceptedPayments": ["cash"],
  "isAirConditioned": false,
  "crowdFactor": 0.7,
  "reliability": 0.65,
  "passes": [
    {
      "direction": null,
      "bidirectional": false,
      "closesLoop": false,
      "isRoadSnapped": false,
      "stops": [
        { "name": "Calamba Crossing Terminal", "shortName": "Calamba", "lat": 14.210000, "lng": 121.165000 },
        { "name": "Crossing Junction (to UPLB)",  "lat": 14.211000, "lng": 121.166000 },
        { "name": "National Highway (to UPLB)",   "lat": 14.213000, "lng": 121.168000 },
        { "name": "UPLB Gate (entering)",         "lat": 14.216000, "lng": 121.170000 },
        { "name": "Kaliwa — Humanities",          "lat": 14.217000, "lng": 121.171000 },
        { "name": "Kaliwa — Freedom Park",        "lat": 14.218000, "lng": 121.172000 },
        { "name": "UPLB Gate (leaving)",          "lat": 14.216100, "lng": 121.170100 },
        { "name": "National Highway (to Calamba)","lat": 14.213100, "lng": 121.168100 },
        { "name": "Crossing Junction (to Calamba)","lat": 14.211100, "lng": 121.166100 },
        { "name": "Calamba Crossing Terminal", "shortName": "Calamba", "lat": 14.210000, "lng": 121.165000 }
      ]
    }
  ]
}
```

`uplb_kanan.json` is identical except `displayName: "UPLB Kanan"`, `lineID: "UPLB_KANAN"`, and campus stops on the kanan road. **Coordinates above are placeholders — replace every one.**

### Field notes

| Field | Why it is what it is |
|---|---|
| `"direction": null` | One chain covers both travel directions of the corridor, so no single direction label could describe it. Direction is not the tool here — separate stops are. |
| `"bidirectional": false` | **The important one.** Makes each edge one-way, so the router can't run the chain backwards. Omit it and you get two-way edges and wrong-side stops. |
| `"closesLoop": false` | Keeps the chain open. Closed loops can't have stops inserted or removed afterwards. The final Calamba stop already closes the circuit as an ordinary stop. |
| `"isRoadSnapped": false` | Say `true` only if you supply real road-following `polyline` arrays. Left `false`, Explore road-snaps the straight chords itself for display. |
| `shortName` | Optional; derived from `name` when omitted. |

### Optional: real geometry

Without `polyline`, each segment is drawn as a straight chord between stops and `distance_km` is the straight-line distance — so fares and times will read slightly short. To supply real geometry, add a `polyline` to each stop **after the first**; it is the path leading *into* that stop, and its measured length replaces the chord:

```jsonc
{ "name": "UPLB Gate (entering)", "lat": 14.216, "lng": 121.170,
  "polyline": [ {"lat": 14.2130, "lng": 121.1680}, {"lat": 14.2145, "lng": 121.1690}, {"lat": 14.2160, "lng": 121.1700} ] }
```

Start each polyline at the previous stop's coordinate and end it at this stop's. You can also skip this now and draw the shapes later in **Admin → Manage Routes → Edit Polylines**.

---

## Step 4 — Create the routes

```bash
curl -s -X POST "$API/api/v1/admin/graph/routes" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --data @uplb_kaliwa.json

curl -s -X POST "$API/api/v1/admin/graph/routes" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --data @uplb_kanan.json
```

Success is `201` with `{"data":{"line_id":"UPLB_KALIWA","stations_added":10,"edges_added":9}}`. An *n*-stop open chain gives *n−1* edges — if `edges_added` equals `stations_added`, `closesLoop` slipped in and you have a closed loop.

Nothing is written when validation fails, so a rejected payload leaves no partial route to clean up.

---

## Step 5 — Verify in the app

Pull to refresh, or reopen the app so the graph syncs, then:

- [ ] **Explore** lists "Uplb Kaliwa" and "Uplb Kanan" and draws each as one continuous line out and back.
- [ ] **Plan Calamba → a campus stop.** The listed stops must all be the *(to UPLB)* ones.
- [ ] **Plan that campus stop → Calamba.** The stops must be the *(to Calamba)* ones, and the alighting coordinate must differ from the outbound one. **This is the check the whole design exists for.**
- [ ] Fare for a one-way trip is one base fare, not two.
- [ ] **Admin → Manage Routes → UPLB Kaliwa** lists the stops in travel order (toggle the eye icon to see coordinates).

---

## Fixing things afterwards

| Need | Where |
|---|---|
| Move a stop / rename it / change hours | Admin → Manage Routes → *line* → tap the stop |
| Add a missed stop | Admin → Manage Routes → *line* → **+** (snaps to the polyline; splits the segment) |
| Remove a stop | Swipe the stop → Remove (merges the two neighbouring segments) |
| Redraw a segment's shape | Admin → Manage Routes → **Edit Polylines** |
| Start over | Swipe the line in Manage Routes → Delete, then re-POST |

Adding or removing stops renumbers every `_STOP<n>` after the change point — that is normal.

**One limitation to know:** you cannot append another pass to these lines later (a line whose pass has no direction is closed to appends). Add stops with the **+** button instead. If the branch's shape changes fundamentally, delete the line and re-POST it.

---

## Troubleshooting

| Response | Cause |
|---|---|
| `401 Unauthorized` | Token missing/expired — repeat Step 2. |
| `403 Forbidden` | The account isn't `role: "admin"`. |
| `"Line ID must only contain uppercase letters, digits, underscores, and dots."` | Fix `lineID`. **Avoid dots** — they are legal but have caused path-parsing trouble; stick to `A–Z`, `0–9`, `_`. |
| `"Line ID 'UPLB_KALIWA' already exists (recorded without a direction)"` | The route is already there. Delete it first, or edit it in place. |
| `"A direction-tagged pass can't be bidirectional."` | You set both `direction` and `bidirectional: true`. For these routes: `direction: null`, `bidirectional: false`. |
| `"Route: at least 2 stops are required."` | `stops` is empty or malformed — check it's an array of objects with `name`, `lat`, `lng`. |
| Route created, but Explore still shows the old graph | The client caches by graph version. Force-quit and reopen; `add_route` bumps the version, so a fresh launch will pull it. |
| Both directions show the *same* stops | `bidirectional` was omitted or `true`. Delete the line and re-POST with `false`. |
