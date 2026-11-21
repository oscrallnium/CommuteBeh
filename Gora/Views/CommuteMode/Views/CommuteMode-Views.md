# Views

## CommuteControlColumn.swift

**`CommuteControlColumn`** is the vertical stack of map controls above the commute sheet.

- **Apart** — three 52 pt glass circles, 10 pt apart: 2D/3D, Track and More. The 2D/3D circle shows the
  mode a tap switches to. The Track circle shows `location.fill` while following.
- **Merged** — one More circle. The 2D/3D and Track circles melt into it with
  `GlassEffectContainer` and `glassEffectID`. The parent changes `isMerged` inside
  `withAnimation(DesignTokens.Motion.controlMorph)`.
- **Menu** — the More circle is a `Menu`. Apart, it holds Route Overview, Trip Details and End
  Commute. Merged, it adds a first section with the 2D/3D toggle and Track or Untrack.

With Location off, the Track circle shows `location.slash`, and a tap opens the Turn On Location alert.
Its VoiceOver label is "Location is off. Turn on Location." The More menu adds "Turn On Location" above End
Commute, and the merged menu drops Track. The column reads `RouteStore.locationAccess` from the environment.

Track uses `Ember`. More uses `.primary`, as the 2D/3D label does, because text on glass keeps
system vibrancy.

`ReelSwap` and `LabelBadge` stay in `Views/Commute/Views`.
