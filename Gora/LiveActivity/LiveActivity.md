# LiveActivity

The commute Live Activity shows route progress on the Lock Screen and in the Dynamic Island.
The app owns the data and the update schedule. The `GoraLiveActivity` extension draws it.

## CommuteActivityAttributes.swift

**`CommuteActivityAttributes`** holds the data of the activity. Both targets compile this file.
The extension target references it by path in `project.pbxproj`. Mark every type `nonisolated`,
because the app target uses `MainActor` as the default isolation and ActivityKit needs plain
`Codable` types.

- **Static values**: `segments` (one per leg, `weight` is the planned minutes), `boundaryLabels`
  (station names under the bar), and `destinationName`.
- **`ContentState`**: `phase`, `progress`, `eta`, `lastFixAt`, `actionText`, `legLabel`,
  `stopsLeft`, `nextLineName`, `legIndex`.
- **`Phase`**: `live`, `waiting` (the current leg is a walk between two ride legs), `arrived`.

## CommuteActivitySnapshot.swift

**`CommuteActivitySnapshot`** builds `Attributes` and `State` from a `RouteResult` and the
`CommuteProgressEngine`. It makes no ActivityKit calls.

- **Update policy** (`shouldSend`): send at once when the leg index, the action text, or the phase
  changes. Otherwise wait 15 seconds, then send when progress moves 0.01, the ETA moves 60
  seconds, or 60 seconds pass.
- **`staleAfterSeconds`** (180): the controller sets `staleDate` to `lastFixAt` plus this value.
- **Texts**: the action text is `RouteLeg.instruction`. Line names come from the loaded graph
  through `RouteStore.lineDisplayName(_:)`. Station names come from the route.

## CommuteLiveActivityController.swift

**`CommuteLiveActivityController`** (`@MainActor`, shared) starts, updates, and ends the one
activity.

- `start` ends any older activity, then requests a new one.
- `reattach(...)` adopts the active activity from an earlier app run and ends extra ones. It starts a
  new activity when none is active.
- `update(engine:now:)` applies the update policy.
- `endArrived(now:)` shows the arrived state and dismisses the card after 120 seconds.
- `end()` dismisses the card at once. It does nothing when no commute runs.
- `endOrphans()` ends activities that an earlier app run left. `ContentView` calls it at launch when no commute is restored.

## Hooks in ContentView

`ContentView+LiveActivity.swift` holds the code. `ContentView` only calls it.

- `startCommute` calls `beginLiveActivity`. It also turns on background location updates.
- `endCommute` calls `endLiveActivity`. It turns background location updates off.
- The 1 Hz commute task calls `tickLiveActivity`. It ends Commute Mode when the passenger is
  within 30 m of the end of the last leg.
- `onDisappear` keeps location tracking on while a commute runs.

## Device checks

Set a signing team for the `GoraLiveActivity` target. Enable Live Activities for Gora in Settings.
