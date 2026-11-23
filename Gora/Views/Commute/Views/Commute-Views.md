# Views

Reusable SwiftUI components for the Commute tab's map layer and search UI. Not full screens
(the screen itself is `ContentView.swift`, one level up) and not cards (see `../Cards`).

## CommuteMapOverlays.swift

- **`PassengerPuck`** — the orange dot that `HostedAnnotationView` hosts in the system
  user-location view and in the snapped-puck annotation.
  Pulses with an idle "breathe" animation while `speed` reads below a walking threshold, and
  stops as soon as movement is detected.
- **`TransferNode`** — the dot that marks where a route changes leg.

## RoutePolylineRendering.swift

The `RouteGeometry` model and the polyline helpers that `Map/RouteLineBuilder.swift` uses. The
files in `../Map` turn them into overlays. See `../Map/Commute-Map.md`.

- **`RouteGeometry`** — precomputes each leg's polyline coordinates and the route's bounding
  box once per `RouteResult`, so `ContentView` isn't remapping hundreds of walk-leg points
  on every re-evaluation. Also precomputes `sharedWithNextMask(leg:)` — see below.
- **`RouteGeometry.revealSpan(leg:points:)`** — the part of the whole route's length that a leg,
  or a run of its points, covers, as two fractions. `legStartOffsets`, `legCumulativeDistances`
  and the total length give the numbers. `RouteLineRenderer` maps the draw-on fraction to
  `strokeEnd` with it. A route with no length returns nil and draws in full.
- **`splitPolyline(_:at:)`** — projects the passenger's coordinate onto a polyline and splits it
  into the traveled and remaining halves.
- **`RouteGeometry.sharedWithNextMask(leg:)`** — per point on a leg's polyline, true where
  that point sits within `overlapThresholdMeters` (10 m) of the *next* leg's polyline: a
  walk-to-stop leg that runs along the same street the next leg's bus travels, for example.
  Two overlays occupying near-identical screen space compete for the same pixels on every
  render pass with no guaranteed winner, which is a rendering limitation, not a coordinate-change
  race. So the builder does not draw both overlays over the same space.
- **`splitByMask(count:mask:)`** — splits a polyline of `count` points into contiguous runs by
  a parallel boolean array. Each run is an index range that shares its boundary point with the
  next, so the runs still join without a gap. A mask of another length gives one run.
- **`offsetCoordinates(_:metersToTheRight:)`** — shifts a polyline sideways by a fixed
  distance, in flat lat/lng space with the same latitude-scale correction `arcCoordinates`
  uses. Backs the shared-segment hint.
- **`RouteGeometry.matches(_:)`** — true only when each leg has the same id, polyline point
  count, first coordinate, and last coordinate as when the geometry was built. It does not
  compare whole arrays, because it runs on every scene build. A walk leg that keeps its
  id but gets a new polyline makes it return false.
- **Line spec** — `DesignTokens.RouteLine`: a ride leg uses the graph line color, or the mode color when the line has none. A walk leg uses the walk color, `Color.cocoa`.
  `RouteStore.legColor(_:)` gives the color. The core is 6 pt and has a 2 pt casing on each side. The casing is the line color at 0.65 brightness in light mode, lowered further until it has 3:1 contrast against white (`Color.routeCasing`). In dark mode it is `.canvas`. The current leg is 7 pt. Walk legs have a 4 pt core with round cap and join
  (`RouteLine.walkStyle`) and the same 2 pt casing. `RouteLine.casingStyle(for:)` gives the casing stroke for each mode. Station connectors are 1.5 pt solid black
  (`RouteLine.connectorStyle`).

## StationAccessConnector.swift

