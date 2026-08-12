//
//  CommuteSearchPanel.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/10/26.
//

import SwiftUI

/// Which search field holds focus. Declared at file scope rather than inside a view so
/// `ContentView` and `CommuteSearchPanel` can share one `@FocusState`.
enum SearchField { case origin, destination }

// MARK: - Commute Search Panel

/// The origin and destination entry surface at the top of the Commute tab. Collapses to a
/// pill while a search runs or results show, and expands to the full card otherwise.
/// It owns the layout only; every action arrives from `ContentView` as a closure.
struct CommuteSearchPanel: View {
    let routeStore: RouteStore
    @Binding var originText: String
    @Binding var destinationText: String
    @FocusState.Binding var focusedField: SearchField?
    let namespace: Namespace.ID
    let showSearchProgress: Bool

    let onReset: () -> Void
    let onSearch: () -> Void
    let onSwap: () -> Void
    let onClearOrigin: () -> Void
    let onClearDestination: () -> Void
    let onSelectOrigin: (LocationSuggestion) -> Void
    let onSelectDestination: (LocationSuggestion) -> Void

    // MARK: Design constants

    /// Inset the panel carries inside the top safe area. `measuresVisibleTop` adds it back
    /// so the published edge describes the panel's outer boundary, not the card within it.
    static let panelPadding: CGFloat = 16

    private static let orange = Color(red: 0.91, green: 0.38, blue: 0.16)
    private static let originGreen = Color(red: 0.18, green: 0.48, blue: 0.20)
    private static let cardCream = Color(red: 0.96, green: 0.94, blue: 0.90)

    private var isSearchCollapsed: Bool {
        routeStore.isLoading || !routeStore.routeOptions.isEmpty
    }

    var body: some View {
        Group {
            if isSearchCollapsed {
                collapsedSearchPill
                    .transition(.opacity)
            } else {
                expandedSearchCard
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: isSearchCollapsed)
    }

    // MARK: Collapsed pill (shown while loading / showing results)

    private var collapsedSearchPill: some View {
        HStack(spacing: 10) {
            Button(action: onReset) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(.white))
                    .overlay(Circle().strokeBorder(DesignTokens.Colors.ink, lineWidth: 2))
                    .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Circle()
                    .fill(Self.originGreen)
                    .frame(width: 8, height: 8)
                    .matchedGeometryEffect(id: "origin-dot", in: namespace, properties: .position)

                Text(originText)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 120, alignment: .leading)
                    .matchedGeometryEffect(id: "origin-text", in: namespace, properties: .position)

                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)

                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary)
                    .frame(width: 8, height: 8)
                    .matchedGeometryEffect(id: "dest-dot", in: namespace, properties: .position)

                Text(destinationText)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 120, alignment: .leading)
                    .matchedGeometryEffect(id: "dest-text", in: namespace, properties: .position)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Capsule().fill(.white))
            .overlay(Capsule().strokeBorder(DesignTokens.Colors.ink, lineWidth: 2))
            .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 2)

            Spacer()
        }
        .measuresVisibleTop(outerPadding: Self.panelPadding)
    }

    // MARK: Expanded card (default search state)

    private var expandedSearchCard: some View {
        VStack(spacing: 6) {
            VStack(spacing: 0) {
                // Origin field
                HStack(spacing: 14) {
                    Circle()
                        .fill(Self.originGreen)
                        .frame(width: 10, height: 10)
                        .matchedGeometryEffect(id: "origin-dot", in: namespace, properties: .position)
                    ZStack(alignment: .leading) {
                        // Invisible anchor for the origin name — used only for geometry matching
                        Text(originText)
                            .font(.system(.body, weight: .semibold))
                            .opacity(0)
                            .matchedGeometryEffect(id: "origin-text", in: namespace, properties: .position)
                            .allowsHitTesting(false)
                        TextField("Start", text: $originText)
                            .font(.system(.body, weight: .semibold))
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .origin)
                            .onChange(of: originText) { _, val in routeStore.updateOriginSuggestions(val) }
                    }
                    if routeStore.isResolvingOrigin {
                        ProgressView().controlSize(.small)
                    } else if !originText.isEmpty {
                        Button(action: onClearOrigin) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.gray.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 15)

                dashedDivider.padding(.horizontal, 18)

                // Destination field
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Self.orange)
                        .frame(width: 10, height: 10)
                        .matchedGeometryEffect(id: "dest-dot", in: namespace, properties: .position)
                    ZStack(alignment: .leading) {
                        // Invisible anchor for the destination name — geometry matching only
                        Text(destinationText)
                            .font(.system(.body, weight: .semibold))
                            .opacity(0)
                            .matchedGeometryEffect(id: "dest-text", in: namespace, properties: .position)
                            .allowsHitTesting(false)
                        TextField("Destination", text: $destinationText)
                            .font(.system(.body, weight: .semibold))
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .destination)
                            .onChange(of: destinationText) { _, val in routeStore.updateDestSuggestions(val) }
                    }
                    if routeStore.isResolvingDestination {
                        ProgressView().controlSize(.small)
                    } else if !destinationText.isEmpty {
                        Button(action: onClearDestination) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.gray.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 15)

                // Action row
                HStack(spacing: 12) {
                    Button(action: onSearch) {
                        Group {
                            if showSearchProgress {
                                ProgressView().tint(.white)
                            } else {
                                Text("SEARCH ROUTE")
                                    .font(.system(.subheadline, weight: .bold))
                                    .kerning(1.2)
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Capsule().fill(Self.orange))
                    }
                    .disabled(!routeStore.canCalculate || routeStore.isLoading)
                    .opacity(!routeStore.canCalculate ? 0.55 : 1)

                    Button(action: onSwap) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 46, height: 46)
                            .background(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 14)

                if let error = routeStore.errorMessage {
                    Text(error)
                        .font(DesignTokens.TypeScale.meta)
                        .foregroundStyle(DesignTokens.Colors.destructive)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 12)
                }
            }
            .background(Self.cardCream)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
            .cardShadow(y: 4)
            // Measure the card, not the enclosing VStack. The suggestion list is a sibling in
            // that stack, so measuring the stack moves the strip edge whenever the list opens
            // or changes, and the camera tasks keyed on that edge re-frame the map per keystroke.
            .measuresVisibleTop(outerPadding: Self.panelPadding)

            // Suggestions — outside the clipped card so they aren't cut off
            if routeStore.showOriginSuggestions && !routeStore.originSuggestions.isEmpty {
                SuggestionList(suggestions: Array(routeStore.originSuggestions.prefix(5))) { suggestion in
                    onSelectOrigin(suggestion)
                }
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
                .cardShadow(y: 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if routeStore.showDestSuggestions && !routeStore.destSuggestions.isEmpty {
                SuggestionList(suggestions: Array(routeStore.destSuggestions.prefix(5))) { suggestion in
                    onSelectDestination(suggestion)
                }
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
                .cardShadow(y: 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(DesignTokens.Motion.suggestEnter, value: suggestionsVisible)
    }

    private var dashedDivider: some View {
        GeometryReader { geo in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0.5))
                path.addLine(to: CGPoint(x: geo.size.width, y: 0.5))
            }
            .stroke(Color.primary.opacity(0.15),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .frame(height: 1)
    }

    private var suggestionsVisible: Bool {
        (routeStore.showOriginSuggestions && !routeStore.originSuggestions.isEmpty) ||
        (routeStore.showDestSuggestions && !routeStore.destSuggestions.isEmpty)
    }
}
