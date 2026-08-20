# Gora — Developer Documentation

Gora is a multimodal transit navigation app for Metro Manila
and Los Baños, Laguna. It finds optimal door-to-door routes across MRT-3, LRT-1, LRT-2,
buses, jeepneys and tricycles using an A\* search over a transit graph, and it ships with the
authoring tools used to build that graph in the first place.

The product is two deployables:

| Tier | Name | Stack | Location |
|---|---|---|---|
| Client | Gora iOS app | Swift 6 · SwiftUI · MapKit · iOS 26+ | `/Users/obiee/Desktop/proj/CommuteBeh` |
| Server | `commutebeh-rails` | Ruby 3.4 · Rails 7.1 API-only · Postgres | `/Users/obiee/Desktop/proj/commutebeh-rails` |

They are separate git repositories. This documentation lives in the iOS repo and describes both.

---

## Read this in order

| # | Page | What it answers |
|---|---|---|
| 1 | [Overview](01-overview.md) | What the app does, who uses it, the vocabulary |
| 2 | [Architecture](02-architecture.md) | How the two tiers fit together; runtime & concurrency model |
| 3 | [Data Model](03-data-model.md) | The transit graph — JSON shape and Postgres schema |
| 4 | [Routing Engine](04-routing-engine.md) | A\*, cost strategies, access walks, legs, fares |
| 5 | [iOS App](05-ios-app.md) | File layout, MVVM conventions, screen-by-screen tour |
| 6 | [Backend](06-backend.md) | Rails service internals, `GraphService`, deployment |
| 7 | [API Reference](07-api-reference.md) | Every endpoint, envelope, and error code |
| 8 | [Graph Sync](08-graph-sync.md) | How the client gets and caches the graph OTA |
| 9 | [Authoring & Admin](09-authoring-and-admin.md) | Recording routes, editing stops, admin rules |
| 10 | [Development Guide](10-development.md) | Build, test, run, conventions, environment |
| 11 | [Known Issues & Drift](11-known-issues.md) | Where docs, code and data disagree today |

## Fast paths

- **"I need to add a jeepney route."** → [9. Authoring & Admin](09-authoring-and-admin.md)
- **"Why did routing return no result?"** → [4. Routing Engine § Failure modes](04-routing-engine.md#failure-modes)
- **"What does the server send the app?"** → [7. API Reference](07-api-reference.md) + [3. Data Model](03-data-model.md)
- **"I'm onboarding."** → [1](01-overview.md) → [2](02-architecture.md) → [5](05-ios-app.md) → [10](10-development.md)

## Conventions used in these pages

- Code references are `path/to/File.swift:123` and are clickable in most editors.
- Mermaid diagrams render on GitHub, GitLab, and in VS Code with the Markdown Preview
  Mermaid extension.
- Anything marked **Drift** is a known inconsistency, catalogued in [11](11-known-issues.md).
