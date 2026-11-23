# Cards

The route-choice sheet shown once `RouteStore.routeOptions` has results, before Commute
Mode starts. (The bottom card shown *during* Commute Mode, `CommuteModeView`, lives in
`Views/CommuteMode/Cards` instead — it tracks live progress, not a search result.)

## RouteChoiceSheet.swift

**`RouteChoiceSheet`** — Liquid Glass bottom sheet (`DesignTokens.Materials.routeSheetGlass`) for the selected route option. It shows:

- An overline with an icon and the option label: Fastest, Balanced, or Cheapest.
- The duration and a fare capsule. The capsule has a `Color.jade` tint at 18% and `.primary` text. `ViewThatFits` stacks them at large text sizes.
- "Arrive by" with the arrival time.
- The ride list when the sheet is collapsed, or the leg timeline when it is expanded. The compressed state hides both.
- A details toggle and the "Start Commute" button.

The map sets `selectedID`. The sheet shows a hint instead of the button while `canStartCommute` is false.
The commute sheet replaces it when Commute Mode starts. The sheet reads `RouteStore` from the environment
for line names, mode plural names, and payment configs. `ContentView` injects it.

The panel, the glass, `Motion.routeDetail(reduceMotion:)`, and the opacity transition of the leg list
make the sheet animation. Change them only on purpose.

Each tap that changes `isDetailExpanded` runs in `withAnimation(Motion.routeDetail(reduceMotion:))`.
The transaction then animates the bottom safe-area inset in `ContentView` and the sheet content together.
Do not put an `.animation(_:value: isDetailExpanded)` inside the sheet: the inset then resizes at once,
the content animates alone, and the buttons in the bottom row slide.

While `RouteStore.locationAccess` is `off`, `ContentView.routeChoicePanel` stacks a `LocationOffBanner` above
the sheet with an 8 pt gap. The banner reads "The map can’t show where you are." and has Turn On and Dismiss.
Dismiss hides it for the current search result, and a new search shows it again. The banner sits in the
same panel as the sheet, so the panel top, which the map callouts read, rises above the banner. The sheet
does not change. With Location off, `canStartCommute` is true, because the rider cannot be near the origin
by position.

The glass of the sheet is a background layer (`.background { Color.clear.goraGlass(...) }`).
Do not apply `goraGlass` to the sheet content. The system then hosts the content inside the glass view,
lays it out from the top edge of the glass while the glass resizes, and the bottom row moves.

### Compressed state

`RouteChoiceState.isCompressed` adds a third state. The compressed sheet shows the grabber, the summary
block, and the "Start Commute" button or the start hint. It hides the schedule row, the ride list or leg
timeline, and the details toggle. `isDetailExpanded` does not change while the sheet is compressed, so an
expand returns to the summary or the details, whichever the sheet showed before.

- **Sections** — `CompressibleSection` wraps each part that hides. Its `CompressLayout` reports the natural
  height multiplied by `1 - progress`, and the section fades with the same value. `progress` is animatable,
  so a `withAnimation` change morphs the height and the opacity on one curve.
- **Drag** — `RouteSheetCompressDrag` moves `progress` with the finger, in the global coordinate space. The
  range is the sum of the natural heights of the sections. The drag works on the grabber and the summary
  block, and on the whole sheet while it is compressed. It never works on the leg timeline, so the timeline
  still scrolls. It starts only when the vertical movement is larger than the horizontal movement.
- **Release** — the state changes when the finger translation or `predictedEndTranslation` reaches half of
  the range in the direction of the change. A shorter or slower drag springs back. The release runs in
  `withAnimation(Motion.routeDetail(reduceMotion:))`. A cancelled drag also springs back.
- **Rubber band** — `RouteSheetCompressMath` clamps the shown progress to 0...1. A drag past an end moves
  the sheet by 20% of the excess, up to 24 pt.
- **Map** — `ContentView` refits the camera after `isCompressed` changes, as it does for `isDetailExpanded`.
- **VoiceOver** — the grabber has the actions "Compress Sheet" and "Expand Sheet".

`SummaryCache` is in `RouteSummaryCache.swift`, `SheetActionSize` is in `SheetActionSize.swift`, and the
previews are in `RouteChoiceSheetPreview.swift`.

