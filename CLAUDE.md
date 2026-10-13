# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Gora** — iOS transit navigation app for Metro Manila. Finds optimal multimodal routes across MRT-3, LRT-1, LRT-2, buses, jeepneys, and tricycles via an A* engine on a bundled JSON graph. No external dependencies.

- iOS 26+ · SwiftUI · MapKit · Swift Concurrency
- Bundle ID: `com.banaueinc.gora`

## Behavioral Guidelines

### 1. Think Before Coding
- State assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If something is unclear, stop. Name what's confusing. Ask.
- If a simpler approach exists, say so. Push back when warranted.

### 2. Simplicity First
- No features beyond what was asked.
- No abstractions for single-use code.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.
- **Anti-Overcomplication**:
    - Prioritize immediate, surgical fixes over large-scale refactors.
    - Avoid "just-in-case" logic, "what-if" error handling, or redundant alternatives.
    - Use native platform primitives (UIKit/Foundation) before creating custom wrappers.
    - If a proposed solution feels complex, stop and ask: "Is there a simpler way that satisfies the requirement?"
    - **Minimum Viable Fix**: Always attempt the smallest, least invasive code change that solves the reported problem before considering architectural changes.
    - Don't solve problems the user hasn't reported yet.

### 3. Surgical Changes
- Don't improve adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it — don't delete it.
- Every changed line should trace directly to the user's request.

### 4. Comments Describe the Code, Not the Change
A comment is read months from now by someone who never saw the diff, the ticket, or the
conversation that produced it. Write for that reader.

- Describe **what the code does and why it must be this way**. Never narrate what it used to do,
  what was replaced, what a review comment said, or what the developer asked for.
- **Banned in committed comments**: "used to", "previously", "this used to search…", "now uses…",
  "changed from…", "instead of the old…", "as requested", "per review", "fixed the bug where…",
  and "deliberately not X" where X is meaningful only as the prior implementation.
- State the constraint directly instead of its history:
    - **Bad**: `// Resolved from Realm rather than HomeV2ViewController.banners, which this used to search.`
    - **Good**: `// Resolved from Realm: the in-memory banner list is only populated after Home's first sync, so it is empty on a cold-start deep link.`
- Rationale that survives — an invariant, an ordering requirement, a platform quirk, a
  non-obvious failure mode — belongs in the comment. Rationale that is only "why this diff
  exists" belongs in the commit message or PR description.
- Reference only symbols and behaviour that exist in the codebase **now**. A comment naming a
  call that was just deleted is stale the moment it lands.
- Prefer a short comment explaining the non-obvious over a long one recounting an
  investigation. If it reads like a changelog entry, it belongs in the PR, not the source.
- **Three lines maximum** per function, property, or type. The limit is a hard ceiling, not a
  target — most comments need one line. A constraint that genuinely needs more room is a sign
  the explanation belongs in a doc the comment can point to.

### 5. Goal-Driven Execution
- Transform tasks into verifiable goals before starting.
- For multi-step tasks, state a brief plan with a verify step for each.
- Define success criteria upfront — weak criteria ("make it work") require constant clarification.

### 6. Plan Mode Workflow
- **When to Use**: For complex tasks, cross-cutting architectural changes, or when the solution path is not immediately obvious.
- **Research Phase**: Map the codebase, validate assumptions using `grep_search` and `glob`, and **empirically reproduce** issues before attempting fixes.
- **Strategy Phase**: Formulate a grounded approach. Share a concise summary before acting.
- **Execution Phase**: Use an iterative **Plan -> Act -> Validate** cycle.
    - **Plan**: Define the implementation steps and the testing strategy.
    - **Act**: Apply targeted, surgical changes.
    - **Validate**: Run tests and workspace standards to confirm success and prevent regressions.
    - 
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

A comment describes what the code does now. **Three lines is a hard ceiling** per function,
property, or type — doc comment or inline. Trim to the rule itself; move the rest out.

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

Long explanations belong in a markdown file next to the code, not in the source. Put it in the
same folder as the type it documents, named after the folder — e.g. `Views/CommuteMode/State/`
holds `CommuteMode-State.md` for everything in that folder. Create the file if the folder
doesn't have one yet. Point to it from the trimmed comment: `See CommuteMode-State.md.`

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

