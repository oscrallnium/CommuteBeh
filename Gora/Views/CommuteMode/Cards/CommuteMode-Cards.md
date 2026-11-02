# Cards

The content of the commute card, shown while Commute Mode is active. `Views/Commute/Cards`
holds the cards shown before a route is chosen.

## CommuteModeView.swift

**`CommuteModeView`** reads the live `CommuteProgressEngine` and `RouteStore`. It builds a
`CommuteSheetModel` and passes it to `CommuteSheetCard`. The remaining distance is the metres left
on the current leg plus the planned length of each later leg. The speed shows only when it is
zero or more.

It also defines **`CommuteCameraMode`** (`twoD` / `threeD`), the two camera poses of the map.
`ContentView+Camera.swift` and `Views/CommuteControlColumn.swift` use it.

## CommuteSheetCard.swift

**`CommuteSheetCard`** is the floating commute card. It draws a `CommuteSheetModel` on regular
Liquid Glass with a 30 pt corner radius and a 36 by 5 pt grabber. The glass is
`DesignTokens.Materials.cardGlass`, tinted with `Color(.systemGray5)` at 40 %: a charcoal gray in
dark mode, a light gray in light mode. The blur keeps
map lines out of the text. Clear glass refracts the map sharply, so it does not suit this card. The header shows the
destination, the remaining distance, the speed and the arrival time without the AM/PM period, in
both states. A tap on the header expands the card. The expanded state adds a 0.5 pt hairline and
`CommuteLegList`.

A vertical drag on the header moves the card height live between `CommuteSheetHeight.collapsed`
and `CommuteSheetHeight.expanded`. On release the card snaps with a spring to the nearer state. It
follows the drag direction when the drag distance or the release velocity exceeds 24. The card
state is a `CommuteCardState` binding. The arrived state shows "Arrived" and a Done button, and
collapses the card. The End Commute alert attaches to the card.

The header destination uses `instruction` (title3 semibold). The subtitle uses `bodyLarge` (body).
The arrival time uses `etaLarge` (title semibold), and "arrive" uses `body`. A leg row has a 68 pt
height. Its title uses `rowTitleLarge` (`rowTitleLargeCurrent` for the current row), and its
subtitle and duration use `body`. The list is 212 pt tall and shows about three rows.

## CommuteLegList.swift

**`CommuteLegList`** is the scrolling leg breakdown with a rail of nodes. **`CommuteLegRowModel`**
turns one `RouteLeg` into the strings and the rail color of a row. A ride row uses the graph line color, or the mode color when the line has none. A walk row uses the walk color. A completed row uses `Faint` for its text, bar and node border. The current row has a
`Tangerine` node and a bold title. A walk row draws a solid 4 pt bar in the walk color. A ride row draws a 6 pt bar. The list starts
4 pt below the hairline. The Done button is a `Tangerine` fill with `Licorice` text, and "Arrived" uses `Jade`.
`CommuteSheetCard` keeps the hairline and the list in the layout in both states. The card height
reveals them. Their opacity follows the live card height. It goes from 0 at the collapsed
height to 1 at `CommuteSheetHeight.midpoint`, so the list shows during a drag. The bottom 18% of
the list fades out with a mask.
