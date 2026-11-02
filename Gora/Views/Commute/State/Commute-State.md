# State

Non-UI logic that backs the Commute tab's search UI — services and state holders, not views,
cards, or modifiers. (`RouteStore` itself, the tab's main view model, lives in
`Domain/TransportMode.swift` — see the project's `CLAUDE.md` for why.)

## LocationSearch.swift

- **`LocationSuggestion`** — one row in the origin/destination suggestion dropdown: either a
  known `Station` or an `MKLocalSearchCompletion` address result.
- **`AddressSearchService`** — wraps `MKLocalSearchCompleter` to drive live address-suggestion
  search as the passenger types.
- **`RouteStore` extension** — the origin/destination confirmation and suggestion-list merge
  methods (`confirmOriginStation`, `confirmDestinationAddress`, `remergeDestSuggestions`, …)
  that `../Views/SuggestionList.swift` and `../Views/CommuteSearchPanel.swift` call into.
  The merged list holds address completions only. It adds station matches only when
  `NetworkStatus.isOnline` is `false`, and it re-merges when connectivity changes.

## RouteDrawAnimator.swift

- **`RouteDrawAnimator`** — ticks `revealedFraction` from 0 to 1 whenever a new route
  replaces the one on screen. `RouteGeometry.revealedCoordinates` in
  `../Views/RoutePolylineRendering.swift` trims each leg's polyline to that fraction, so
  `ContentView` draws the route on progressively from origin to destination.
  `RouteGeometry.cut(leg:gridIndex:step:)` in the same file cuts the current walking leg on a fixed ground grid
  for Commute Mode.
  A second `RouteDrawAnimator` in `ContentView` redraws the newly selected route from origin
  to destination when the passenger picks another option. Alternates stay fully drawn.

## RouteChoiceState.swift

- **`RouteChoiceState`** — `@Observable @MainActor` state for the route-choice phase. It holds
  `selectedID`, `isDetailExpanded`, and one entry per option: geometry, stop markers, and
  callout text, plus one callout spot per route (tip coordinate and tail corner). `sync(options:)` rebuilds the
  entries. A new set of option ids hides the callouts until `revealBubbles()` springs them in,
  60 ms apart.
- **`scheduleBubblePlacement(...)`** — waits 120 ms, then projects every route to screen
  points and calls `RouteCalloutPlacement`. The selected route goes first, then the others in
  option order. It stores one spot per route. A route with no valid spot has no callout.
  A callout with a new spot fades out for 0.15 s, moves while hidden, and fades in. A newer
  placement cancels the older one and ends with every revealed callout shown. `ContentView.placeRouteBubble()` calls it when the camera
  settles, when the selection changes, when `visibleTop` or `visibleBottom` changes, and after
  `sync`. The wait merges these calls into one.
- **Selection tween** — `select(_:)` runs a 0.3 s, 30 Hz tween. The new route rises from
  opacity 0.26 and width 5 to opacity 1 and width 7. The old route falls back. `frame(...)`
  marks every route flat while the tween runs, because MapKit does not interpolate strokes.
- **`frame(options:revealedFraction:selectedRevealedFraction:)`** — builds a `RouteChoiceFrame`: all routes,
  alternates first and the selected route last. Call it from `body`, not from the map content
  closure, so the reads register with the view's observation scope.
- **`zoomScale`** — one scale from the settled `cameraDistance`: 1 at 1500 m or closer, down
  to 0.35, in steps of 0.05. `RouteChoiceFrame.zoomScale` carries it. A frame with no routes
  carries 1, so `body` does not read `cameraDistance` in Commute Mode.
  Callouts and the destination pin use it with a floor of 0.6.
- **`selectFromAnnotation(_:)`** — sets a short window during which `handleRouteTap` ignores
  the map tap that arrives with a callout or marker tap.
- **`RouteBounds`** — a bounding box. `unionBounds` spans every option, and the camera fits it.

## RouteCalloutPlacement.swift

**`RouteCalloutPlacement.place(routes:avoid:visible:)`** — works in screen points. It samples
each route every 8 pt or more (300 samples at most). At each sample it tries the four tail
corners, with the sample as the tail tip. A spot is valid when all of these hold:

- The callout frame is inside the visible area, with an 8 pt margin.
- The frame is 36 pt or more from each stop marker of the selected route and from the origin end.
- The callout body is 3 pt or more from every line, own and other.
- The frame is 6 pt or more from each callout placed before it.

Routes are placed in the order given, selected first. The valid spot closest to the middle of
the visible part of the route wins. A later route takes only a spot on a stretch that is 24 pt or
more from the other routes, unless it has none. If no spot is valid, the route has no callout.

## RouteHitTesting.swift

**`RouteHitTesting`** — picks the route nearest a tap from screen-projected legs, within 22 pt.
On a tie the current selection wins.
