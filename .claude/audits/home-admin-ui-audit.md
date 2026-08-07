# Home (Commute) & Admin Tab UI/UX Audit

**Date:** 2026-07-04 · **Scope:** Commute tab (`ContentView.swift`) and Admin tab (`AdminRoutesView.swift`) UI only.
**Method:** built the working tree (`xcodebuild`, iPhone 17 / iOS 26.4 simulator — note: the `iPhone 16` destination in CLAUDE.md does not exist on this machine), logged in as an admin, exercised and screenshotted every reachable state of both tabs (screenshots in `/tmp/ui-audit/`). Backend data contracts are treated as trustworthy per `.claude/audits/backend-api-audit.md`; routing/polyline correctness is out of scope per `.claude/audits/polyline-audit.md`.

**Tab naming, verified:** there is **no "Home" tab**. `MainTabView` (`CommuteBehApp.swift:20-39`) declares: **Commute** (`ContentView`), **Explore**, **Record**, **Admin** (only when `session.isAdmin`), **Settings**. "Home" throughout this document = the Commute tab, the first/default tab.

**Baseline check:** `.claude/audits/homeview-ux-audit.md` does **not exist**. There is no prior design direction to extend; `.claude/skills/branding.md` is an explicit placeholder ("Status: To be defined", all colors inline system colors, no custom type). The tokens in this document are therefore the founding baseline, not an extension.

---

## Summary

The Commute tab is in good conventional shape — map-dominant layout, material search card, bottom result sheet — but its information hierarchy is inverted (the celebratory "Route Found" label is the biggest text on the result card while the decision metrics — time, fare — are gray captions), its loading overlay is a full-screen dark takeover for an A* computation that measurably completes in under ~100 ms (it renders as a flash), and one error message advises controls ("try different payment methods or transport modes") that have no UI anywhere on the tab. The Admin tab is an internal staff tool (role-gated — the commuter-facing assumption is confirmed wrong for it, as expected) and it has one **functional-severity UI bug found empirically in this pass: the station row's tap target is only the text label itself, not the row** — taps on the right ~60 % of every row do nothing (verified with real HID touches via `idb`; taps at x=200 pt failed, taps on the text at x=80 pt opened the editor). The same construction makes rows invisible to assistive tech (the row's AX element exposes no press action — VoiceOver cannot open the editor at all). Beyond that, the editor gives the admin zero context (bare map, no line/edges/neighbors), no move-distance feedback, no validation, no confirmation, and no success signal. Backend fixes changed one UI-relevant thing: error states on Admin save are now *reachable and real* rather than guaranteed — but the client still maps errors by status code alone, so during this audit a save failed after **~40 s of spinner** with the message *"This item no longer exists."* (an `APIError.notFound` string) when the actual cause was the deployed server lacking the PATCH route — the Rails-side param fix exists only as an **uncommitted local change** in `commutebeh-rails` and has not been deployed. That deploy gap is flagged below, not re-audited.

---

## Current State (grounded in screenshots)

### Commute tab (as of this build)

- **Default state:** full-bleed MapKit map of Metro Manila; floating material card at top with two fields ("From: Search station…" green dot icon, "To: Search station…" red pin icon), a full-width `Search Route` prominent button plus a small reset button; system tab bar below. Clean, recognizably a transit app.
- **Typing:** suggestion list appears as a second material card under the search card — icon + station name (`.subheadline`) + line id (`.caption`, secondary), max 5 rows. Line ids display raw (`JEEPNEY_QUIAPO`, `EDSA_BUS`).
- **Result (collapsed):** polylines + green origin dot / red destination pin / white transfer dots on the map (camera auto-fits, animated); bottom card shows `✓ Route Found` in green `.headline`, beneath it a single gray `.caption` row `35 min · ₱25 · 10.1 km`, a horizontal mode-pill chain (`Train` tinted pill) with `· 1 transfer` gray text, and a circular chevron expand button.
- **Result (expanded):** leg rows (mode dot, instruction `.subheadline`, gray caption `24 min · ₱12 · 6:45 PM`), a tinted `9 stops ⌄` disclosure that expands an indented vertical-track list of intermediate stations. Scrolls within `maxHeight: 260`.
- **Loading:** `LoadingOverlay` (full-screen `black.opacity(0.45)` + pulsing tri-color rings + "Calculating Route / Engine working…") could **not be captured even with a screenshot fired in the same command as the tap** — the local A* finishes faster than one frame of the overlay is meaningfully visible. Users see a dark flash.
- **Dark mode:** materials and map adapt correctly; no broken contrast found on this tab (walk-leg polylines at `gray.opacity(0.6)` are the weakest element on the dark map).

