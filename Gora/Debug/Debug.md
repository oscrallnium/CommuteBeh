# Debug

Debug-only tooling compiled out of release builds entirely (`#if DEBUG`). Exercises
production code paths without needing a real GPS fix or an actual train ride.

## DebugTrainSimulator.swift

**`DebugTrainSimulator`** drives a simulated ride along a fixed route (MRT North Avenue to
Guadalupe). Use it to test Commute Mode without a real train ride. The route always starts at
North Avenue, wherever the real GPS is.

### One passenger position

During a run, the simulator is the only writer of `RouteStore.userLocation`, `userSpeed` and
`userCourse`. Every consumer reads that one position.

- `RouteStore.beginSimulatedLocation(at:)` moves the passenger to North Avenue before Commute
  Mode starts. The progress engine and the track snapper seed at North Avenue.
- `RouteStore.applySimulatedFix(_:speed:course:)` is the only simulator write.
- `RouteStore` stores each real GPS fix but does not apply it while a run is active.
- `RouteStore.endSimulatedLocation()` clears the flag and applies the newest real fix. Real GPS
  resumes at once and no simulator state stays.

### Run life cycle

- `isStarting` blocks a second start from a double tap. `isActive` stays true from the moment the
  simulator owns the position until `stop`. Arrival does not clear it.
- The first tick fixes the passenger at 0 m. The last fix has speed 0.
- The train waits `dwellSeconds` (10 s) at each intermediate station, with speed 0.
- A failed step sets `lastError`, prints it with `[DebugSim]`, and changes the button label to
  "Sim failed".
- The button is hidden during a real commute.

### Exits and camera

Stop, the commute card's End button and arrival all call `ContentView.endCommute()`. It calls
`endDebugSimulationIfActive()`, which stops the run and restores real GPS.

- `ContentView.debugSimAnchor` holds the map centre from before the run. It updates only while
  no run and no commute is active.
- Start and every exit make one camera move that frames `debugSimAnchor` and North Avenue.
- After the start framing, one `.start` move centres on the puck. Follow mode then turns on.
- On exit, `debugSimHoldsCamera` makes `recenterHome()` return early until the framing move
  ends. The home trigger and the auto-origin step cannot move the camera in that time.

`start(routeStore:onRouteReady:)` awaits `onRouteReady`. `ContentView` starts Commute Mode and
runs the start framing in that call. The first tick runs after the call returns.

### Geometry helpers

`flattenedPolyline`, `cumulativeDistances`, `coordinate(at:route:cumulativeMeters:)`, and
`bearing(at:route:cumulativeMeters:)` mirror the same "flatten, accumulate distance,
interpolate" shape as `CommuteProgressEngine.LegGeometry` and `TrackSnapper.LineGeometry`. A
fourth copy of that pattern reads better here than threading a debug-only concern through
either of those actor-isolated types.