## Threading
Ensure UI updates are in main thread while other should be in other threads

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

## Clean Code and SOLID Principles

Apply these rules to every file you write or edit, in every session. Treat them with the same
weight as the Swift file header and the comment rules above.

### Clean Code

- Give each name one clear meaning. Name a function after what it returns or does, not how it
  does it.
- Keep a function to one task. Split a function that does two things into two functions.
- Keep a function short enough to read on one screen. Extract a block when it needs a comment
  to explain what it does — the extracted name replaces the comment.
- Avoid a boolean parameter that switches behaviour inside a function. Split into two named
  functions instead.
- Remove dead code and commented-out code. Git history holds the old version.
- Prefer early returns over nested `if` blocks. Handle the failure case first and return.

### SOLID Principles

- **Single Responsibility**: give each type one reason to change. Split a type that mixes
  parsing, storage, and presentation.
- **Open/Closed**: add new behaviour through a new type or a new case, not by editing a
  `switch` that other code already depends on. Use a protocol when call sites must stay
  closed to change.
- **Liskov Substitution**: a type that conforms to a protocol must honour every guarantee the
  protocol promises. Do not throw or return `nil` from a method the protocol declares as
  always succeeding.
- **Interface Segregation**: keep a protocol small and focused. Split a protocol that forces a
  conformer to implement methods it does not need.
- **Dependency Inversion**: depend on a protocol, not on a concrete type, at a boundary
  between layers. `TransitGraphEngine` should accept a `GraphLoading` protocol, not a
  concrete `GraphLoader`, where a test needs to substitute one.

Apply SOLID at the level this codebase already uses: ViewModels, the engine actor, and
protocols at MVVM boundaries. Do not add a protocol or a layer of indirection where one
concrete type already serves every call site — that violates the "Reuse before you write" and
file-size rules above.

## Model Selection

Opus 5.5 (`claude-opus-5-5`) is the orchestrator. Sonnet 5.5 (`claude-sonnet-5-5`) and Haiku 5.5 (`claude-haiku-5-5`) are the implementors. This is the default for every task in this project.

- **Opus 5.5 does**: read the request, research the codebase, ask the user questions, write the plan, split the work, and review the result. It also does architecture, refactor plans, and audits.
- **Sonnet 5.5 does**: code edits that need judgement. Start each one with the `Agent` tool and `model: "sonnet"`.
- **Haiku 5.5 does**: code edits that the brief fully defines. Start each one with the `Agent` tool and `model: "haiku"`.
- **Opus 5.5 edits directly only**: documentation (`CLAUDE.md`, `.claude/` files, memory) and a fix of a few lines after review.

| Task | Implementor |
|---|---|
| SwiftUI views and components with state, layout logic, or a ViewModel | Sonnet 5.5 |
| Static UI with no state: a text, font, color, or spacing value at a given line | Haiku 5.5 |
| API client method: request, decoding, error and loading paths | Sonnet 5.5 |
| API endpoint URL or path constant | Haiku 5.5 |
| ViewModels, `TransitGraphEngine`, A* and graph logic, `GraphLoader`, models | Sonnet 5.5 |
| MapKit overlays, Live Activity, concurrency, and bug fixes that need a root cause | Sonnet 5.5 |
| Unit tests (Swift Testing) and file splits for the 500-line ceiling | Sonnet 5.5 |
| `project.pbxproj` entries, one constant or `Color` static | Haiku 5.5 |
| Copy and string changes, renames, comment fixes | Haiku 5.5 |
| Read-only exploration: find files, symbols, call sites and usages; inventory values; summarize what a folder holds | Haiku 5.5 |

