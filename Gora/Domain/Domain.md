# Domain

## Route diversity

`RouteStore.calculateRoute` runs three base searches: fastest, cheapest and balanced. The three often return the same route. `TransitGraphEngine.diverseRoutes` adds different routes.

1. The method sorts the base routes by time and keeps the fastest. It drops a later base route that is too similar to an accepted route.
2. The method collects every ride line of every route found so far, accepted or not.
3. It runs one balanced search with those lines in `RouteRequest.penalizedLines`. A* multiplies the search cost of a ride edge on a penalized line by `linePenaltyFactor`. The shown time stays real. Walk-like edges and `INTERCHANGE` edges are never penalized.
4. It keeps the result when the route is new, its time is within `slowdownFactor` and `slowdownMinutes` of the fastest route, and it is not too similar to an accepted route.
5. It stops after `maxExtraSearches` searches, when a search returns a known route, or when `maxOptions` routes exist.

The trunk of a route is its ride line with the most ride minutes, and zone ride lines do not count. On a tie, the earlier leg wins. A zone ride line is the trunk only when the route has no other ride.

Two routes are too similar when one route rides the trunk line of the other route on any leg, or when their overlap is above `maxOverlap`. The rule applies to base routes and to extra routes. The fastest route always stays. The overlap leaves zone ride lines out of the shared minutes and of the totals.

A rejected extra route still adds its lines to the penalized set, so the next search moves away from it. Zone ride lines never enter the penalized set, so a route can use a zone ride as a feeder. The loop stops when the penalized set does not grow between two searches.

Overlap is the ride minutes on shared lines divided by the smaller total of ride minutes. The measure skips walk-like legs.

A penalty only raises the cost of an edge, so the A* heuristic stays admissible.

## Timetable route

A timetable wait can make every timetable route lose the three base searches. When no shown route has a timetable leg, `TransitGraphEngine.timetableExtra` runs one search with `CostStrategy.timetable`. That search keeps the wait in the route time and leaves the wait out of the search cost. It reaches the destination only after a timetable ride.

The method accepts the route only when its time without the wait is at most the shortest time of the shown routes. The extra card therefore shows only a route that would be the fastest trip if the rider caught the vehicle.

`RouteStore.calculateRoute` adds the result as a fourth option with the balanced label, when its route differs from the shown routes. `RouteOption.isTimetableExtra` keeps this option last and out of the fastest and cheapest labels, also after the refiners rebuild the list.

## Fare distance step

`RoadFare.amount` rounds the fare km up to the next multiple of `LineConfig.fareStepKm` before it applies `baseFare`, `baseKm`, and `farePerKm`. A distance within 0.01 km above a multiple counts as that multiple. A line with a nil or 0 step keeps the exact fare km. Each line in the graph sets its own step. `searchFare` in the A* search still uses the exact distance, so the search cost is an estimate and the shown fare follows this rule. The amount then rounds to the nearest 25 centavos, as LTFRB guides do. The toll share is not rounded.

## LocationAccess.swift

**`LocationAccess`** has three cases: `undetermined`, `allowed`, and `off`. `off` covers Don't Allow, a
restricted phone, and Location Services turned off for the whole phone. `CommuteLocationFetcher.access`
holds it, and `RouteStore.locationAccess` mirrors it. The fetcher updates it in
`locationManagerDidChangeAuthorization` and in `refreshAccess()`, which `ContentView` calls when the scene
becomes active. Background location updates start only while the access is `allowed`.
