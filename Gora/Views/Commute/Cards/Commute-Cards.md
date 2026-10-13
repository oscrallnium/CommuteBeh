# Cards

The route-choice sheet shown once `RouteStore.routeOptions` has results, before Commute
Mode starts. (The bottom card shown *during* Commute Mode, `CommuteModeView`, lives in
`Views/CommuteMode/Cards` instead — it tracks live progress, not a search result.)

## RouteChoiceSheet.swift

**`RouteChoiceSheet`** — Liquid Glass bottom sheet for the selected route option: badge,
duration, arrival, fare, leg chips, a details toggle, and the "Use This Route" button. The map
sets `selectedID`. The sheet shows a hint instead of the button while `canStartCommute` is false.
The commute sheet replaces it when Commute Mode starts.

## RouteChoiceLegList.swift

**`RouteChoiceLegList`** — the expanded leg timeline in `RouteChoiceSheet`: a 30 pt icon circle
per leg, joined by a line. It scrolls past 184 pt.

- A ride leg fills its circle and its solid connector with the leg color, the color the map
  draws. The glyph is `Color.licorice` or `Color.white`, chosen by `Color.contrastingInk(in:)`
  from the fill's luminance in the current color scheme.
- A walk leg keeps a `Color.haze` circle with a `.primary` glyph. Its connector is dotted
  `Color.smoke`, like the walk dots on the map.
- `RouteChoiceSheet` takes `legColor` from `RouteStore.legColor` and passes it to
  `RouteCardSummary`, which stores the color in each `LegRow`.

## RouteCardSummary.swift

**`RouteCardSummary`** — not a view. Formats a `RouteResult` into the display strings and
`LegRow` values, with the leg color, that the sheet renders (fare text, arrival text, distance labels). The map's time
bubbles also read it. Shared so `RouteChoiceSheet`, `../State/RouteChoiceState`, and
`CommuteMode/Cards/CommuteModeView` never format the same figure two different ways.

## AddPlaceSheet.swift

**`AddPlaceSheet`** — the Liquid Glass sheet that saves a place. It has a name field, six icon
buttons, an address search field, and a Use Current Location row. Save Place stays disabled
until the name is not empty and a location is picked. Save calls `onSave` and closes the sheet.

- With an `editing` place, the title reads "Edit Place" and the button reads "Save Changes".
  The fields start with the place's name, icon and saved address, so Save is enabled at once.
  The saved place keeps its `id` and `createdAt`, and `updatedAt` becomes the save time.
- The sheet uses the system Liquid Glass background only. Do not add a `glassEffect` to its
  content: a second layer draws an inner edge above the home indicator and a touch glow on drag.
- The only detent is the measured content height, so Save Place sits under the last row. The
  address field shows at most four suggestions, and the sheet grows with them.
- The selected icon, the location icon and the selected location outline use `Lagoon`, the
  sheet selection color. Save Place uses `Tangerine` with `Licorice` text. See `Design/Design.md`.

## AddPlaceViewModel.swift

**`AddPlaceViewModel`** — the form state. Address search reuses `AddressSearchService` and
`LocationSuggestion` from `State/LocationSearch.swift`, and matches stations by name.

- Typing in the address field clears the picked location. A programmatic text change does not.
- Use Current Location picks `RouteStore.userLocation`. The subtitle is the reverse-geocoded
  address from `MKReverseGeocodingRequest`, or the coordinates when geocoding fails.
- `makePlace()` returns a `SavedPlace`, or nil while `canSave` is false.
