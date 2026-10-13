# GoraLiveActivity

Widget extension that draws the commute Live Activity. It reads `CommuteActivityAttributes`
from `Gora/LiveActivity/`. It holds no app logic.

## Files

- **GoraLiveActivityBundle.swift**: the `@main` widget bundle.
- **CommuteLiveActivity.swift**: the `ActivityConfiguration`, the Lock Screen card and the
  Dynamic Island regions. The staleness flag comes from `context.isStale`.
- **CommuteLockScreenView.swift**: the Lock Screen and banner card.
- **CommuteIslandViews.swift**: compact bar, compact time, minimal ring, expanded leading and body.
- **CommuteStatusViews.swift**: the time-left timer and the footer status line.
- **SegmentedRouteBar.swift**: ride capsules, dotted walk lines, progress fill and marker.
- **LiveActivityPalette.swift**: the monochrome colors for light, dark, and the island.
- **CommuteLiveActivityPreviews.swift**: one preview per state and presentation.
- **Info.plist**: declares the WidgetKit extension point.

## Rules

- The fill and the marker both draw at `state.progress`. They move on each update with an
  0.8 second ease.
- The timer text counts down to `eta` and updates without an app update.
- A stale state dims the timer and the summary, dashes the marker, and removes the Live dot.
- The extension target does not use `MainActor` as the default isolation.
