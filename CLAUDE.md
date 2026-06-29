# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**CommuteBeh** — iOS transit navigation app for Metro Manila. Finds optimal multimodal routes across MRT-3, LRT-1, LRT-2, buses, jeepneys, and tricycles via an A* engine on a bundled JSON graph. No external dependencies.

- iOS 26+ · SwiftUI · MapKit · Swift Concurrency
- Bundle ID: `com.banaueinc.commutebeh.CommuteBeh`

## Build & Test

```bash
# Build
xcodebuild -project CommuteBeh.xcodeproj -scheme CommuteBeh \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run all tests (requires CommuteBehTests target — see .claude/skills/swift-testing.md)
xcodebuild -project CommuteBeh.xcodeproj -scheme CommuteBeh \
  -destination 'platform=iOS Simulator,name=iPhone 16' test

# Run a single test
xcodebuild -project CommuteBeh.xcodeproj -scheme CommuteBeh \
  -destination 'platform=iOS Simulator,name=iPhone 16' test \
  -only-testing:CommuteBehTests/SuiteName/testMethodName
```

No linter is configured. No Swift packages.

## Critical File Layout

`TransportMode.swift` is misleadingly named — it contains the entire domain layer:
- All `Codable` model types (`Station`, `TransitEdge`, `RouteLeg`, `RouteResult`, `TransitGraph`, …)
- `TransitGraphEngine` — Swift `actor`; builds the adjacency list, runs A*
- `CommuteViewModel` — `@Observable final class`; drives `ContentView`
- `GraphLoader` — decodes JSON from the app bundle
- Supporting algorithms: `MinHeap`, Haversine, peak-hour multipliers

Everything else is UI: `ContentView.swift` (Commute tab), `ExploreView.swift` (Explore tab + its own `ExploreViewModel`).

**Active data**: `transit_graph_v3.json`. `transit_graph_v2.json` is loaded only by `ExploreView` for network visualisation; it is not used for routing.

## Architecture

MVVM + `@Observable` + Swift Concurrency. See `.claude/skills/architecture-mvvm.md`.

- ViewModels are `@Observable final class` marked `@MainActor`. Use `@State private var vm = MyViewModel()` in views — never `@StateObject` or `ObservableObject`.
- `TransitGraphEngine` is an `actor`. Route calculation runs via `Task.detached(priority: .userInitiated)` so it doesn't block the actor's executor queue during the CPU-heavy A* search.
- Models are immutable `Codable` value types. `RouteLeg.id` is a `UUID()` (transient); all other IDs come from JSON.

## Key Invariants

- Never hardcode station names, fares, coordinates, mode strings, or payment strings in Swift. All come from `transit_graph_v3.json`.
- `alwaysAllowedModes` in the engine is derived from `isAlwaysAllowed: true` in the JSON — the string `"walk"` must not be hardcoded in A* logic.
- When stitching `polylineCoordinates` across merged edges, drop the first coordinate of each subsequent segment — it duplicates the shared junction point.
- Fare is computed once per `RouteLeg` (single boarding), not summed per edge.
- `"line": "INTERCHANGE"` on an edge prevents leg consolidation and skips fare/operating-hours checks.

## Transit Lines Quick Reference

| Mode | Line keys in JSON |
|---|---|
| `train` | `MRT-3`, `LRT-1`, `LRT-2` |
| `bus` | `EDSA_BUS`, `COMMONWEALTH_BUS` |
| `jeepney` | `JEEPNEY_QUIAPO_CUBAO`, `JEEPNEY_QUIAPO`, `JEEPNEY_NORTH`, `JEEPNEY_MAKATI`, `EJEEPNEY_BGC`, `JEEPNEY_CARTIMAR_LRT` |
| `tricycle` | `TRICYCLE_MANILA` |

## Adding a Transit Line

Edit `transit_graph_v3.json` only — no Swift changes required unless the mode is brand new. Schema and naming conventions: `.claude/skills/transit-data.md`.

## Map Styling Note

`modeColor(_:)` for `TransportMode` is duplicated across `ContentView`, `RouteResultCard`, `RouteLegRow`, and `ExploreViewModel`. Consolidate into `extension TransportMode { var color: Color }` before adding more call sites.

## Skills

| Topic | File |
|---|---|
| MVVM conventions | `.claude/skills/architecture-mvvm.md` |
| Swift Testing (unit tests) | `.claude/skills/swift-testing.md` |
| Transit JSON schema | `.claude/skills/transit-data.md` |
| SwiftUI + MapKit patterns | `.claude/skills/swiftui-mapkit.md` |
| Branding (pending) | `.claude/skills/branding.md` |
