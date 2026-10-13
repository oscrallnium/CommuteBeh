# State

Live position-tracking logic that runs while Commute Mode is active — no views, cards, or
modifiers of its own.

## CommuteProgress.swift

**`CommuteProgressEngine`** — the `@Observable` engine driving Commute Mode's live progress:
which leg the passenger is on, distance remaining, and on-time status. `update(location:)` is
the entry point, called on every GPS fix from `ContentView`. Projects the raw fix onto the
current leg's polyline (road/jeepney/bus legs) or delegates to the `TrackSnapper` actor
(`Domain/TrackSnapper.swift`) for train legs, whose polyline is often a straight chord between
stations rather than the real track alignment. Publishes the result as `snappedLocation`.

- **`snappedLocation`** — the fix the camera and progress figures actually track, not the raw
  GPS point. Snapping absorbs ordinary urban GPS noise (a fix a few metres off the road one
  moment, back on it the next) so the dot reads as "on the road" instead of hopping between
  parallel streets. Only snapped within `maxSnapDistanceMeters`; past that the passenger has
  plausibly left the route for real, and the raw fix is more honest than a false snap. On a
  walk leg (`mode == .walk`) it is always the raw fix at any distance, because a walker is not
  bound to the path.
- **`maxSnapDistanceMeters`** (75 m) — wide enough to absorb ordinary urban GPS error (often
  10–30 m, more between tall buildings) without being so wide that a real wrong turn still
  reads as "on the road".
- **`legSwitchMarginMeters`** (20 m) — how much closer a *different* leg's polyline must be
  before the engine actually switches `currentLegIndex` to it. Keeps the leg from flapping
  between an access-walk leg and the ride leg it hands off to, whose endpoints can sit within
  a few metres of each other at a station's access point.
- **`legProgressJitterToleranceMeters`** (8 m) — how far a new same-leg projection may land
  *behind* the last confirmed point before it's treated as jitter and held rather than applied.
  Mirrors `TrackSnapper.progressJitterToleranceMeters`, which guards the same class of mismatch
  for train legs.
- **`lastConfirmedLegProgress`** / **`stabilizedProgress(_:)`** — hold the non-train snap at its
  last confirmed point when a new projection jumps backward past the jitter tolerance, so GPS
  noise picking a nearby-but-wrong segment can't teleport the snapped position (and so the
  camera following it) backward or sideways along the route. Reset on every leg switch. Walk legs
  skip it: `applyWalkProgress(_:location:now:)` uses the raw projection, so backward movement
  shows in `metersIntoCurrentLeg` and the walk leg never writes this state.
- **`closestPoint(on:to:)`** — projects a raw fix onto one leg's polyline: distance off the
  route, and how far along it the closest point sits. Mirrors the same "closest point on a
  polyline" projection `LoopCreatorView.roadPointsNear(_:road:within:)` uses, minus that
  function's run-bucketing (a route leg's polyline doesn't loop back over itself the way a
  recorded road can).
- **`snapToTrack(location:leg:now:)`** — the train-only path. Runs `TrackSnapper.snap(...)` on
  its actor and writes `snappedLocation` back once it lands; cancels any snap still in flight
  for the previous fix so a burst of fast fixes can't let an older call overwrite a newer one.
  Pass `location: nil` to trigger `TrackSnapper`'s dead-reckoning path instead of a live fix.
- **`currentLegOffRouteMeters`** / **`currentLegAheadBearing`** — the raw fix's distance off the
  current leg's polyline and the polyline's own bearing at the nearest point, both
  unstabilized. Read by `CommuteRerouteMonitor`, which needs the actual deviation rather than
  the held-back value `stabilizedProgress(_:)` may report for `metersIntoCurrentLeg`.
- **`applyReroute(_:)`** — adopts a route `CommuteRerouter` has patched mid-ride: rebuilds
  `legGeometries`/`plannedElapsedAtLegStart` from the same helpers `init` uses, keeps
  `startedAt`/`currentLegIndex`, and clears `lastConfirmedLegProgress`/`trainProgress` the way a
  normal leg switch already does.
