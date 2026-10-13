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

## RouteDrawAnimator.swift

- **`RouteDrawAnimator`** — ticks `revealedFraction` from 0 to 1 whenever a new route
  replaces the one on screen. `RouteGeometry.revealedCoordinates` in
  `../Views/RoutePolylineRendering.swift` trims each leg's polyline to that fraction, so
  `ContentView` draws the route on progressively from origin to destination.
  `RouteGeometry.cut(leg:gridIndex:step:)` in the same file cuts the current walking leg on a fixed ground grid
  for Commute Mode.

## RouteChoiceState.swift

- **`RouteChoiceState`** — `@Observable @MainActor` state for the route-choice phase. It holds
  `selectedID`, `isDetailExpanded`, and one entry per option: geometry, stop markers, and
  bubble text, plus `bubbleCoordinate` for the selected route. `sync(options:)` rebuilds the
  entries. A new set of option ids hides the bubbles until `revealBubbles()` springs them in,
  60 ms apart.
- **`scheduleBubblePlacement(...)`** — waits 120 ms, then projects the selected route to screen
  points and calls `RouteBubblePlacement`. It stores the result as `bubbleCoordinate`. A route
  with no valid spot has no bubble. `ContentView.placeRouteBubble()` calls it when the camera
  settles, when the selection changes, when `visibleTop` or `visibleBottom` changes, and after
  `sync`. The wait merges these calls into one.
- **Selection tween** — `select(_:)` runs a 0.3 s, 30 Hz tween. The new route rises from
  opacity 0.26 and width 5 to opacity 1 and width 7. The old route falls back. `frame(...)`
  marks every route flat while the tween runs, because MapKit does not interpolate strokes.
- **`frame(options:revealedFraction:)`** — builds a `RouteChoiceFrame`: all routes,
  alternates first and the selected route last. Call it from `body`, not from the map content
  closure, so the reads register with the view's observation scope.
- **`zoomScale`** — one scale from the settled `cameraDistance`: 1 at 1500 m or closer, down
  to 0.35, in steps of 0.05. `RouteChoiceFrame.zoomScale` carries it. A frame with no routes
  carries 1, so `body` does not read `cameraDistance` in Commute Mode. Walk dots use it as is.
  Bubbles and the destination pin use it with a floor of 0.6.
- **`selectFromAnnotation(_:)`** — sets a short window during which `handleRouteTap` ignores
  the map tap that arrives with a bubble or marker tap.
- **`RouteBounds`** — a bounding box. `unionBounds` spans every option, and the camera fits it.

## RouteBubblePlacement.swift

**`RouteBubblePlacement.center(path:avoid:visible:size:)`** — works in screen points. It samples
the selected route every 12 pt or more, and tries both sides of the line at each sample. A spot is
valid when all of these hold:

- The bubble is 14 pt or more from the line.
- The bubble is inside the visible area, with an 8 pt margin.
- The bubble is 44 pt or more from each stop marker and from the origin end.

The valid spot closest to the middle of the visible part of the route wins. If no spot is valid,
the function returns nil and the bubble hides.

## RouteHitTesting.swift

**`RouteHitTesting`** — picks the route nearest a tap from screen-projected legs, within 22 pt.
On a tie the current selection wins.
