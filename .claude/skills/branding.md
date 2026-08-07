# Branding & Visual Identity

> **Status: Founding tokens defined (2026-07-04).** The token layer lives in `CommuteBeh/DesignTokens.swift` (`DesignTokens.TypeScale/Space/Radius/Colors/Motion`, `extension TransportMode { color/icon/lineWidth }`, `View.cardShadow(y:)`), per `.claude/audits/home-admin-ui-audit.md`. Consume tokens, not literals. Full brand identity (custom typeface, app icon, brand palette beyond `#127BED`) remains to be defined.

## App Identity

| Property | Current Value | Notes |
|---|---|---|
| App name | **Gora** | Product / display name; `CommuteBeh` remains the Xcode project/scheme name |
| Display name | Gora | Update in `Info.plist` / target settings |
| App icon | Xcode default | Replace `AppIcon.appiconset` — see below |
| Accent color | System default | Set in `AccentColor.colorset` |

## Color System

No custom color system has been defined yet. All colors are currently inline SwiftUI system colors.

When branding is established, define named colors in `Assets.xcassets` and reference them as `Color("BrandPrimary")` etc. — or use a `BrandColors` enum:

```swift
// Proposed pattern — implement once brand colors are confirmed
enum BrandColors {
    static let primary   = Color("BrandPrimary")
    static let secondary = Color("BrandSecondary")
    static let accent    = Color("BrandAccent")
}
```

## Transit Line Colors

These are functional colors (map legibility), not brand colors. They live in `ExploreViewModel.color(for:)` and the `modeColor(_:)` helpers across the codebase.

| Line | Current Color | Matches Real-World? |
|---|---|---|
| MRT-3 | Blue `#127BED` | Yes (DOTC blue) |
| LRT-1 | Green `#1AB233` | Yes (LRT-1 green) |
| LRT-2 | Purple `#8C1AE5` | Yes (LRT-2 purple) |
| EDSA Bus | Orange `#F4800` | Approximate |
| Jeepney routes | Red/pink/teal variants | Arbitrary — for visual distinction |
| Tricycle | Teal `#00AD7A` | Arbitrary |

## Typography

Currently relies entirely on system fonts via SwiftUI `.font(.headline)`, `.font(.caption)`, etc. No custom typeface defined yet.

When typography is defined, document the font family, weights, and size scale here.

## App Icon

The app icon is the Xcode-generated placeholder. To replace:
1. Design a 1024×1024pt icon (single image, no alpha).
2. Drop it into `CommuteBeh/Assets.xcassets/AppIcon.appiconset/`.
3. Update `Contents.json` to reference the new image.

Conceptual directions to consider:
- A jeepney silhouette + map pin
- Stylised Metro Manila skyline
- Abstract transit network / node graph

## Pending Brand Decisions

- [ ] App name confirmation (keep "CommuteBeh" or rebrand?)
- [ ] Primary + secondary brand color palette
- [ ] App icon design
- [ ] Custom typeface (or stick with system SF Pro?)
- [ ] Onboarding / splash screen style
- [ ] Dark mode color adjustments for map overlays

## Where Colors Are Currently Duplicated

Consolidated (2026-07-04): the three `modeColor(_:)` copies in `ContentView` / `RouteResultCard` / `RouteLegRow` were replaced by `extension TransportMode { var color: Color; var icon: String; var lineWidth: CGFloat }` in `DesignTokens.swift`. `ExploreViewModel.color(for:)` still holds its own per-line (not per-mode) mapping — intentionally separate; unify only if line colors become tokens.