- **`progressFraction`**, **`plannedSecondsRemaining`**, **`fractionAlongCurrentLeg`** — route
  progress weighted by each leg's planned minutes, the planned time left, and the share of the
  current leg covered. `CommuteActivitySnapshot` reads them to build the Live Activity state. See
  `Gora/LiveActivity/LiveActivity.md`.

## CommuteRerouteMonitor.swift

**`CommuteRerouteMonitor`** — decides when the passenger has genuinely left the current walk
leg, fed one fix at a time from `ContentView`'s `onChange(of: routeStore.userLocation)`. Armed
only while the current leg's `mode == .walk`; every other leg resets it. `evaluate(...)`
returns `true` at most once per deviation, which `ContentView` turns into one call to
`RouteStore.rerouteCurrentWalkLeg(from:legIndex:engine:)` (`Services/CommuteRerouter.swift`).

- **Distance gate** — `offRouteMeters` must exceed `offRouteThresholdMeters` (75 m), the same
  point `CommuteProgressEngine.maxSnapDistanceMeters` already stops trusting the snap.
- **Speed gate** — below `minWalkingSpeedMetersPerSecond` (0.5 m/s) a fix never counts. A
  stationary phone's GPS noise must not read as a deviation.
- **Bearing gate** — compares the fix's `course` (`RouteStore.userCourse`, not the
  always-updating `userHeading`, since a deviation is about travel direction) against the
  route's own forward bearing at the nearest point (`currentLegAheadBearing`). Only a course
  pointing away from the route past `awayBearingDegrees` (60°) counts — crossing the route or
  walking roughly parallel to it (the far side of a wide street) does not. Falls back to
  distance and sustain alone when `course` is unavailable, rather than holding a real
  deviation open forever waiting for one.
- **Sustain gate** — the distance and bearing conditions must hold together for
  `sustainSeconds` (8 s) before `evaluate(...)` returns `true`. One bad fix never fires a
  reroute on its own.
- **Cooldown** — `cooldownSeconds` (20 s), armed by `armCooldown(now:)` only once
  `ContentView.evaluateReroute` confirms `RouteStore.rerouteCurrentWalkLeg` actually replaced
  the leg. A failed attempt (offline, rate-limited) arms nothing, so the very next sustained
  deviation retries instead of waiting out a cooldown for a fix that never landed.

## CommutePositionResolver.swift

**`CommutePositionResolver`** — dead-reckons the passenger's position forward along the current
leg's polyline when GPS fixes stop arriving (a tunnel, a signal drop), using the last known
speed. Falls back to holding the last known point once the projection window expires. Feeds a
synthetic coordinate back into `CommuteProgressEngine.update(location:)` — it does not write
`snappedLocation` directly.

`resolvedCoordinate` equals the last GPS fix while fixes arrive regularly; once fixes stop, it
switches to a polyline-projected point using `lastFixSpeed`, then switches back the moment a
real fix returns.

## PuckGlideInterpolator.swift

**`PuckGlideInterpolator`** — moves the passenger dot continuously between two snapped
positions via its own 30 Hz tick loop. Exists because MapKit's `Annotation` re-places its
coordinate instantly on every write rather than interpolating it, the same reason
`ContentView.beginCameraTransition()` hand-rolls its own interpolation loop for the camera
instead of relying on `withAnimation`. `ContentView`'s puck `Annotation` reads
`displayedCoordinate` from this class, not `CommuteProgressEngine.snappedLocation` directly.

`ContentView.updateCommuteCamera(_:)` reads this same `displayedCoordinate` as the camera's
first-priority center, so the dot and the camera it's centered under are always driven by the
one continuously-moving value and can never visibly disagree.

## ActiveCommuteStore.swift

**`SavedCommute`** holds the route, the start time, the origin and destination text, and the save
time. **`ActiveCommuteStore`** saves, loads, and clears it as one JSON file in Application
Support. `isRestorable(at:)` is true until the planned trip time plus one hour after the start
time. `RouteLeg` leaves out its transient `id` when it encodes.

