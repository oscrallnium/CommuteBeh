# Modifiers

## CommuteSheetPresentation.swift

`View.commuteSheet(...)` floats the commute card over the map while `isActive` is true.

- **Card state** — `CommuteCardState` has two cases, `collapsed` and `expanded`. Their heights
  come from `CommuteSheetHeight` and scale with Dynamic Type. The card cannot be dismissed. It
  enters and leaves with a move-from-bottom transition.
- **Placement** — the card layer ignores the safe area. The card sits 16 pt from the left, right
  and bottom screen edges. The map stays interactive outside the card.
- **Card top** — the card measures its top edge with `onGeometryChange` in window coordinates.
  `onSheetTopChange` passes the value to the parent after it stays unchanged for 120 ms, so a
  snap sends one value. The parent feeds it to the camera strip. The value is 0 when the card hides.
- **Control column** — the modifier draws `CommuteControlColumn` in an overlay on the map, 14 pt
  above the card top and 16 pt from the trailing edge. It follows every frame of a drag. The column
  merges as soon as the live card top rises 4 pt above its settled collapsed top, and splits when
  the top returns. A change of more than 24 pt between two measures is a snap. The column then
  animates to the new top with `DesignTokens.Motion.cardEnter` instead of a jump.
- **State** — the modifier owns the card state, the merge flag and the End Commute alert flag.
  Both flags pass into the card content.
