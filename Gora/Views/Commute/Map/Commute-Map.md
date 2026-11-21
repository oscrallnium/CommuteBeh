# Map

The Commute tab map is one `MKMapView` inside a `UIViewRepresentable`. The SwiftUI `Map` cannot
draw a polyline on with `strokeEnd`, so the map moved to UIKit. Explore and the Admin maps still
use the SwiftUI `Map`.

## Data flow

`ContentView.mapLayer()` returns `CommuteMapLayer`. Its `body` calls `commuteMapScene()`, which
builds a `CommuteMapScene` from the observed state. `CommuteMapView.updateUIView` passes the scene
to `CommuteMapCoordinator.apply(_:)`. The coordinator diffs the scene against the map by id.

Read every 30 Hz value (the puck, the emphasis tween) inside `commuteMapScene()`. A read in
`ContentView.body` re-evaluates the panels and the sheets at that rate.

## Files

- **`CommuteMapScene`** — the value type for one frame: `RouteLineDescriptor` list (bottom to
  top), `AccuracyCircleDescriptor`, `MapAnnotationDescriptor` list, and the `UserDot` state.
- **`RouteLineBuilder`** — builds line descriptors for route choice and for a single route.
- **`RouteAnnotationBuilder`** — builds annotation descriptors for the same two cases.
- **`CommuteMapView`** — the representable. It sets `MKStandardMapConfiguration` with
  `pointOfInterestFilter = .excludingAll`, and hides the compass and the scale.
- **`CommuteMapCoordinator`** (and `+Overlays`, `+Annotations`) — the delegate. It owns the
  overlays, renderers, annotations, and the tap and long-press recognizers.
- **`CommuteMapController`** — `ContentView` holds it. It writes the camera and converts between
  points and coordinates in the map view's own space.
- **`RouteLineOverlay`**, **`RouteLineRenderer`**, **`ResolvedStroke`** — the overlay that
  carries a stroke and a reveal span, its renderer, and a stroke resolved for one appearance.
- **`HostedAnnotationView`**, **`CommuteAnnotation`**, **`AnnotationContentView`** — the
  annotation model and the view that hosts the existing SwiftUI views.

## Overlays

- A descriptor id stays the same while its line stays on the map. The coordinator builds a new
  overlay only when the `CoordinateSignature` (count, first point, last point) changes. Then
  `insertOverlay(_:above:)` and `removeOverlay(_:)` swap it at the same place, so the order holds.
- Color, width, dash, and reveal span change in place on the renderer. The renderer redraws only
  when a resolved value changed. Colors resolve against the map's `traitCollection`, and a change
  of `userInterfaceStyle` restyles every renderer.
- `MKMapView.overlays` matches the scene order, then the accuracy circle. After a diff, the
  coordinator removes every overlay from the first one that is out of place and adds the rest in
  order. A renderer survives the move, because `rendererFor` returns the cached one.
- `RouteLineRenderer` subclasses `MKPolylineRenderer` and overrides no drawing method, so MapKit
  draws it as a GPU vector and `lineWidth` and the dash values stay fixed in screen points at every
  frame of a zoom. MapKit simplifies interior points at low zoom but keeps the end points of each
  line. Each leg is its own overlay, so the end of a leg stays on its stop. Any drawing override
  makes MapKit draw tiles, which lag on zoom.
- A leg has one casing overlay and one core overlay for the whole draw-on. Both carry the same
  `RevealSpan`, so they grow together. A stretch that runs along the next leg draws as a dashed
  hint, split by `RouteGeometry.sharedWithNextMask`.
- In Commute Mode the current leg's overlay is built again on each trim. It carries no reveal span.
- With Location off, `LegProgress.manual` draws every leg in full with a casing and a core. A finished leg
  draws at `RouteLine.doneOpacity` (35 %). The current leg draws 1 pt wider than the others. These lines
  set `LineStroke.animatesChange`, so `RouteLineRenderer.apply(_:tweenDuration:)` eases a change of opacity
  or width over `Motion.locationStateDuration`. Reduce Motion fades the opacity and changes the width at once.
  The renderer still overrides no drawing method.
- When `CommuteMapScene.isManualGuidance` changes, the lines crossfade over `Motion.locationStateDuration`. A line
  with the same id tweens its stroke. A new line starts at alpha 0 (`RouteLineRenderer.fadeIn`). A line that leaves
  stays under the new lines, fades out, and leaves the map when the fade ends.

