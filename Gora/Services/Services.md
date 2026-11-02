# Services

## DirectionsGateway.swift

**`DirectionsGateway`** is the one gate for every `MKDirections` request. One clock paces all callers.
`path(...)` caches walking and driving paths in memory and on disk.

**`travelSeconds(from:to:departure:cacheOnDisk:urgency:)`** returns the driving time in seconds for one
departure date. It uses `calculateETA()` and returns `nil` on any failure. A request with `cacheOnDisk` set
to `true` is a free-flow time. The gateway keeps it in memory and on disk with no expiry. Any other request
stays in memory for 5 minutes.

## RoadTrafficRefiner.swift

**`RoadTraffic`** computes a traffic factor for a bus, jeepney, or tricycle leg. The factor is the driving
time now divided by the driving time at the next 3:00 a.m. The code limits it to 1.0 through 4.0. A missing
or zero time gives no factor, and the leg stays as it is.

The new leg time is the sum of the free-flow edge minutes multiplied by the factor. It replaces the peak
multiplier for road legs only. Each later leg arrival moves by the same difference.

| Entry point | Use |
|---|---|
| `RouteStore.applyTrafficToRoadLegs()` | Runs after `refineWalkLegs()` in the same task. Retimes every option, then re-sorts with `sortedByDuration()`. |
| `RoadTraffic.retimed(_:legIndex:live:metersInto:metersRemaining:)` | Commute mode. Measures the current leg from the live position and keeps the elapsed time. |

The log category `Directions` shows the now time, the free-flow time, and the factor for each leg. Use it
to check whether MapKit has traffic data for Metro Manila.

## NetworkStatus.swift

**`NetworkStatus`** iterates `NWPathMonitor` as an `AsyncSequence` and exposes `isOnline`. It is `true` until
the first path arrives. `onChange` runs when the value flips. `RouteStore` uses it to show station
suggestions only when the device is offline.