### Admin tab (as of this build)

- **Root ("Manage Routes"):** inset-grouped list of raw line keys (`COMMONWEALTH_BUS`, `JEEPNEY_CARTIMAR_LRT`, …) sorted alphabetically — modes interleaved, no mode icon/color. Subtitle has a live pluralization bug: **"1 stations"** (visible on four rows in the screenshot).
- **Station list (e.g. LRT-1):** rows of station name (`.headline`) + raw coordinates (`14.640600, 121.005600`, `.caption.monospacedDigit`), interchange icon where relevant. **Alphabetical order** (5th Avenue, Abad Santos, Baclaran, …) — not line order. Search field exists (`.searchable`) but is hidden until pulled.
- **Row tap:** broken as described in Summary — only the text block is tappable; rows expose no AX action.
- **Editor (`EditStationMapView`):** full-screen map at 400 m camera distance, fixed blue center pin, top material card (station name + live coordinate readout), bottom `Cancel` / `Confirm` buttons. **No line polyline, no adjacent stations, no original-position marker, no moved-distance indicator, no title, no unsaved-changes affordance.** The map is visually indistinguishable from a generic location picker.
- **Save:** Confirm becomes a bare spinner; **~40 s** elapsed with no further feedback before the error pill appeared: red caption *"This item no longer exists."* — factually wrong (the station exists; the deployed server is missing the route). Cancel stayed active during save. On a success path there is no confirmation moment at all: the sheet just dismisses, and the list's `onAppear { vm.load() }` re-reads the local graph, clobbering the in-memory update (polyline-audit Issue 3(b) — the *logic* is covered there; the *UI consequence* is that the admin's saved value silently reverts on screen).
- **Dark mode:** adapts correctly.

---

## Home Tab Direction

### Visual identity — concrete values

Typography (system SF Pro via Dynamic Type styles — do not add a custom face; branding.md defers that decision):

| Token | Style | Use |
|---|---|---|
| `type.metric` | `.title2` + `.bold()` + `.monospacedDigit()` | Total trip time on result card — the decision number |
| `type.metricSecondary` | `.headline` + `.monospacedDigit()` | Fare, distance on result card |
| `type.cardTitle` | `.headline` | Leg instructions, card headers |
| `type.body` | `.subheadline` | Field text, suggestion names |
| `type.meta` | `.caption` | Timestamps, line ids, stop counts |
| `type.coord` | `.caption.monospacedDigit()` | Any lat/lng display (shared with Admin) |

