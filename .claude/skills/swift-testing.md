# Unit Testing — Swift Testing Framework

CommuteBeh uses **Swift Testing** (introduced in Xcode 16 / Swift 6), not XCTest.

## Setup

Tests live in a separate target: `CommuteBehTests`. Create it in Xcode:
- File → New → Target → Unit Testing Bundle
- Set "Testing System" to **Swift Testing** (not XCTest)
- Import the app module: `@testable import CommuteBeh`

## Basic Anatomy

```swift
import Testing
@testable import CommuteBeh

struct CommuteEngineTests {

    @Test func routeFoundBetweenKnownStations() async throws {
        let graph = try #require(GraphLoader.load().get() as TransitGraph?)
        let engine = TransitGraphEngine(graph: graph)
        let result = await engine.findRoute(RouteRequest(from: "MRT3_NORTH_AVE", to: "MRT3_AYALA"))
        #expect(result != nil)
        #expect(result?.legs.isEmpty == false)
    }
}
```

## Key Macros

| Macro | Purpose |
|---|---|
| `@Test` | Marks a function as a test case |
| `@Suite` | Groups related tests (optional; structs/classes auto-qualify) |
| `#expect(condition)` | Assertion — test continues on failure |
| `#require(condition)` | Assertion — test stops immediately on failure (like `XCTUnwrap`) |
| `#expect(throws: ErrorType.self) { }` | Assert a specific error is thrown |

## Parameterised Tests

Run the same test logic across multiple inputs with a single declaration:

```swift
@Test("Route exists", arguments: [
    ("MRT3_NORTH_AVE", "MRT3_AYALA"),
    ("LRT1_BACLARAN",  "LRT1_ROOSEVELT"),
    ("LRT2_RECTO",     "LRT2_SANTOLAN"),
])
func routeExistsForKnownPairs(origin: String, destination: String) async {
    // ...
}
```

## Tags

Group tests across suites for selective runs:

```swift
extension Tag {
    @Tag static var routing: Self
    @Tag static var fareCalculation: Self
}

@Test(.tags(.routing)) func astarFindsOptimalPath() { ... }
```

Run only tagged tests: `swift test --filter .routing` or via Xcode Test Navigator filter.

## Async Tests

Swift Testing natively supports `async` test functions — no `XCTestExpectation` needed:

```swift
@Test func calculateRouteUpdatesViewModel() async {
    let vm = CommuteViewModel()
    // Wait for engine to be ready
    try? await Task.sleep(for: .milliseconds(200))
    vm.originID = "MRT3_NORTH_AVE"
    vm.destinationID = "MRT3_AYALA"
    await vm.calculateRoute()
    #expect(vm.routeResult != nil)
    #expect(vm.isLoading == false)
}
```

## Testing the Engine

`TransitGraphEngine` is an `actor` — call its methods with `await`:

```swift
@Test func engineReturnsNilForUnreachableRoute() async throws {
    let graph = try GraphLoader.load().get()
    let engine = TransitGraphEngine(graph: graph)
    // Two stations with no connecting edges
    let result = await engine.findRoute(RouteRequest(from: "FAKE_A", to: "FAKE_B"))
    #expect(result == nil)
}
```

## Testing Pure Functions

Isolate and test deterministic logic directly — no async needed:

```swift
@Test func legFareIsZeroForWalkMode() {
    // Walk legs should always return 0 fare regardless of distance
    let walkEdge = TransitEdge(/* mode: "walk", baseFare: 0, ... */)
    // ... construct RawStep and verify computeLegFare returns 0
}

@Test func haversineDistanceIsSymmetric() {
    // Distance A→B == distance B→A
}
```

## Testing GraphLoader

```swift
@Test func graphLoaderDecodesV3() throws {
    let result = GraphLoader.load(from: "transit_graph_v3")
    let graph = try #require(try? result.get())
    #expect(!graph.stations.isEmpty)
    #expect(!graph.edges.isEmpty)
    #expect(graph.transportModes["train"] != nil)
}
```

## What to Test

| Layer | What to cover |
|---|---|
| `GraphLoader` | JSON decodes successfully, station/edge counts are non-zero |
| `TransitGraphEngine` | Route found for known origin/destination pairs; nil returned for disconnected stations; same origin/destination returns empty legs |
| Fare logic | Walk legs return 0; distance-based fares scale correctly; flat fares are unchanged by distance |
| Leg consolidation | Consecutive same-line edges merge into one leg; walk legs never merge with transit legs |
| Peak multipliers | Multiplier > 1.0 during peak windows; 1.0 outside them |
| `CommuteViewModel` | `canCalculate` false when IDs empty; `routeResult` populated after `calculateRoute()` |

## What Not to Test

- SwiftUI view rendering — use previews for visual checks.
- `MapKit` road snapping — it calls Apple's servers; mock or skip in unit tests.
- `ExploreViewModel.snapToRoads` — side-effectful network call; test `buildLayers` in isolation instead.