## RouteChoiceRideList.swift

**`RouteChoiceRideList`** — the collapsed ride list in a `Color.haze` box. It shows one row for each ride:
the mode icon in the leg color, a title, and the minutes. A leg that has alternative lines reads
"Any of N <plural>". With more than 3 rides, the list shows 2 rides and then a "N more rides" button.
The button sets `isDetailExpanded`. A "Walk in total" row and `PaymentFactRow` follow the rides.

## PaymentFactRow.swift and PaymentMethodIcon.swift

**`PaymentFactRow`** — the payment methods of the route. The full methods are accepted on every ride.
After a "·", the partial methods are dimmed. A partial method is accepted on some lines only.

**`PaymentMethodIcon`** — the one icon view for a payment method. When an image named
`payment.<id>` is in the asset catalog, the view shows that brand image. Otherwise it shows the
`sfSymbol` of the graph's `PaymentMethodConfig`. When that symbol is empty or invalid, it shows `creditcard`.
Every icon is a badge of one size, so brand images and symbols line up. To give a new payment
method a brand image, add an image set named `payment.<id>`. No Swift change is needed.

## RouteChoiceLegList.swift and RouteChoiceLineRows.swift

**`RouteChoiceLegList`** — the expanded leg timeline in `RouteChoiceSheet`: a 30 pt icon circle
per leg, joined by a line. It scrolls past 184 pt. A grouped leg has 2 or more lines. It reads
"Ride any of N <plural>", with "Board at X · Get off at Y" below. A tap on a grouped leg opens
`RouteChoiceLineRows`: each line with its name, fare, and payment icons.
One leg is open at a time.

- A ride leg fills its circle and its solid connector with the leg color, the color the map
  draws. The glyph is `Color.white` when white has at least 3:1 contrast on the fill, else
  `Color.licorice`, chosen by `Color.iconInk(in:)` in the current color scheme.
- A walk leg follows the same rule with the walk color, `Color.cocoa`. Its circle and its
  connector are Cocoa, like the walk line on the map, and `iconInk(in:)` picks its glyph.
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
- While the keyboard shows, the detent is capped at `Layout.keyboardHeightShare` (60 %) of the
  keyboard's top edge, and the content scrolls in a `ScrollView`. On iOS 26 a sheet blends from
  Liquid Glass toward opaque as it nears full height, so the cap keeps it well below that.
  Two `.task` loops read `keyboardWillChangeFrameNotification` and `keyboardWillHideNotification`.
- The selected icon, the location icon and the selected location outline use `Lagoon`, the
  sheet selection color. Save Place uses `Tangerine` with `Licorice` text. See `Design/Design.md`.

## AddPlaceViewModel.swift

**`AddPlaceViewModel`** — the form state. Address search reuses `AddressSearchService` and
`LocationSuggestion` from `State/LocationSearch.swift`. Suggestions are address results only, never stations.

- Typing in the address field clears the picked location. A programmatic text change does not.
- Use Current Location picks `RouteStore.userLocation`. The subtitle is the reverse-geocoded
  address from `MKReverseGeocodingRequest`, or the coordinates when geocoding fails.
- `makePlace()` returns a `SavedPlace`, or nil while `canSave` is false.

## ScheduleStatus.swift and the Schedule parts

A route with a leg on a timetable line shows schedule parts on its existing option. They add no option or label.

- **`ScheduleStatus`** — pure model. `init?(legs:timetable:offsetMinutes:now:)` reads the first leg with a `scheduledDeparture`. The state is `.ready`, `.tooEarly`, `.noMoreToday`, or `.noServiceToday`. `RouteStore.scheduleStatus(for:at:)` builds it.
- **`ScheduleCopy`** and **`ScheduleFormat`** — every string and symbol, in 12-hour or 24-hour time.
- **`ScheduleTicker`** — wraps a part in `TimelineView(.everyMinute)`. A route with no timetable leg gets nil.
- **`ScheduleStatusBlock`** — the two status lines. **`ScheduleTripRow`** — the trip times. **`ScheduleLegLines`** — the lines in the expanded leg.
- `RouteChoiceSheet.useButton` turns off with the reason as a second line when the status is not `.ready`.
