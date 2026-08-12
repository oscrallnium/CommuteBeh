# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Gora** — iOS transit navigation app for Metro Manila. Finds optimal multimodal routes across MRT-3, LRT-1, LRT-2, buses, jeepneys, and tricycles via an A* engine on a bundled JSON graph. No external dependencies.

- iOS 26+ · SwiftUI · MapKit · Swift Concurrency
- Bundle ID: `com.banaueinc.gora`

## Writing Style — ASD-STE100

Write all prose in this repository in ASD-STE100 (Simplified Technical English). This applies
to code comments, documentation, commit messages, and PR bodies. It does not apply to
user-facing UI copy, which stays natural.

Core rules:

- Use one word for one meaning. Do not call the same thing a "stop" in one place and a
  "station" in another.
- Use the active voice. Write "The engine builds the adjacency list", not "The adjacency list
  is built".
- Use the present tense for facts and the imperative for instructions.
- Keep procedural sentences to 20 words or fewer. Keep descriptive sentences to 25 or fewer.
- Write one instruction per sentence.
- Keep articles. Write "Drop the first coordinate", not "Drop first coordinate".
- Avoid gerunds and noun clusters. Write "a station that has doors", not "a door-having
  station".
- Do not use slang, idioms, or metaphor.
- Start a paragraph with its main point.

## Comments

A comment describes what the code does now. Keep it to **three lines or fewer** per function,
property, or type.

Write the current behaviour, not the path that produced it:

```swift
// [Wrong] narrates history and a past bug
/// The old policy was a flat 1.5 km radius applied to the k nearest stops globally, which
/// failed in both directions: it accepted 1.4 km walks to an arbitrary mid-route stop, and
/// because the nearest stops around any dense point all belong to one line, it could hand
/// every access edge to that line. Verified in the simulator on 2026-07-14. Replaced after
/// the routing audit with the role-aware policy below.
static let midRouteKm: Double = 0.6

// [Correct] states the rule and the one fact that explains it
/// Longest walk allowed to an ordinary stop. Terminals use `terminalKm` instead, because
/// passengers accept a longer walk to board at a terminal.
static let midRouteKm: Double = 0.6
```

Do not write:

- What a developer asked for, or when.
- What the code used to do, or which bug changed it.
- Dates, ticket numbers, audit references, or names.
- A restatement of the function signature.

Do write a constraint when breaking it causes a defect. State it as a present-tense rule:

```swift
/// Reverses the recorded points when the ride crosses a bidirectional edge backwards, so the
/// stored polyline still runs from `edge.from` to `edge.to`.
```

Long explanations belong in `docs/`, not in the source.

## Swift File Header

Every new `.swift` file must begin with this header. Use the exact date the file is first created (`M/D/YY`, no leading zeros):

```swift
//
//  FileName.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 7/7/26.
//
```

- App name is **Gora**.
- Author is **Oscar Allen Brioso**.
- Date format: `M/D/YY` — e.g. `7/7/26`, `11/2/26`. No leading zeros.
- The header goes on line 1, before any `import` statements.

## Build & Test

```bash
# Build
xcodebuild -project Gora.xcodeproj -scheme Gora \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# Run all tests (requires GoraTests target — see .claude/skills/swift-testing.md)
xcodebuild -project Gora.xcodeproj -scheme Gora \
  -destination 'platform=iOS Simulator,name=iPhone 17' test

# Run a single test
xcodebuild -project Gora.xcodeproj -scheme Gora \
  -destination 'platform=iOS Simulator,name=iPhone 17' test \
  -only-testing:GoraTests/SuiteName/testMethodName
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

## File Size and Structure

Keep each Swift file between 400 and 500 lines. Treat 500 as a hard ceiling. When a file
passes the ceiling, split it before you add more code.

Split a file by responsibility, not by line count. One file holds one screen, one component,
or one group of closely related helpers. Name the file after the type it holds.

### Break up nested view bodies

A deeply nested `body` is hard to read and impossible to reuse. Extract each distinct region
into a computed property or a view function on the same type:

```swift
// [Wrong] one 200-line body with six levels of nesting
var body: some View {
    VStack { HStack { ZStack { … } } }
}

// [Correct] a body that reads as an outline
var body: some View {
    VStack(spacing: DesignTokens.Spacing.m) {
        header
        legList
        footer(fare: summary.fare)
    }
}

private var header: some View { … }
private var legList: some View { … }
private func footer(fare: Double) -> some View { … }
```

Rules:

- Give each extracted part a name that states what it shows.
- Use a computed property when the part needs no input. Use a function when it takes a
  parameter.
- Extract a part into its own `View` struct when two or more screens use it.
- Keep a `body` short enough to read on one screen.

### Reuse before you write

Search for an existing type before you add a new one. Reuse the view, the modifier, or the
helper that already exists. Two copies of the same layout drift apart, and a fix to one never
reaches the other.

The same rule applies to logic. Put a shared rule in one place and call it from both sites.
`TransportMode.color` in `Design/DesignTokens.swift` is the model to follow.

## Model Selection

Use Opus to plan and Sonnet to implement.

Opus suits work that needs judgement: architecture, refactor plans, audits, and any change
whose blast radius is unclear. Sonnet suits work whose shape is already decided: writing the
code a plan describes, mechanical edits, and tests.

Switch with `/model`, or pass a model to a subagent.

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