- **Brief each agent fully.** An agent does not see the conversation. Give it the file paths, the exact behavior, the user's answers, and the `CLAUDE.md` rules that apply. Tell it which skills to read.
- **Haiku is the default explorer.** Use a Haiku 5.5 agent, not the built-in Explore agent, for a search across many files. Give it a precise question, such as "list every call site of X" or "list every color value in Y". Haiku returns facts with `file:line` for each one, and no conclusions. Opus 5.5 reads the cited lines that a plan depends on before it plans. For a search of one or two files, Opus 5.5 searches directly.
- **Haiku does not diagnose.** A question about why code fails, or about runtime behavior of gestures, state, layout or concurrency, goes to Opus 5.5 or Sonnet 5.5, not to Haiku 5.5.
- **Haiku brief**: name the file, the line or symbol, and the exact new code or text. If the brief must ask the agent to decide or choose, give the task to Sonnet 5.5.
- **Split API work by layer.** Haiku 5.5 adds the URL constant. Sonnet 5.5 writes the client method in a different file.
- **Split by file.** Run independent agents in parallel. Do not give two agents the same file.
- **Review every result.** Opus 5.5 reads the diff against the plan and this file before it reports to the user. Send fixes back to the same agent with `SendMessage`.
- **Escalate once.** If a Haiku result fails review, give the task to a new Sonnet 5.5 agent. Do not retry it with Haiku.
- **Haiku outside the table.** The table lists the default tasks for Haiku 5.5. It is not a limit. In each session, Opus 5.5 decides which other tasks go to Haiku 5.5, from what Haiku does well and what it does badly:
    - Haiku does well: tasks with one clear result and no design choice. Examples: read-only searches and summaries across many files, lists of call sites or usages, checks of the 500-line file ceiling or project file entries, mechanical edits that repeat one pattern, sample data for previews and tests, and the application of a diff that Opus 5.5 already reviewed.
    - Haiku does badly: tasks that need judgement. Examples: architecture, state and data flow, concurrency and actors, A* and graph logic, root-cause analysis, unclear requirements, and edits that depend on each other across files. These tasks go to Sonnet 5.5.
    - When Opus 5.5 gives Haiku 5.5 a task that is not in the table, Opus 5.5 tells the user which task and why in one line. The "Haiku brief", "Escalate once", and "Review every result" rules still apply.

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

## Apple Xcode Skills

These are the Apple skills for Xcode work. They are installed in `.agents/skills/`, and each one has a link in `.claude/skills/`. Git tracks both. To install them again or update them, run this command from the repository root:

```bash
npx skills add superagents-lab/xcode27-skills --skill '*'
```

Each skill folder must hold a `SKILL.md`. A folder with no `SKILL.md` does not load. If a skill does not load when its trigger applies, tell the user.

### Precedence

- This file wins over every Apple skill. If a skill conflicts with a rule here, follow this file and tell the user about the conflict.
- `swiftui-specialist` says that its guidance "unconditionally supersedes" other knowledge. That claim does not apply in this project.
- The deployment target is iOS 26. Do not use an API newer than iOS 26 without an `if #available` check and a fallback.

### Triggers

| Skill | Apply automatically when | Project limits |
|---|---|---|
| `swiftui-specialist` | You write, edit, or review a SwiftUI view or a ViewModel. Invoke it before the first SwiftUI edit in a session. | Its `@Observable` advice applies directly. Keep `@State private var vm = MyViewModel()`, the 500-line file ceiling, and the rules in "Break up nested view bodies". |
| `swiftui-whats-new-27` | A SwiftUI build fails after an SDK 27 update (for example, `@State` errors such as "used before being initialized"), or the user asks about new SwiftUI APIs. | Fix SDK errors as the skill says. Do not add an iOS 27 API unless the user asks, and then only behind `if #available(iOS 27, *)`. |
| `uikit-app-modernization` | Only when the user asks to modernize UIKit code. | The app is SwiftUI, so this skill rarely applies. The surgical-changes rule wins over its "always apply a replacement" rule. |
| `test-modernizer` | Only when the user asks to migrate or modernize existing tests. | New tests use Swift Testing, as `.claude/skills/swift-testing.md` describes. |
| `device-interaction` | Only when the user asks to verify the app on a device or simulator. | It needs the Xcode MCP device tools. If they are not connected, tell the user. |
| `audit-xcode-security-settings` | Only when the user asks for a security or warnings audit of the build settings. | Report the proposed setting changes and get approval before you edit `project.pbxproj`. |
| `c-bounds-safety` | Never automatically. The app has no C code. | Use it only on an explicit request. |