## Draw-on

`RouteDrawAnimator` runs a `CADisplayLink` for 0.9 s with an ease-out curve. Each frame calls
`CommuteMapCoordinator.applyReveal(_:)`. For each renderer, `RevealSpan.strokeEnd(at:)` maps the
route fraction to the leg's share. The coordinator sets `strokeEnd` and calls `setNeedsDisplay()`
only on a renderer whose value changed. A renderer with a zero share has `alpha` 0, so the round
cap of an undrawn line shows no dot. See `State/Commute-State.md`.

## Selection redraw

`CommuteMapScene` carries `selectedRouteID` and `routeIDs`. In `apply(_:)`, before the overlay
diff, the coordinator compares the id with the last one it applied. A change between two routes
that are both on the map calls `drawAnimator.start()`. The first selection and a new search do
not restart it. The reordered overlays so never show fully drawn. The map tap, the annotation
tap, and the sheet binding all change `routeChoice.selectedID`, so all three take this path.

## Geometry redraw

In `apply(_:)`, before the overlay diff, the coordinator checks each line against its current
overlay. While `drawAnimator.isDrawing`, it calls `start()` when a line with a reveal span is new,
has new points, or has a new span. The legs then draw in order from the new spans. A change
after the draw-on ends does not restart it.

## Stop dots

An annotation descriptor can carry `revealAt`, a route fraction. A transfer marker or dot gets
`RouteGeometry.startFraction(of:)` of its leg. The destination gets 1. Each route uses its own
geometry. Route choice sets it on the selected route's stop markers, and the single-route view
sets it on the destination pin and the transfer dots. Callouts, connector tips, the puck and
Commute Mode annotations have none and show at once. `applyReveal(_:)` also runs
`revealAnnotations(at:): a view hides while the fraction is below `revealAt`, pops in with a
0.25 s spring when the draw crosses it, and hides again at once when the draw restarts. The
scale is a transform on the content and title about the anchor point, so `centerOffset` does
not change. A new or reused view reads `drawAnimator.fraction` in `configure`. A hidden dot takes
no taps. On a selection change `start()` runs before the annotation diff, so the new markers
start hidden.

## Annotations

- A descriptor carries `zoomScale`, outside `MapAnnotationContent`. A zoom step calls
  `HostedAnnotationView.setZoomScale(_:animated:)`, which scales the content about the anchor
  with a 0.25 s animation. It hosts no new view, so `centerOffset` and the pin tip stay fixed.

- `HostedAnnotationView` hosts an `AnnotationContentView` through `UIHostingConfiguration` with
  zero margins. It measures the fitting size and sets `centerOffset` from the anchor.
- The hosted view ignores touches. A tap selects the annotation, `didSelect` calls the route
  select closure and deselects at once. A VoiceOver activation runs the SwiftUI button action.
- An annotation view with no tap target has user interaction off, so a tap goes to the map. The
  tap and press recognizers ignore a touch that starts inside any `MKAnnotationView`.
- Every annotation uses `collisionMode = .none` and `displayPriority = .required`. `zPriority`
  orders them: connector tip, transfer dot, stop marker, destination pin, callout, selected
  callout, puck.
- With Location off, the scene has no user dot, no puck, and no accuracy circle. The annotation
  `stepStart` marks the start of the current leg with `StepStartNode`.
- The snapped puck is the annotation `snappedPuck`. Its coordinate changes on each glide tick
  with no animation.
- The system user-location view hosts `PassengerPuck`. With the snapped puck on the map, the
  view stays and draws nothing, because `showsUserLocation = false` would stop the location feed.

## Camera

`CommuteMapController.setCamera` and `setRegion` take a duration. A nil duration writes the
camera at once. A duration wraps a non-animated `setCamera` in `UIView.animate` with ease-in-out,
because `MKMapView` has a fixed animation time. `setRegion` first flattens the pitch and heading,
as the SwiftUI `.region` position did. `regionDidChangeAnimated` calls
`ContentView.cameraSettled(distance:)`, `recordObservedCamera(_:)`, and the DEBUG anchor update.

## Limits

- The Apple Maps logo and legal label sit at the bottom edge of the full-bleed map, behind the
  route sheet.
- The accuracy circle changes radius in steps. It has no ease.
