# Architecture — MVVM + @Observable + Swift Concurrency

## Pattern

CommuteBeh uses **MVVM** with Apple's `@Observable` macro (iOS 17+) and structured Swift Concurrency.

```
View (SwiftUI struct)
  └── ViewModel (@Observable final class, @MainActor)
        └── Engine / Service (actor or struct)
              └── Models (Codable structs, value types)
```

## ViewModels

- Annotate with `@Observable` and `final class`.
- Annotate with `@MainActor` so all published state updates happen on the main thread.
- Expose state as `var` properties — `@Observable` synthesises observation tracking automatically.
- Do not use `@Published`, `ObservableObject`, or `@StateObject` — they are the old pattern.

```swift
@Observable
@MainActor
final class CommuteViewModel {
    var routeResult: RouteResult?
    var isLoading = false
    var errorMessage: String?

    private var engine: TransitGraphEngine?
}
```

## Views

- Own their ViewModel via `@State`:
  ```swift
  @State private var vm = CommuteViewModel()
  ```
- Never create ViewModels with `@StateObject` or `.environmentObject`.
- Views are pure structs — no business logic, no direct data access.
- Keep `body` a short outline of named sections. Follow `CLAUDE.md`, section "Break up nested view bodies", for how to extract a section.

## Engine / Services

- Use `actor` for anything that runs off the main thread and holds mutable state.
- `TransitGraphEngine` is the reference implementation: it owns the adjacency list and runs A*.
- Call actor methods with `await` from `@MainActor` contexts — Swift handles the hop automatically.

```swift
actor TransitGraphEngine {
    func findRoute(_ request: RouteRequest) -> RouteResult? { ... }
}

// In ViewModel:
let result = await Task.detached(priority: .userInitiated) {
    await engine.findRoute(request)
}.value
```

- `Task.detached` is used for CPU-heavy work (A* search) so it doesn't block the actor's executor queue.

## Models

- All domain models are `Codable` value types (`struct`).
- `Identifiable` models implement `id` from the JSON where possible; use `let id = UUID()` only for transient types like `RouteLeg`.
- Do not add mutability (`var`) to model structs — models are read-only snapshots.

## Data Flow

```
JSON file
  → GraphLoader.load() → Result<TransitGraph, GraphLoadError>
  → TransitGraphEngine.init(graph:)   (actor; builds adjacency dict)
  → TransitGraphEngine.findRoute(_:)  (async; returns RouteResult?)
  → CommuteViewModel.routeResult      (@MainActor published state)
  → ContentView / RouteResultCard     (reads vm.routeResult)
```

## Async Patterns

- Use `async/await` — no completion handlers.
- Launch async work from views via `Task { await vm.someAction() }` or `.task { }` modifier.
- Use `Task.detached` only for CPU-bound work that should not inherit the caller's actor context.
- Avoid `DispatchQueue` — use actors and `@MainActor` instead.

## Adding a New Feature

1. Add model types (Codable structs) in `TransportMode.swift` if they relate to the domain.
2. Add engine methods (actor) for any logic that shouldn't run on main thread.
3. Add ViewModel state + async method on `CommuteViewModel` or create a new `@Observable` VM.
4. Build the View as a new SwiftUI struct; inject the VM via `@State` or pass as a binding/parameter.

## What to Avoid

- `DispatchQueue.main.async` — use `@MainActor` instead.
- `@Published` / `ObservableObject` — use `@Observable`.
- Singleton ViewModels — instantiate them with `@State` in the owning View.
- Business logic in View bodies — belongs in the ViewModel or engine.
- Mutable model structs passed by reference — keep models as immutable value types.
