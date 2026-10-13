# Commute

Root-level view state for the Commute tab: the map, its camera, and Commute Mode's live
tracking wiring. Subfolders have their own docs — `Cards/`, `Modifiers/`, `State/`, `Views/`.

## ContentView.swift

- **`wasBackgrounded`** / `scenePhase` handling — `.background` and `.active` are never
  adjacent values of the same `onChange` call; the system reports `.inactive` as its own step
  in both directions. `wasBackgrounded` tells "returning from a real background session" apart
  from "flicked through `.inactive` for a Control Center pull".
- **`autoSetOriginText`** / `wasBackgrounded` together re-open two seams a stale position
  otherwise gets stuck behind: the auto-filled origin field, and the resting camera. Neither
  has any other way to notice that time has passed and the passenger may have moved.
- **`cameraTransitionToken`** — identifies the transition `beginCameraTransition(_:)` most
  recently started. Changing it stops a running transition, which is how untracking cancels one.
- **`walkGridStep`** — ground metres that `RouteLine.walkPitch` points span at the puck. The
  follow loop measures it once per second through the `MapProxy`, and on a camera-mode change.
  The current walking leg cuts its line on this grid, so its dots do not move between cuts.
  See `ContentView+WalkGrid.swift`.
- **Map body — polylines per leg**: in Commute Mode the line only ever shows what's left —
  nothing for a leg already ridden, the live-trimmed leg for the current one, the full leg for
  everything ahead. Outside Commute Mode every leg draws in full.
- **Map body — route choice**: while `showsRouteChoice` is true the map draws every option
  through `routeChoiceMapContent` and skips the single-route legs and pins below. The existing
  long-press gesture sets the origin or destination. A `SpatialTapGesture` added with
  `simultaneousGesture` selects the nearest route. Both gestures read the same `MapReader` proxy.
- **Map body — update scope**: the `MapReader` closure holds only the `Map`, its gestures and the
  proxy `onAppear`. The map content reads `displayedPuckCoordinate`, which changes about 30 times a
  second, so the closure re-runs at that rate. The search panel, the route sheet, the commute
  sheet and every other modifier sit outside the closure and stay idle. Keep them outside.
  A custom `MapContent` type does not scope the read, because `MapContent` bodies do not track
  observed reads.
- **Map body — pins**: the map shows only the passenger's position and the destination. It
  draws no start pin.
- **Map body — GPS accuracy circle**: hidden while commuting, because it centers on the raw
  fix while the puck shows the track/route-snapped position — the two visibly diverge, and a
  snapped point's uncertainty isn't a 2D radius in the first place.
- **Map body — the passenger annotation**: outside commute, MapKit's own `UserAnnotation`
  tracks the raw fix. During commute it swaps to a plain `Annotation` at the snapped position,
  because the raw fix can sit off the polyline. The invisible `UserAnnotation` stays in the
  tree regardless — removing it is the only way to stop MapKit's location feed.
- **Auto-set origin** (`onChange(of: routeStore.userLocation, initial: true)`) — fills the
  origin field with "My Location" on the first fix, then replaces it with the reverse-geocoded
  street address once `CLGeocoder` resolves. `hasAutoSetOrigin` stops later fixes from
  overwriting an origin the passenger has since edited. Its `recenterHome()` call is a no-op
  next to `HomeTrigger`'s own first-fix centring on ordinary launch; the case it actually
  matters for is `scenePhase` resetting `hasAutoSetOrigin` after the app returns from the
  background, where `HomeTrigger` has nothing left to change and would otherwise leave the
  camera wherever it was left.
- **Live leg progress** (`onChange(of: routeStore.userLocation)`, while commuting) — always
  updates `commuteEngine`/`positionResolver`, but never writes the camera directly; the
  continuous follow loop (below) samples the puck's own glide every frame instead, so motion
  reads the same regardless of which mode or pace produced the fix.
