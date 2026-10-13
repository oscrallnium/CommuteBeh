# Modifiers

`ViewModifier`s, their `View` extension entry points, and the `PreferenceKey` plumbing that
backs a matching extension — grouped together because a `PreferenceKey` only ever exists to be
read by a modifier chain (`.preference(key:value:)` / `.onPreferenceChange(_:)`).

## JellyEffect.swift

**`JellyEffect`** — springs a view's scale down then back up when a trigger value changes.
Applied as `.jellyEffect(trigger:)`, defined in the same file as the `View` extension that
wraps it, per this project's convention of pairing a modifier with its own entry point.

## CommuteLayoutKeys.swift

`PreferenceKey` types that let child views publish layout facts up to `ContentView`, plus the
one `View` extension built on top of them:

- **`VisibleTopKey`** / **`VisibleBottomKey`** — publish the top/bottom edges of the visible map
  strip (bottom edge of the search panel, top edge of the route-choice sheet) in global coordinates.
- **`measuresVisibleTop(outerPadding:)`** — the `View` extension that publishes `VisibleTopKey`;
  apply only to the search card/pill itself, never a container that also holds the transient
  suggestion list.
