# Views

Reusable SwiftUI components for the Commute tab's map layer and search UI. Not full screens
(the screen itself is `ContentView.swift`, one level up) and not cards (see `../Cards`).

## CommuteMapOverlays.swift

- **`PassengerPuck`** — the orange dot placed inside a MapKit `UserAnnotation` or `Annotation`.
  Pulses with an idle "breathe" animation while `speed` reads below a walking threshold, and
  stops as soon as movement is detected.

## RoutePolylineRendering.swift

Map-content helpers (`@MapContentBuilder` functions) and the `RouteGeometry` model they draw
from. Split out of `CommuteMapOverlays.swift` because these aren't `View`s — they're MapKit
content builders and a plain geometry cache, a different responsibility from the three views
above even though everything here also renders onto the map.

- **`RouteGeometry`** — precomputes each leg's polyline coordinates and the route's bounding
  box once per `RouteResult`, so `ContentView.body` isn't remapping hundreds of walk-leg points
  on every re-evaluation. Also precomputes `sharedWithNextMask(leg:)` — see below.
- **`splitPolyline(_:at:)`** — projects the passenger's coordinate onto a polyline and splits it
  into the traveled and remaining halves.
- **`RouteGeometry.gridIndexAhead(leg:passenger:step:)`** — the index of the first multiple of
  `step` metres from the leg start at or past the passenger. Returns `nil` when the leg has no
  geometry or the passenger is at the leg end.
- **`RouteGeometry.walkChunk(leg:index:step:)`** — the part of a leg between two chunk
  boundaries. A chunk is `walkChunkSteps` grid steps long, so boundaries stay on a fixed ground
  grid. The last chunk ends at the leg end. `walkChunkCount` gives the number of chunks.
  These live in `RouteGeometry+WalkChunks.swift`.
- **`flatRoutePolyline(coordinates:mode:width:color:)`** — a single flat stroke in the leg color. Every
  polyline whose coordinates can change from one `body` evaluation to the next must draw this
  way. `MapPolyline` wraps an immutable `MKPolyline`, so a coordinate change swaps the whole
  `MKOverlay` rather than moving a point, and each swap redraws asynchronously on its own
  schedule; two overlays sharing a coordinate source that changes every frame race each
  other's redraw and visibly desync — the wider casing trailing or leading the narrower core.
  A coarser-cadence twin of the source was tried for the live leg and still raced often
  enough to stay visible, since `body` re-evaluates at the source's full rate regardless of
  how rarely one layer's own value actually changes — so nothing short of a single overlay is
  safe for an animating polyline.
- **`casedRoutePolyline(coordinates:mode:)`** — the two-layer stroke a *settled* route
  polyline draws with instead: a white casing (`mode.lineWidth + 4`) beneath the mode's
  saturated core (`mode.lineWidth`), matching Apple Maps' own route line. Only for coordinates
  that won't change on the next `body` evaluation — see `flatRoutePolyline` for why an
  animating one can't use this.
- **`RouteGeometry.sharedWithNextMask(leg:)`** — per point on a leg's polyline, true where
  that point sits within `overlapThresholdMeters` (10 m) of the *next* leg's polyline: a
  walk-to-stop leg that runs along the same street the next leg's bus travels, for example.
  Exists because settled, non-animating cased polylines *still* flicker where two legs'
  geometry genuinely coincides — confirmed on a fully static screen, camera and reveal both
  idle, ruling out every timing-based cause `flatRoutePolyline` addresses. Two overlays
  occupying near-identical screen space compete for the same pixels on every render pass with
  no guaranteed winner, which is a rendering/z-order limitation, not a coordinate-change race,
  and needs a different fix: don't draw both overlays over the same space at all.
- **`splitByMask(_:mask:)`** — splits a coordinate array into contiguous runs by a parallel
  boolean array, each run sharing its boundary point with the next so they still join without
  a gap (the same technique `splitPolyline` uses for its own behind/ahead halves).
- **`offsetCoordinates(_:metersToTheRight:)`** — shifts a polyline sideways by a fixed
  distance, in flat lat/lng space with the same latitude-scale correction `arcCoordinates`
  uses. Backs `sharedHintPolyline`.