- **`evaluateReroute(at:now:)`** — called from the same `onChange`, after `commuteEngine`
  updates. Feeds the fix to `rerouteMonitor` (`CommuteRerouteMonitor`, `State/`); if it fires,
  starts one `Task` calling `RouteStore.rerouteCurrentWalkLeg(from:legIndex:engine:)`
  (`Services/CommuteRerouter.swift`), which re-measures the current walk leg from the live
  position and writes the patched route back to both `routeStore.routeResult` and
  `commuteEngine`. Arms `rerouteMonitor`'s cooldown only if that call reports success — a
  failed attempt leaves the cooldown unarmed so the next sustained deviation retries right
  away. Only walk legs are eligible; `rerouteMonitor` is reset in `startCommute(with:)`
  and `endCommute()` alongside `positionResolver`.
- **Snap → glide handoff** (`onChange(of: commuteEngine?.snappedLocation)`) — every new snap
  target, synchronous for every mode but train and asynchronous once `TrackSnapper` resolves
  for train, starts the puck's own glide toward it. This is the only place a new position is
  handed to `PuckGlideInterpolator`.
- **Dead-reckoning tick** (1 Hz `.task(id: isCommuting)`) — once no GPS fix has arrived for
  more than `CommutePositionResolver.deadReckonAfterSeconds`, projects the passenger forward
  along the leg polyline using their last known speed. Train legs use `TrackSnapper`'s own
  nil-coordinate path; other modes get the projected coordinate as a synthetic fix.
- **Continuous camera follow** (30 Hz `.task(id: isCommuting)`) — ticks at the same cadence as
  `PuckGlideInterpolator` and samples its already-smooth position every frame, rather than
  writing a new camera position once per GPS fix. A per-fix write can't read as continuous
  motion on its own: fixes land at whatever cadence `distanceFilter` produces, which varies by
  mode and pace.
- **`onChange(of: commuteCameraMode)`** — starts a `followPassenger` transition while tracked.
  While untracked it starts a `keepCenter` transition, which keeps the camera centre.