Color — semantic tokens to create in `Assets.xcassets` (all currently inline; branding.md's proposed `BrandColors` enum pattern is the place):

| Token | Light value | Role |
|---|---|---|
| `color.accent` | `#127BED` (already the de-facto blue: login icon, train lines) | Interactive elements, prominent buttons |
| `color.success` | systemGreen | Route found, origin dot |
| `color.destructive` | systemRed | Destination pin, errors |
| `color.warning` | systemOrange | Delays/incidents (future), Admin pending states |
| Mode colors | keep the existing functional mapping (train blue, bus orange, jeepney green, tricycle purple, walk gray) | Polylines, pills, dots |

**Consolidate `modeColor(_:)` now** into `extension TransportMode { var color: Color; var icon: String; var lineWidth: CGFloat }` — it is defined three times in `ContentView.swift` alone (lines 294-312, 461-479, 590-598) and already drifts: walk is `opacity(0.6)` on the map (line 300) but full opacity in rows (467, 596). CLAUDE.md already mandates this before new call sites.

Iconography: SF Symbols only. One correction: jeepney renders as `car.fill` (suggestion list line 354, pills line 475) — visually a private car. Use `bus.fill` with the jeepney green until a custom symbol exists; the color already differentiates it from bus orange.

Spacing scale (already implicitly ~4/8/12/16): formalize `space.1=4, space.2=8, space.3=12, space.4=16, space.6=24`. Corner radius: `radius.card=16` (search panel, result card — already used), `radius.control=12` (suggestion list, fields), capsules for pills. Elevation: `shadow.card = black 15 %, radius 8, y ±4` (already used top and bottom — keep as the only card shadow).

### Information hierarchy — what changes

1. **Invert the result-card header.** Today the largest, most colorful element is `✓ Route Found` (`.headline`, green) while `35 min · ₱25 · 10.1 km` is a gray `.caption` row (`RouteResultCard`, ContentView.swift:382-391). The card's existence already communicates success. Make total time the anchor: `35 min` in `type.metric`, fare `₱25` in `type.metricSecondary` beside it, distance in `type.meta`. Drop the "Route Found" text entirely or reduce it to the green checkmark icon. This is the single highest-value change on the tab: the number a commuter decides with becomes what the eye lands on.
2. **Promote transfers.** `· 1 transfer` is gray caption text trailing the pill scroll (line 416-420). Transfers are a decision factor on par with time for Manila commuters; render it as its own neutral pill (`1 transfer`, gray capsule) in the mode chain rather than an afterthought.
3. **Fix error messaging to match the UI that exists.**
   - `"No route found. Try different payment methods or transport modes."` (TransportMode.swift:1067) advises filters the Commute tab does not expose (`selectedPayments` / `selectedModes` / `useScheduledTime` exist on `CommuteViewModel` with no controls anywhere). Either build the filter UI or reword to `"No route found between these stations."` Do not ship advice the user cannot act on.
   - `"Failed to load transit data: \(error)"` (TransportMode.swift:1028) interpolates a raw Swift error into user-facing text. Truncate to `"Couldn't load transit data."` and log the detail.
   - These are **local-engine** messages, not backend-defensive remnants — reword, don't delete.
4. **Suggestion rows show raw line keys** (`JEEPNEY_QUIAPO`) as the secondary line (SuggestionList, line 333-335). The graph's `transportModes[].displayName` exists precisely for this; map key → display name for commuter-facing text. (Raw keys remain correct in the Admin tab — see below.)

### Motion — named patterns with values

| Pattern | Spec | Where |
|---|---|---|
| `motion.searchProgress` | Replace `LoadingOverlay` for route calculation: swap the `Search Route` label to an inline `ProgressView` inside the same prominent button, **only if** the search exceeds a 250 ms grace delay; if shown, keep visible ≥ 500 ms to avoid flicker | ContentView `.overlay` (line 84-86) — the current full-screen overlay renders as a dark flash for a < 100 ms local computation and should not appear at all for it. Keep `LoadingOverlay` only for genuinely long operations (none exist on this tab today) |
| `motion.cardEnter` | `.transition(.move(edge: .bottom).combined(with: .opacity))` with `.spring(response: 0.35, dampingFraction: 0.85)` | `RouteResultCard` appearance in `safeAreaInset` — today it hard-cuts in |
| `motion.suggestEnter` | `.transition(.opacity.combined(with: .move(edge: .top)))`, `.easeOut(duration: 0.2)` | Suggestion list appear/disappear — today it hard-cuts |
| `motion.cameraFit` | `.easeInOut(duration: 0.5)` | Already implemented (`fitMap`, line 287) — keep |
| `motion.disclose` | `.easeInOut(duration: 0.2)` | Already implemented for stop expansion (line 530) and card expand spring (line 395) — keep |

Motion's job on this tab is to communicate "the answer arrived" (card slides up) and "the map is responding" (camera glide) — both state changes. The loading overlay communicates nothing because the state it describes is over before it paints.

### Converge vs. differentiate

**Stay conventional:** full-bleed map, top search card, bottom result sheet, system tab bar, pull-behavior, green-dot/red-pin origin-destination language. Commuters transfer these habits from Google/Apple Maps; there is no upside in moving them.
**Differentiate:** (a) the mode-pill chain and the vertical-track intermediate-stop list are already distinctive and genuinely local (multimodal jeepney/tricycle chains don't exist in the big map apps) — invest polish there (consolidated mode colors, display names, transfer pill); (b) transit-line colors as a first-class identity system (branding.md's line-color table) rather than generic UI accents. Do **not** differentiate via the loading experience or nonstandard gestures.

### File/component-level notes

- `ContentView.swift` — result-card hierarchy (`RouteResultCard`), transfer pill, suggestion display names, error text rendering (line 134-140: red caption is fine, keep placement), loading replacement, enter transitions, `modeColor` consolidation, jeepney icon.
- `TransportMode.swift` — error message strings only (lines 1028, 1037, 1041, 1067); no engine changes.
- No obsolete backend-defensive code found on this tab: it is offline-first **by design** (local A*, bundled JSON), not as a workaround. The silent-stale-graph behavior (`syncIfNeeded` still swallows errors) is a data-layer item already covered by backend-api-audit R1/R2 — see Open Questions for its partially-applied state.

---

## Admin Tab Direction

Confirmed an internal, role-gated staff tool editing **live routing data** (station lat/lng, remote-persisted). Recommendations weight usability, clarity, and error-prevention over brand — no brand identity work here beyond token reuse.

### Priority 0 — the row tap target (functional bug, verified)

`StationListView` rows (`AdminRoutesView.swift:106-110`) apply `.contentShape(Rectangle()).onTapGesture` to `StationCoordRow`, whose leading-aligned `VStack` hugs its text — so the hit area is the text block only. Real HID taps at the row's horizontal center do nothing; taps on the text open the editor. **Fix:** give the row content `.frame(maxWidth: .infinity, alignment: .leading)` *before* `.contentShape(Rectangle())` — or better, wrap the row in `Button { selectedStation = station } label: { StationCoordRow(station: station) }` with `.buttonStyle(.plain)`, which also fixes the second half of the bug: the current AX element exposes only scroll/menu actions (no press), so **VoiceOver users cannot open the editor at all**. The `Button` form gets both for free.

### Information hierarchy — concrete values

- **Lines list:** keep raw keys (`EDSA_BUS`) as the primary label — for an internal tool the canonical id *is* the name staff grep for. Add: mode icon + mode color chip (reuse `TransportMode.color`), the human `displayName` as `.caption` secondary, and group sections by mode (`Trains`, `Buses`, `Jeepneys`, `Tricycles`) instead of one alphabetical soup. Fix the pluralization: `"^[\(count) station](inflect: true)"` or manual `count == 1 ? "station" : "stations"` — "1 stations" is on screen today (`AdminRoutesView.swift:72-74`).
- **Station list:** order by **line sequence** (walk the line's edges from terminal to terminal), not `sorted { $0.name < $1.name }` (`AdminRoutesView.swift:26`). Editing coordinates is spatial work; alphabetical order forces the admin to already know the answer. Keep search for direct jumps. Add the raw `station.id` (`LRT1_BACLARAN`) as a `.caption2` third line — it's what appears in server logs and API calls, and staff will cross-reference it.
- **Row content:** name `.headline` (keep) · coordinates `type.coord` (keep) · station id `.caption2` secondary · interchange badge (keep).

### State clarity — the editor must answer "what am I editing, what changed, what will it affect"

`EditStationMapView` (`AdminRoutesView.swift:148-268`) changes, all concrete:

1. **Context overlay:** render the station's connected edges as `MapPolyline`s (line color, 3 pt) and adjacent stations as dots, so the admin sees the route they're bending. (Polyline-audit Issue 3 fix #4 already specifies this; it is unimplemented in the current build — the map is bare.)
2. **Original vs. new position:** keep a hollow marker at the original coordinate; show a `motion.disclose`-animated readout in the top card: `Moved 128 m NE` (`.caption`, `color.warning` when > 500 m). Compute with the existing haversine helper.
3. **Dirty-state gating:** `Confirm` disabled until `centerCoordinate` differs from the original by > 1 m; label it `Save Change` (verb + object beats "Confirm" in a destructive-ish context).
4. **Saving state:** replace the bare spinner with `Saving…` + spinner *inside the button*, disable `Cancel` (or convert it to `Abort` explicitly). Add a time-escalation message after 10 s: `Still saving — server may be waking up (up to ~60 s)` — the deployed backend is a Render free-tier instance with ~44 s cold starts; a silent spinner of that length reads as a hang and invites a duplicate tap or force-quit.
5. **Success feedback:** on save success, before `dismiss()`, flash a checkmark state (`Saved ✓`, `color.success`, 600 ms) — currently dismissal is the only signal and it is indistinguishable from Cancel. After dismissal the list row must show the new value durably (the `onAppear { vm.load() }` clobber is polyline-audit Issue 3(b)'s scope; the UI requirement it must satisfy: *the value the admin saved stays on screen*).
6. **Title the screen:** `Edit Station Position` + station name — a full-screen cover with no title reads as a mispush.

### Error prevention — concrete values

- **Bounds validation, client-side, pre-submit:** Metro Manila bbox lat 14.3–14.9, lng 120.9–121.2 (matches polyline-audit fix #4). Out of bounds → inline `.caption` error in `color.destructive` above the buttons + `Save Change` disabled. Validation feedback timing: live on `onMapCameraChange` end (not on submit — don't let the admin line up a save that can't succeed).
- **Consequence confirmation for large moves:** move > 500 m → `confirmationDialog`: title `Move Baclaran 3.2 km?`, message `This updates live routing data for LRT-1 and 2 connected edges.`, destructive-styled confirm `Move Station`, cancel default. Under 500 m saves directly — don't tax the common nudge-by-10-m case.
- **Honest error surfaces:** the audit-observed failure showed *"This item no longer exists."* for a missing server route. For an **internal tool**, show the technical truth: HTTP status + server message + endpoint (`PATCH /admin/stations/LRT1_BACLARAN → 404`). Staff can act on that; commuter-grade euphemisms actively mislead here. This requires `APIError` to carry the response body/status (same mechanism backend-api-audit L1 fix #1 specifies for login — one shared fix, two beneficiaries). The generic `"Save failed. Try again."` fallback (`AdminRoutesView.swift:264`) survives as the true last resort only.
- **Stale-error-messaging flag (requested check):** the `"Save failed. Try again."` + status-code-only mapping *predates* the contract fixes and is now the wrong shape: with contracts fixed, remaining failures are network/deploy/validation, each needing different admin action. It is compensating-era code — replace per above rather than keep.

### Efficiency

Current common-edit path: Admin tab → line → scroll (alphabetical) → row (broken target) → pan → Confirm → no feedback. After the fixes above: tab → mode section → sequenced list or search → full-width row → pan with live Δ → save with confirmation only when it matters. That is the same step count with every step de-risked; no further compression is warranted for an occasional-use tool.

### Converge vs. differentiate

**Stay standard:** inset-grouped lists, `.searchable`, nav-stack drill-down, system `confirmationDialog`, red-for-destructive. Internal tools benefit from zero learning curve. **Differentiate only in information density:** internal tools should show *more* raw data (ids, exact coords, HTTP statuses) than commuter UI, not less. No brand styling work.

### File/component-level notes

- `AdminRoutesView.swift` — everything above: row Button conversion (P0), pluralization, mode grouping/sequencing, station id line, editor title/context/Δ-readout/dirty-gating/saving-states/success-flash, bounds check, large-move dialog.
- `APIError.swift` / `APIClient.swift` — carry status + server body in errors so Admin can render them (shared with the login-message fix in backend-api-audit; implement once).
- Line-sequence ordering needs edge-walking over the loaded graph — add as a helper in `AdminRoutesViewModel`, not in the view.

---

## New Design Tokens Needed

No prior token set exists (no homeview-ux-audit.md; branding.md is a placeholder), so the Home-tab tables above **are** the founding set: `type.metric/.metricSecondary/.cardTitle/.body/.meta/.coord`, `space.1–6 (4/8/12/16/24/32)`, `radius.card=16 / radius.control=12 / capsule`, `shadow.card (black 15 %, r8, y4)`, `color.accent/success/destructive/warning`, mode colors via `TransportMode.color`, and the five motion patterns (`searchProgress`, `cardEnter`, `suggestEnter`, `cameraFit`, `disclose`).

Admin-specific additions (not needed by commuter UI):

| Token | Value | Use |
|---|---|---|
| `color.admin.saved` | systemGreen | Success flash on save |
| `color.admin.pending` | systemOrange | In-flight save, > 500 m move warnings, cold-start escalation text |
| `color.admin.error` | systemRed | Validation + save failures |
| `color.admin.originalPin` | systemBlue at 40 % opacity, hollow circle stroke 2 pt | Original station position in editor |
| `pattern.confirmLargeMove` | `confirmationDialog`, destructive confirm labeled with verb + object (`Move Station`), message names line + affected edge count | Any edit whose spatial delta > 500 m |
| `pattern.saveButton` | idle `Save Change` → saving `Saving… + spinner` (disabled, ≥ 500 ms min) → 10 s escalation caption → success `Saved ✓` 600 ms → dismiss | All Admin remote writes |

Implement as a `DesignTokens.swift` (or the `BrandColors` enum branding.md proposes) + named colors in `Assets.xcassets`; reference by token name from both tabs.

---

## Files a fix will touch

**iOS (`/Users/obiee/Desktop/proj/CommuteBeh/CommuteBeh/`):**

| File | Why |
|---|---|
| `ContentView.swift` | Result-card hierarchy, transfer pill, suggestion display names, loading replacement, enter transitions, error-text rendering |
| `AdminRoutesView.swift` | Row Button conversion (P0 + accessibility), pluralization, mode grouping, line-sequence order, station id display, full editor rework (context overlay, Δ readout, dirty gating, save states, validation, large-move dialog, title) |
| `TransportMode.swift` | `extension TransportMode { color/icon/lineWidth }` consolidation; user-facing error strings (1028, 1037, 1041, 1067) |
| `APIError.swift`, `APIClient.swift` | Carry HTTP status + server message in errors (shared with backend-audit login fix) |
| *(new)* `DesignTokens.swift` + `Assets.xcassets` color sets | Token definitions above |
| `.claude/skills/branding.md` | Record the founding tokens (it asks to be updated when decisions land) |

**Out of this audit's scope but touched by shared tokens/messaging:** `LoginView.swift`, `SettingsView.swift`, `ExploreView.swift`.

---

## Open questions / assumptions

- **"Home tab" = Commute tab.** No Home tab exists; the prompt's naming caution was warranted. If a distinct Home/dashboard tab is planned, nothing here presumes it.
- **Deploy gap, flagged not re-audited:** the deployed Render backend returns **404 for `PATCH /api/v1/admin/stations/:id`** (verified by direct curl with an admin token). The accepting-both-param-shapes fix exists in `commutebeh-rails` **only as an uncommitted working-tree change** (`git diff app/controllers/api/v1/admin/stations_controller.rb`), and the iOS contract fixes are likewise uncommitted in the CommuteBeh working tree. "Backend fixed" currently means "fixed on this machine" — commit + deploy before any Admin-save UI polish can be verified end-to-end.
- **Partially-applied client fixes:** `GraphService.syncIfNeeded` in the working tree still compares a `String` version and writes raw response bytes to Documents without validation — backend-api-audit R1/R2's client half appears incomplete. Out of scope here; noted so the UI pass isn't blamed for stale-graph symptoms.
- **Test admin account created:** `ui-audit@commutebeh.ph` (role promoted to admin via Supabase SQL) now exists **in the production database** for this audit. Remove or demote it if unwanted: `UPDATE users SET role = 0 WHERE email = 'ui-audit@commutebeh.ph';` (or `DELETE`). The simulator has its (since-rotated) session cached.
- **Loading-overlay finding is behavioral, not visual:** the overlay could not be captured because the computation outpaces it; the "flash" characterization derives from tap-to-screenshot timing, not a rendered frame.
- **Row-tap bug environment:** verified on iOS 26.4 simulator with HID-level taps (`idb`), cross-checked against tab bar / back button / NavigationLink rows all responding to identical taps. Assumed to reproduce on device (the mechanism — content-hugging `contentShape` — is layout, not input-stack, dependent).
- **Both prior audits were static** (polyline-audit: "No app run / no screenshots"); this is the first pass that has actually operated the Admin editor, which is why the tap-target and 40-s-spinner findings are new.
- **`AdminRoutesView.swift` is untracked** in git (`??` status) — the entire Admin tab is unversioned work. Commit it before iterating.