- **`stationAccessConnectors(legs:)`** — one connector per station across `legs`. A transfer
  station ends one leg and starts the next, and draws one connector. It returns the line
  descriptors (a thin solid arc from the station's access point to its routing centroid) and the
  descriptors of the arrow tips. A station whose access point and centroid match has none.
- **`bearingDegrees(from:to:)`** — compass bearing between two coordinates.

## CommuteSearchPanel.swift

The origin/destination search panel shown at the top of the map before a route is selected —
collapsed pill and expanded card states, with the address/station suggestion fields.

The collapsed top bar holds a 44 pt glass circle back button and a 44 pt glass capsule. The capsule shows the origin marker, origin text, an arrow, the
destination marker, and destination text.

Both markers use one shape, `marker(ring:center:size:id:)`: a filled circle with a 2 pt
`strokeBorder` ring on the same circle, so the ring and the center stay concentric. The origin
marker is 11 pt, with a Canvas ring and a Tangerine center. It is 1 pt larger because its Canvas
ring is close to the card color, so it otherwise looks smaller. The destination marker is 10 pt,
with an Onyx ring and a Canvas center. Canvas is white in light mode and near-black in dark mode,
and Onyx is the opposite. Keep the sizes and the ring width in whole points. A ring with a
fractional pixel width draws thicker on one side. The card, the pill, and the moving layer draw the same marker.

The card and the pill share one persistent surface in `CommuteSearchPanel`. The private
`SearchPanelMode` enum (`expanded`, `collapsed`) selects the content, the corner radius, the tint
opacity, the surface width, and the back button through exhaustive switches. The surface is a
`RoundedRectangle` with `goraGlass`. When the mode changes, the spring changes the surface size, so
the glass shrinks to the pill and grows back.

The surface is a `Color.clear` frame sized from measured values: the card height (measured with
`onGeometryChange` while the card shows) and the pill size (measured by a hidden pill before the first collapse). The card or pill content sits in an overlay. Do not
size the surface from the content itself: during a transition SwiftUI keeps the outgoing and the
incoming content in the layout together, so the surface would take the larger size, the card, and
the morph would become a fade, with a dark card-sized surface appearing at once on expand. The corner radius runs from `Radius.card` to half the
pill height, and the width runs from full width to the pill width. One `Glass` value serves both
modes, and the charcoal tint fades to zero when collapsed. The panel has no `GlassEffectContainer`,
so each glass shape follows its own animated frame. Removed content fades out in 0.15 s. Inserted
card content and the extras below the card fade in after the surface grows, so no content shows on a
small surface. The back button appears left of the pill with a scale and fade.
The two markers and the two texts move in a separate layer, `movingContent`, drawn above the
fading content. The card rows and the pill report the frame of each marker and text, keyed by
`SearchGeometryID`, in `cardFrames` and `pillFrames`. From the start of a mode change until the
spring rests (`Motion.settleDuration`), the layer draws them and the card and the pill hide theirs
with `snapsOpacity`. The layer moves each one from its card frame to its pill frame, and back, with
the surface spring. One animatable progress value (`MorphEffect`) sets the position and the
scale of every item, so all items arrive together. It draws the card font and scales it to the pill font size. The `TextField` hides
its text during the move, and keeps its placeholder when the field is empty. After the card settles,
the `TextField` shows its text and the layer hides. An empty text draws nothing, so nothing moves.
With Reduce Motion on, the layer stays hidden, and the surface is replaced and cross-fades, with no
size change.

- `SearchMovingLayer.swift` — the layer that moves the markers and texts between the card and the pill.
- `SearchPanelMode.swift` — the `expanded` and `collapsed` panel modes, with the surface radius and tint of each.
- `SearchFieldAccessory.swift` — the trailing spinner or clear button of a search field row.
- `SearchFieldSeparator.swift` — the hairline between the origin and destination rows, and the dotted rail between their markers.
- `SearchSuggestionDropdown.swift` — the search results in a Liquid Glass list below the search card, and the "No Results" state.

The expanded card is a Liquid Glass rounded rectangle (`DesignTokens.Materials.cardGlass`, `Radius.card`). The
`SavedPlacesRow` sits 12 pt under it.

The card has two parts: the fields group and Search Route.

- The swap button sits in the fields group, on the trailing edge, centered on the divider. It is a
  secondary control: a 36 pt `secondaryActionFill` circle with a `secondaryAction` symbol, in a 44 pt
  target. Search Route is the only filled button, and it fills the card width.
- One trailing control shows at a time. With no focus, the swap button shows. A focused field shows its
  clear button, and the swap button fades out. A resolving field shows its spinner, and the swap button
  also fades out.
- While a field has focus, Search Route folds away, and the tab bar and Simulate MRT fade out. The
  saved-place chips stay, and Add Place fades out so the chips use its space. The whole saved-places row
  hides only while the results list or No Results shows. The results list grows from the card (opacity, 97 % scale, 10 pt from above, 0.38 s spring).
  Reduce Motion fades only.
- Each result row shows a symbol in a 28 pt circle with the destination marker colors (`Color.onyx` fill,
  `Color.canvas` symbol: black and white in light mode, the reverse in dark mode), the name
  in 15 pt type-scale Body with the typed letters in semibold, and the distance and line or area in 13 pt Subtitle. The list shows up to 8 rows and
  scrolls when they do not fit. A tap plays a light haptic. Search Route plays a heavy haptic.
- The keyboard key reads Done. Done drops the focus and removes the results list. The field keeps its text.
- "No Results" shows when the field text has had no rows for 0.8 s, so it does not flash while the
  address search runs.
- A swap slides the two texts past each other and turns the symbol 180 degrees. Reduce Motion
  cross-fades the texts, and the symbol does not turn. Each swap plays a light haptic, and VoiceOver
  announces the new start and destination.

The panel binds its fields to `routeStore.originText` and `routeStore.destinationText`. The swap,
clear, and suggestion actions call `RouteStore` methods in `../State/RouteStore+Endpoints.swift`
directly. After a suggestion applies, the panel sets the focus: an origin moves the focus to the
destination field, and a destination clears the focus. The panel has two closures only, `onBack`
and `onSearch`, because both actions also move the map camera, which `ContentView` owns.

## Route choice lines

`RouteLineBuilder.choiceLines(_:legColor:)` in `../Map` builds the lines. Each leg draws in its
`RouteStore.legColor(_:)` color. Every route option draws its line. Only the selected route
draws its stop markers (`RouteAnnotationBuilder.choiceAnnotations`). Every route draws a time
callout. The selected route draws last. Every route draws a 6 pt core and 4 pt walk legs, each
with a `Color.routeCasing` casing. A selection change does not change the casing or the width.
Only the core color changes: the selected route uses its leg colors, and an alternate uses the
faded `routeAlternate` blend at strength 0.3. The casing and the core of a leg carry the same
reveal span, so both grow together during the draw-on.

## RouteChoiceAnnotations.swift

- **`RouteCallout`** (in `RouteCallout.swift`) — rounded rectangle with a pointed tail at one
  corner, in a 44 pt or larger button. Line 1 is the travel time. Line 2 is the option label.
  The tail tip is the annotation anchor (`RouteCalloutCorner.unitPoint`), so the tip sits on
  the route line. `HostedAnnotationView` scales it by `zoomScale` (floor 0.6) about the tip.
  The selected callout uses `Onyx` fill, `Canvas` text, and full opacity. Each other
  callout uses `Graphite` fill, primary and secondary text, a 1 pt `Smoke` border, opacity 0.85,
  and a smaller size. It has no shadow. `RouteCalloutShape` draws the outline and
  `RouteCalloutMetrics` holds the sizes that placement also uses. See `Commute-State.md`.
- **`RouteStopMarker`** — destination or transfer marker in a 44 pt button. Alternate
  routes show it at opacity 0.5. The destination is `DestinationPin`, the SF Symbol `mappin` in `Onyx`. The commute map uses the same view. Its
  annotation anchors at `.bottom`, so the pin tip sits on the coordinate. The pin scales like
  the callouts, with anchor `.bottom`. `HostedAnnotationView` applies that scale as a
  transform, not the view. Transfer markers anchor at the centre and keep their size.

Callouts and markers are flat. Both views select their route on tap and carry accessibility labels.
`HostedAnnotationView` hosts them, and the map selects the annotation on a tap. See `../Map/Commute-Map.md`.

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

- The saved-place chips and the pinned Add Place chip use `goraGlass(.regular.interactive(), in: .capsule)`.
  The press effect of the glass grows past the chip, so the chip scroll view does not clip its content.
- A chip is selected while the origin or the destination holds the place: its coordinate and
  confirmed label equal the place's coordinates and name. A manual edit, a clear, or a swap deselects it.
- A tap calls `routeStore.fill(_:with:)` for the origin when the origin field has focus, and for the
  destination otherwise. After an origin fill, focus moves to the destination. After a destination fill, focus clears.
  A tap on a chip that already fills the target field calls `routeStore.clear(_:)` for that field.
- A tap that selects a place only fills a field. It does not start a search; the
  passenger taps Search Route.
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
- The chip scroll view has `scrollClipDisabled()`, so a chip shadow (glass fallback) and the press effect of interactive glass draw outside the row height instead of being cut to a rectangle.

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
chip does not drag. Saving an edit of a selected place refreshes each field that holds it, without a search.

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

## LocationOffBanner.swift

**`LocationOffBanner`** is the Liquid Glass banner that says Location is off. It has a 56 pt minimum height,
a 28 pt corner radius, and the padding 6 (top), 14 (leading), 6 (bottom), 6 (trailing). The glass is a
background layer (`goraGlass` with `Materials.cardGlass`). The content is the `location.slash` symbol, the
title "Location is off", a one-line subtitle, a Turn On capsule, and an optional Dismiss button. Turn On
uses the title font (`subtitleEmphasis`) with a 44 pt minimum height. The subtitle scales down to 80 % before it
wraps, and wraps freely at accessibility sizes. A non-nil `onDismiss`
shows Dismiss. Turn On sets `RouteStore.isTurnOnLocationAlertPresented`. At accessibility text sizes the
buttons move under the text. The banner is one accessibility group with the label "Location is off. <subtitle>".
Turn On and Dismiss stay separate buttons.

## CommuteMapOverlays.swift: StepStartNode

**`StepStartNode`** is the hollow circle at the start of the current step: a `Color.canvas` fill with a 3 pt
`Color.onyx` ring, 12 pt across. It shows only while Location is off.