- **`startCommute(with:)`** — seeds `positionResolver`/`commuteEngine` with the passenger's
  already-known location immediately, instead of waiting for the next GPS fix (which, at
  `distanceFilter`'s pace, can be several seconds away). Until `commuteEngine.snappedLocation`
  holds a value, the Map draws MapKit's raw-GPS `UserAnnotation` instead of the tracked puck,
  and the camera has nothing of the engine's to follow — both wait on this same value. The
  camera write itself is `.start` (see `ContentView+Camera.swift`), not
  `beginCameraTransition()`, because the jump from wherever the camera was resting to the
  ride's start can be arbitrarily large and must be a cut, not a pan.
- **`beginCameraTransition(_:)`** — see `ContentView+CameraPose.swift` below.

## ContentView+LiveActivity.swift

Hooks between Commute Mode and `CommuteLiveActivityController`. See `LiveActivity.md`.

- `beginLiveActivity(startedAt:)` runs at the end of `startCommute`. It starts the activity and
  turns on background location updates.
- `endLiveActivity()` runs at the start of `endCommute`. It removes the activity and turns the
  background updates off.
- `tickLiveActivity(now:)` runs once per second in the dead-reckoning task. It sends throttled
  updates. Within 30 m of the end of the last leg it ends the activity on the arrived state and
  calls `markArrived(at:)`.
- `noteLiveActivityFix(at:)` records the time of each real GPS fix for the stale date.
- `ContentView.onDisappear` stops location tracking only when no commute runs.

## ContentView+CommutePersistence.swift

Keeps the commute across backgrounding and app termination.

- `startCommute(with:)` runs `enterCommuteMode(with:startedAt:)`, starts the Live Activity, and
  saves the commute.
- `saveCommute()` writes the commute through `ActiveCommuteStore`. It runs at start, on each leg
  change, after a reroute, and when the app goes to the background. It skips a debug simulation
  and an arrived commute.
- `restoreCommuteIfNeeded()` runs once per launch. It resumes a saved commute with its first
  start time and reattaches the Live Activity. A commute older than its planned trip time plus
  one hour is discarded, and then leftover Live Activities end.
- `markArrived(at:)` clears the saved commute, turns background location off, and sets
  `arrivedAt`. The commute card shows "Arrived" until the passenger taps Done.
- `endCommute(reason:)` logs a `CommuteEndReason` and clears the saved commute.
- During a commute, `CommuteLocationFetcher` never pauses updates and holds a
  `CLBackgroundActivitySession`. Both reset when the commute ends.

## ContentView+Camera.swift

- **`CameraFollowTrigger.start`** — entering Commute Mode for the first time this session.
  Written with no animation, because the resting camera can be anywhere (Manila default, the
  passenger's last real fix) and animating that unbounded distance would fly the camera across
  the map before the ride has even begun. A debug simulator run skips this write in
  `startCommute`. It frames the pre-run map centre and North Avenue, then writes `.start` once
  to centre on the puck. See `Debug.md`.
- **`recenterHome()`** — returns early in debug builds while `debugSimHoldsCamera` is true, so
  the exit framing of a simulator run is the only camera move.
- **`displayedPuckCoordinate`** — the puck's 30 Hz glide position, then the snapped fix, then the
  raw fix. The puck annotation, the live polyline trim point, and the camera centre all read it,
  so no polyline segment shows behind the puck.
- **`updateCommuteCamera(_:)`** — writes `targetPose(_:)` for the current mode. The pose centre
  is the puck's glide position, then the engine's snapped fix, then the leg's start station;
  never the raw GPS fix.
- **`positionedInStrip(_:fraction:)`** — shifts the camera centre so the puck lands `fraction` of
  the way down the map strip, and at the horizontal middle of the screen. The strip runs from the
  top safe-area inset to the top edge of the commute sheet. `MapProxy.convert(_:from:)`
  gives the offset between the screen centre and the strip point under the camera the map shows
  now. It returns the input unchanged when the strip is not measured, the proxy is nil, or a
  convert fails.
- **Strip bottom** — the commute sheet measures its own top edge in window coordinates.
  `followSheetTop(_:)` stores it in `commuteStripBottom` and in `visibleBottom`.
  `startCommute` clears it, and clears `visibleTop`, which commuting does not use.
- **`StripBottomEase`** — eases the strip bottom from its last value to a new measured value
  over `DesignTokens.Motion.discloseDuration`, with an ease-in-out shape. Each 30 Hz camera
  write reads the eased value, so the puck offset follows the sheet with no jump.
- **Follow writes** — `.followTick` and every transition tick write with no animation. Each runs its
  own 30 Hz interpolation, and an animated write restarts MapKit's animation every tick, which
  makes the camera lag behind the puck. `.fit` and `.start` keep `cameraFit`.

## ContentView+CameraPose.swift

- **Poses** — `twoD` is north-up, flat, 800 m, puck at 0.5 of the strip. `threeD` faces the route
  direction, pitch 50, 300 m, puck at 0.7 of the strip.
- **Route heading** — `routeHeading(along:at:)` gives the bearing to the point 40 m ahead of the
  puck. `advanceSmoothedRouteHeading()` low-passes it once per 30 Hz follow tick and holds it
  while the puck stands still.
- **`beginCameraTransition(_:)`** — interpolates from the stored camera to the target pose over
  `cameraPoseDuration`, with a smoothstep curve. The target is read again each tick. Heading takes
  the shortest turn. `followPassenger` moves the centre to the pose. `keepCenter` keeps it.
- **Stored camera** — every write stores its pose in `lastCommuteCamera...`. While untracked,
  `recordObservedCamera(_:)` stores the camera after a pan, so a re-track starts from the screen.
- **Untrack** — writes nothing and calls `cancelCameraTransition()`.

## ContentView+RouteChoice.swift

- **`showsRouteChoice`** — true when options exist and the passenger is not commuting.
- **`routeChoiceKey`** — option ids plus leg ids. Walk refinement keeps option ids and replaces
  leg ids, so both must be in the key that triggers `syncRouteChoice()`.
- **`previewSelectedRoute()`** — runs on every `selectedID` change and calls
  `routeStore.previewRoute`. The walk refiner finds the shown option through `routeResult`,
  so `routeResult` must always match the selected option.
- **`handleRouteTap(at:proxy:)`** — projects each route with `proxy.convert`, then asks
  `RouteHitTesting` for the nearest route. It ignores taps in Commute Mode.
- **`refitForDetailToggle()`** — waits for the panel measurements to settle, then refits the
  union of all routes from the new `visibleBottom` with `.smooth(duration: 0.5)`.
