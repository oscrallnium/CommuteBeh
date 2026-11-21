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

## RouteStore+Endpoints.swift

- **`RouteStore` extension** — the search-field actions: `clear(_:)`, `swapEndpoints()`,
  `select(_:for:)`, and `closeResults()`. Each method changes model state only. The views set
  the focus and move the camera. `select(_:for:)` returns `false` when an address does not
  resolve, so the view leaves the focus where it is.

## RouteDrawAnimator.swift

- **`RouteDrawAnimator`** — a `@MainActor` object that draws a route on from origin to
  destination. A `CADisplayLink` runs for `duration` (0.9 s) and applies an ease-out curve
  (cubic). Each frame it stores `fraction` and calls `onFrame`, which `CommuteMapCoordinator`
  sets. The coordinator maps the fraction to a `strokeEnd` for each route renderer and calls
  `setNeedsDisplay()`. No frame builds an overlay or changes the scene.
  `RouteGeometry.revealSpan(leg:points:)` in `../Views/RoutePolylineRendering.swift` gives the
  part of the route that one overlay covers, from the leg start offset and the leg length.
- **`prepareForNewRoute()`** — sets `fraction` to 0 before a search, so the new route is
  empty when it arrives. **`start()`** runs the draw-on. `fitToRouteIfSuccessful` calls it after
  the camera fit, and `CommuteMapCoordinator.apply(_:)` calls it when the selected route changes to another route on the map, before the overlay diff, so every route
  redraws from origin to destination. A renderer that the map creates during a draw-on starts
  at the current `fraction`.
- **Draw-on timing** — `RouteStore.geometryPhase` is `.refining` while walk and zone-ride
  refinement runs, and `.final` after. `fitToRouteIfSuccessful` waits for `.final`, for at most
  `DesignTokens.Motion.geometryWaitCap` (1.5 s), then fits the camera and draws on. The traffic
  step changes times only, so it does not delay the draw. If a line gets new points while a
  draw-on runs, the coordinator restarts it. After the draw-on ends, new points do not replay it.

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
- **Selection tween** — `select(_:)` runs a 0.3 s, 30 Hz tween. The new route rises from the
  alternate strength 0.3 to 1. The old route falls back. Only the core color of each route line
  changes. The scene diff restyles the renderers in place, so no overlay is built again.
- **`frame(options:)`** — builds a `RouteChoiceFrame`: all routes,
  alternates first and the selected route last. Call it from a view `body`, as
  `CommuteMapLayer` does, so the reads register with the view's observation scope.
- **`zoomScale`** — one scale from the settled `cameraDistance`: 1 at 1500 m or closer, down
  to 0.35, in steps of 0.05. `RouteChoiceFrame.zoomScale` carries it. A frame with no routes
  carries 1, so the map layer does not read `cameraDistance` in Commute Mode.
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