- **`sharedHintPolyline(coordinates:color:)`** — a thin dashed line in the leg's own color,
  offset `sharedHintOffsetMeters` (5 m) to the side of a stretch marked shared in
  `sharedWithNextMask`. The earlier leg's normal stroke isn't drawn there at all — the later
  leg's cased polyline already occupies that space — but the offset keeps this hint from
  recreating the exact near-coincident-overlay conflict it exists to avoid, while still
  showing the passenger that a leg continues alongside the one on top.
- **`maskedRoutePolyline(coordinates:mask:mode:)`** — `casedRoutePolyline`, except a run
  marked shared by `splitByMask` draws as `sharedHintPolyline` instead. Falls back to a single
  unsplit `casedRoutePolyline` when `mask` is `nil` or doesn't match `coordinates`' length —
  the route's last leg has no next leg to compare against, so never has a mask.
- **`RouteGeometry.matches(_:)`** — true only when each leg has the same id, polyline point
  count, first coordinate, and last coordinate as when the geometry was built. It does not
  compare whole arrays, because it runs on every `body` evaluation. A walk leg that keeps its
  id but gets a new polyline makes it return false.
- **`routePolylineContent(leg:coords:isAnimating:sharedMask:)`** — draws one leg's polyline in
  full, for the non-commuting route preview and every leg still ahead in Commute Mode.
  `isAnimating` is true only while *this leg's own* coordinates are still growing during the
  pre-commute reveal (`ContentView` compares the revealed count against the full count per
  leg, since legs finish revealing at different times) — true routes to `flatRoutePolyline`
  (ignoring `sharedMask`, which is only valid against the full, untrimmed polyline), false to
  `maskedRoutePolyline`.
- **`currentLegPolylineContent(leg:coords:passenger:geometry:walkGridStep:)`** — draws only the
  portion of the passenger's current leg still ahead of them, always via `flatRoutePolyline` —
  this polyline's coordinates are re-cut from the live passenger position up to 30 times a
  second. A walking leg splits into chunks on a `walkGridStep` grid, and draws one overlay per chunk from the
  passenger's chunk to the leg end, keyed by chunk index. A chunk keeps its coordinates while the
  passenger advances, so MapKit never swaps an overlay and no frame loses its dots. No two overlays
  draw the same ground, so dots of different overlays never merge. Each chunk starts a dot at its
  own start, so the dots stay fixed to the ground. The puck covers the part of the chunk behind it. A solid leg cuts at the exact passenger position. Without a `walkGridStep` a walking leg cuts exactly.
  The traveled portion is dropped. On a walk leg with real geometry, a single dotted
  connector (`walkConnector`) runs from the passenger to the nearest point on the line,
  so it never overlaps the walk overlays. It exists because the passenger dot shows the real position, which is off the path. It is
  skipped under 2 m. Not `maskedRoutePolyline`: the live leg
  is always the *earlier* one from its own perspective and `flatRoutePolyline` is already a
  single overlay, so there's nothing here for the mask to protect against.
- **`completedLegPolylineContent`** — draws each leg the passenger has finished in `.faint`,
  flat and without casing. Walk legs keep their dots.
- **Line spec** — `DesignTokens.RouteLine`: a ride leg uses the graph line color, or the mode color when the line has none. A walk leg uses the walk color.
  `RouteStore.legColor(_:)` gives the color. The core is 6 pt and has a 2 pt `.canvas` casing on each side. The current leg is 7 pt. Walk legs are 5 pt round dots on a
  9 pt pitch with no casing (`RouteLine.walk`). Station connectors are 1.5 pt solid black
  (`RouteLine.connectorStyle`).

## StationAccessConnector.swift

- **`stationAccessConnector(station:nearestTo:)`** — the thin solid arrowed line from a station's
  access point to its routing centroid, when they differ.
- **`stationAccessConnectors(legs:)`** — `stationAccessConnector` once per station across `legs`.
  A transfer station ends one leg and starts the next, and draws one connector.
- **`bearingDegrees(from:to:)`** — compass bearing between two coordinates.

## CommuteSearchPanel.swift

The origin/destination search panel shown at the top of the map before a route is selected —
collapsed pill and expanded card states, with the address/station suggestion fields.

