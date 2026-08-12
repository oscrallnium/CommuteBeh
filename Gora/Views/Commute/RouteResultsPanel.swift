//
//  RouteResultsPanel.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/10/26.
//

import SwiftUI
import UIKit

// MARK: - Route Results Panel

struct RouteResultsPanel: View {
    let options: [RouteOption]
    /// Shared with `ContentView` and, through it, `CommuteModeView` — lets the selected
    /// card's shape morph into the Commute Mode card's shape when `onSelect` fires.
    let morphNS: Namespace.ID
    let onSelect: (RouteOption) -> Void
    let onPreview: (RouteOption) -> Void

    /// ID of the currently expanded card.
    @State private var selectedID: RouteOption.ID?
    /// ID of the option whose full leg breakdown is showing, if any. Only ever set for
    /// the selected card — the disclosure only exists on the one that's expanded.
    @State private var detailID: RouteOption.ID?
    /// Whether the panel is contracted to just the handle + summary row.
    @State private var isMinimized: Bool = false
    /// Natural height of the header plus card list, tracked continuously as a cache.
    /// The minimize crossfade needs this value the instant it starts, before a fresh
    /// measurement of the new state exists.
    @State private var contentHeight: CGFloat = 0
    /// Height of the collapsed summary row, tracked the same way and for the same
    /// reason as `contentHeight`.
    @State private var minimizedRowHeight: CGFloat = 0
    /// Non-nil only during the minimize crossfade. It stops the ZStack from ballooning to
    /// max(minimized, content) while both branches are in the layout. Do not lock the height
    /// on every content change, which makes the detail reveal lag a frame.
    @State private var minimizeCrossfadeHeight: CGFloat?
    /// Display strings per option, rebuilt only when the option list changes.
    /// Not seeded in `init`, because `State(initialValue:)` evaluates its argument on every
    /// init. The card's `??` fallback covers the first frame.
    @State private var summaries: [RouteOption.ID: RouteCardSummary] = [:]

    private static let maxScrollHeight: CGFloat = UIScreen.main.bounds.height * 0.50

    init(options: [RouteOption], morphNS: Namespace.ID,
         onSelect: @escaping (RouteOption) -> Void, onPreview: @escaping (RouteOption) -> Void) {
        self.options = options
        self.morphNS = morphNS
        self.onSelect = onSelect
        self.onPreview = onPreview
        // Seeds the first card as expanded before the first layout pass. Selecting it later
        // animates the panel's height, which races the `VisibleBottomKey` measurement and
        // leaves `fitMap` framing the route against a stale panel height.
        _selectedID = State(initialValue: options.first?.id)
    }

    // Selected option floats to index 0; others follow in their original order.
    private var displayOptions: [RouteOption] {
        guard let id = selectedID,
              let idx = options.firstIndex(where: { $0.id == id }) else { return options }
        var sorted = options
        let selected = sorted.remove(at: idx)
        sorted.insert(selected, at: 0)
        return sorted
    }

    private var selectedOption: RouteOption? {
        options.first { $0.id == selectedID }
    }

    /// Every option, or just the selected one once its details are open. `ForEach` keys on
    /// `RouteOption.id`, so the surviving card is the same view instance either way and its
    /// leg list animates in as a content change.
    private var visibleOptions: [RouteOption] {
        guard let detailID else { return displayOptions }
        return displayOptions.filter { $0.id == detailID }
    }

    private static func buildSummaries(_ options: [RouteOption]) -> [RouteOption.ID: RouteCardSummary] {
        Dictionary(uniqueKeysWithValues: options.map { ($0.id, RouteCardSummary(result: $0.result)) })
    }