The collapsed top bar is a `GlassEffectContainer` that holds a 44 pt glass circle back button
and a 44 pt glass capsule. The capsule shows the origin ring dot, origin text, an arrow, the
destination square, and destination text.

The expanded card is a Liquid Glass rounded rectangle (`glassEffect`, `Radius.card`). The
`SavedPlacesRow` sits 12 pt under it.

## RouteChoiceMapContent.swift

**`routeChoiceMapContent(_:legColor:onSelect:)`** — a `@MapContentBuilder` that draws each leg in
its `RouteStore.legColor(_:)` color. Every route option draws its line. Only the selected route
draws its stop markers and its time bubble. The selected route draws last. At rest it has a `.canvas` casing, width 6, and a dotted
walk leg. An alternate is flat, width 4, opacity 0.26. A route that is still revealing or
tweening draws flat.

## RouteChoiceAnnotations.swift

- **`RouteTimeBubble`** — capsule with the route time inside a 44 pt button. The selected
  bubble uses `Onyx` and scale 1.08. The others use `Graphite` at opacity 0.72.
  The bubble edge is a `Smoke` ring, and the bubble has no shadow.
  It also scales by `frame.zoomScale`, with a floor of `RouteAnnotationScale.floor` (0.6).
  Its coordinate is `bubbleCoordinate`. The bubble sits beside the route line, inside the
  visible map area, clear of the stop markers. See `Commute-State.md`.
- **`RouteStopMarker`** — destination or transfer marker in a 44 pt button. Alternate
  routes show it at opacity 0.5. The destination is `DestinationPin`, the SF Symbol `mappin` in `Onyx`. The commute map uses the same view. Its
  annotation anchors at `.bottom`, so the pin tip sits on the coordinate. The pin scales like
  the bubbles, with anchor `.bottom`. Transfer markers anchor at the centre and
  keep their size.

Bubbles and markers are flat. Both views select their route on tap and carry accessibility labels.

## SuggestionList.swift

The dropdown list of station/address suggestions shown under a focused search field, backed by
`LocationSuggestion` (see `../State/LocationSearch.swift`).

## ViewEffects.swift

Small, general-purpose view components used across the Commute tab, not specific to any one
card or panel:

- **`ReelSwap`** — a two-state label that swaps by sliding vertically, like a mechanical reel.
- **`LabelBadge`** — the FASTEST/CHEAPEST solid-fill badge.
- **`JustifiedLabel`** — a `UILabel` bridge for justified text alignment, which SwiftUI's `Text`
  cannot produce natively.

(`JellyEffect`, a `ViewModifier`, used to live in this file — it now lives in `../Modifiers`.)

## SavedPlacesRow.swift

**`SavedPlacesRow`** — the chip row under the expanded search card. It shows one chip per
`SavedPlace` in `SavedPlacesStore`, then the Add Place chip, which opens `AddPlaceSheet`. The
row shows only with the expanded card, and hides while a suggestion list is open. It sits
outside the `measuresVisibleTop` view, so it does not move the map strip edge.

- The saved-place chips use `.glassEffect(.clear)` without `.interactive()`. Interactive glass
  tracks the touch itself, so the row's scroll pan and the vertical pull pan cannot start on a
  chip. The pinned Add Place chip sits outside the scroll view and keeps interactive glass.
- A chip is selected while `destinationCoordinate` and `confirmedDestLabel` equal the place's
  coordinates and name. A manual edit, a clear, or a swap changes one of them and deselects it.
- A tap sets the destination through `setDestinationCoordinate`, then sets the label and
  `destinationText` to the place name. A tap on the selected chip calls `onClearDestination`.
- A tap that selects a place also runs `onSearch`, the same action as Search Route, when
  `routeStore.canCalculate` is true. Without a start point it only fills the destination.
- Every chip keeps its intrinsic width. The Add Place chip stays pinned at the trailing edge
  and never scrolls. The saved places sit in a horizontal `ScrollView` that spans the row and
  runs under Add Place. The scroll content has a trailing margin of the Add Place width plus
  the chip gap, so no chip rests behind Add Place.
- The row shows the places newest to oldest, left to right, so the oldest place sits next to
  Add Place. The store order does not change. The scroll view rests at its trailing end
  (`defaultScrollAnchor(.trailing)`) and does not scroll when a place is added.
- While any chip is behind Add Place (the offset is more than 4 pt from the trailing end),
  Add Place gets a `secondarySystemBackground` fill at 0.92 opacity. The fill fades out at rest.
- The search panel pads the row by 16 pt. The row cancels that padding, so the chips scroll to the
  screen edge. The scroll content has 16 pt margins, and Add Place keeps its place under the card edge.
- The row has no `GlassEffectContainer`, so the glass of a chip behind Add Place does not blend into it.

### Drag to delete

A pull lifts a saved-place chip, and a hold opens its edit sheet. A SwiftUI drag cannot refuse a
touch by direction, and it would take the horizontal touches that the row needs to scroll. So the
pull uses one UIKit pan for the whole row.

- **Pull:** one `UIPanGestureRecognizer`, added to the row's `UIScrollView` by
  `SavedPlacesPanInstaller`. It begins only when the touch started on a chip and the first travel is
  mostly vertical. Then the chip lifts, with a light haptic. A horizontal start fails the pan, so the
  row scrolls. The scroll view's own pan waits for this pan to fail.
- **Hold:** a `LongPressGesture` of 0.3 s that fails after 10 pt of travel. It gives a light haptic
  and opens the edit sheet. It does not start a drag. It has no `updating` press state: a press
  state makes the gesture active at touch-down, and an active SwiftUI gesture stops the scroll pan
  and the pull pan. The hold guard clears when the edit sheet closes.

The row disables scrolling while a drag runs. A tap during a hold or drag, or within 0.3 s after it,
does not select the chip. Each chip has the accessibility actions "Edit" and "Remove". The Add Place
chip does not drag. Saving an edit of the selected place refreshes the destination, without a search.

- **`SavedPlaceDragState`** — `@Observable @MainActor`. Holds the dragged place, the finger
  position, the return point, the hover flag, and the global frame of each chip. `ContentView` gets
  it from `savedPlaceDragHost()`, which puts it in the environment. All frames use the global space.
- **`SavedPlaceDragSource`** (`savedPlaceDragSource(place:onEdit:)`) — the hold gesture and the
  row slot of one chip. The slot is the chip plus a 6 pt gap on its left. It has no clip, so the
  glass of a pressed chip keeps its rounded edge. The chip is invisible while it is dragged.
- **`SavedPlacesPanInstaller`** — the `UIViewRepresentable` that finds the enclosing `UIScrollView`
  and owns the pan. It reports window-space locations, which equal the global space.
- **`SavedPlaceDragOverlay`** — draws the moving chip and the delete target above the screen.
  It takes no touches. The chip is scaled to 1.08 and uses the finger position, so the
  row's ScrollView does not clip it.
- **`SavedPlaceChipLabel`** — the chip content. The row and the overlay share it. The title is
  one line, at most 90 pt wide, and ends in an ellipsis when it is longer.

The slot collapses to zero width while the chip center is outside the row (20 pt vertical slop).
`SavedPlaceDragState.collapsedPlaceID` changes only inside `withAnimation(slotAnimation)`, so the
neighbors and the scroll offset slide in the same transaction as the slot. The `cardEnter` spring
runs the slot, the neighbors and the returning chip, so they land together. The slot stays open while the chip
is inside the row. The target shows at the same time. It is a 64 pt Liquid Glass circle at the
bottom center, above the safe area. A chip within 56 pt of the target center hovers: the target
grows to 1.15 and turns `Color.vermilion`.

- **Release on the target:** the chip flies into it over 0.25 s, then calls `onDelete` with
  animations disabled. The slot is already closed and the chip is hidden, so the row does not jump
  and the chip does not flash. The "Remove" accessibility action animates the removal.
- **Release elsewhere:** the slot reopens and the chip flies to the slot with the same spring.
  The chip aims at the live slot position (`returnCenter`), so both end on the same frame.
- **Edit saved:** `SavedPlacesRow.update` runs inside `withAnimation(slotAnimation)`. The slot
  measures its width and animates changes of it (`setSlotWidth`). `SavedPlaceChipLabel` swaps the
  icon with `.symbolEffect(.replace)` and the title with `.interpolate`. Reduce Motion uses a fade.
- **Reduce Motion:** the chip fades in place and does not travel. The slot and the row use a
  0.15 s ease-out.