    var body: some View {
        VStack(spacing: 0) {
            dragHandle

            // ZStack, not VStack: both branches are in the layout during the minimise swap.
            // Stacked vertically their heights would add and the panel would balloon.
            ZStack(alignment: .top) {
                if isMinimized {
                    minimizedRow
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: MinimizedRowHeightKey.self, value: geo.size.height)
                            }
                        )
                        .transition(.opacity)
                } else {
                    expandedContent
                        .fixedSize(horizontal: false, vertical: true)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: CardsBranchHeightKey.self, value: geo.size.height)
                            }
                        )
                        .transition(.opacity)
                }
            }
            // Locks the container height for the length of the minimize crossfade only.
            // `setMinimized` sets it in the same transaction that flips `isMinimized` and
            // releases it once the spring settles.
            .frame(height: minimizeCrossfadeHeight, alignment: .top)
        }
        .background(detailID == nil ? DesignTokens.Colors.cream : DesignTokens.Colors.paper)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 12, x: 0, y: -4)
        // Passive tracking. Neither drives an animation; they give `setMinimized` a current
        // starting height to lock to when a crossfade begins.
        .onPreferenceChange(CardsBranchHeightKey.self) { height in
            if height > 0 { contentHeight = height }
        }
        .onPreferenceChange(MinimizedRowHeightKey.self) { height in
            if height > 0 { minimizedRowHeight = height }
        }
        // Keyed on leg ids, not option ids. Option ids survive walk refinement, but refinement
        // rewrites times, fares and geometry, so an id-only key would serve stale figures.
        // Rebuilt legs always move the signature.
        .onChange(of: options.flatMap { $0.result.legs.map(\.id) }, initial: true) { _, _ in
            summaries = Self.buildSummaries(options)
            // Refinement can still *drop* an option whose access walk turned out to be
            // too long to walk, so the selection and the open detail view are re-checked
            // against what survived.
            let ids = options.map(\.id)
            if !ids.contains(where: { $0 == selectedID }) {
                selectedID = ids.first
            }
            if let id = detailID, !ids.contains(id) {
                detailID = nil
            }
        }
    }

    /// Crossfades to `target`, locking the container's height to a sensible starting
    /// point for the length of the spring and releasing it once the spring settles.
    /// The only place `minimizeCrossfadeHeight` is written.
    private func setMinimized(_ target: Bool) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
            isMinimized = target
            minimizeCrossfadeHeight = target
                ? (minimizedRowHeight > 0 ? minimizedRowHeight : nil)
                : (contentHeight > 0 ? contentHeight : nil)
        } completion: {
            minimizeCrossfadeHeight = nil
        }
    }

    // MARK: Drag handle — tap to minimize / maximize

    private var dragHandle: some View {
        Button {
            setMinimized(!isMinimized)
        } label: {
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 36, height: 4)
                    .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(detailID != nil)
    }

    // MARK: Minimized row — "Search Results" label + expand button

    private var minimizedRow: some View {
        HStack {
            Text("Search Results")
                .font(.subheadline.weight(.heavy))
                .kerning(0.5)
            Spacer()
            Button {
                setMinimized(false)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(8)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: Expanded content — header + scrollable card list
    //
    // One branch covers both the full option list and the single-card detail state.
    // The header drops out once one card stands alone with its leg list open.

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if detailID == nil {
                Text("BEST WAY THERE")
                    .font(.subheadline.weight(.heavy))
                    .kerning(0.8)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(visibleOptions) { option in
                        RouteOptionCard(
                            option: option,
                            summary: summaries[option.id] ?? RouteCardSummary(result: option.result),
                            isExpanded: option.id == selectedID,
                            showsDetails: option.id == detailID,
                            morphNS: morphNS,
                            onExpand: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    selectedID = option.id
                                }
                                onPreview(option)
                            },
                            onToggleDetails: {
                                withAnimation(DesignTokens.Motion.morph) {
                                    detailID = (detailID == option.id) ? nil : option.id
                                }
                            },
                            onSelect: { onSelect(option) }
                        )
                        .jellyEffect(trigger: option.id == selectedID)
                        // The siblings that drop out of `visibleOptions` when details
                        // open fade rather than pop; the one that stays is the same
                        // view instance throughout, so this never touches it.
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)
                // Required, not decoration: `jellyEffect` springs the card past scale 1.0 and
                // a ScrollView clips to its bounds, so the overshoot and shadow need margin.
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            // Self-sizing to min(content, cap). Modifier order matters: `fixedSize` must stay
            // outermost so the frame clamps the ScrollView's ideal height. Swapped, the frame
            // means "flexible up to the cap" and the list expands with empty space below.
            .frame(maxHeight: Self.maxScrollHeight)
            .fixedSize(horizontal: false, vertical: true)
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
