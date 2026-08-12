//
//  RouteOptionCard.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/10/26.
//

import SwiftUI

// MARK: - Route Option Card

struct RouteOptionCard: View {
    let option: RouteOption
    let summary: RouteCardSummary
    let isExpanded: Bool
    /// Whether this card's leg-by-leg breakdown is open. True for at most one card, and only
    /// one that is also `isExpanded`.
    let showsDetails: Bool
    /// Shared with `CommuteModeView`'s compact card — see `morphNS` on `RouteResultsPanel`.
    let morphNS: Namespace.ID
    let onExpand: () -> Void
    let onToggleDetails: () -> Void
    let onSelect: () -> Void

    /// Card-local — carries the one matchedGeometryEffect left in this view, the
    /// divider that splits in two when details open. See `expandedSection`.
    @Namespace private var dividerNS

    private var result: RouteResult { option.result }

    // VStack with a persistent header row lets SwiftUI interpolate the card's height
    // smoothly as the conditional sections are added/removed below it.
    var body: some View {
        Group {
            // Tagged only on the expanded card, which is the one shape that can morph into
            // `CommuteModeView`. Several cards sharing one (id, namespace) pair at once is not
            // what `matchedGeometryEffect` supports.
            if isExpanded {
                cardShape.matchedGeometryEffect(id: "commute-card", in: morphNS)
            } else {
                cardShape
            }
        }
    }

    private var cardShape: some View {
        VStack(alignment: .leading, spacing: 0) {
            compactBar
            if !isExpanded {
                collapsedSubRow
                    .transition(.opacity)
            }
            if isExpanded {
                expandedSection
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
        .clipped()
        .background(DesignTokens.Colors.paper)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(DesignTokens.Colors.ink.opacity(isExpanded ? 1 : 0.25),
                              lineWidth: isExpanded ? 2 : 1)
        )
        .shadow(color: isExpanded ? .black.opacity(0.10) : .clear, radius: 8, x: 0, y: 3)
    }

    // MARK: Compact bar — only rendered when collapsed.

    @ViewBuilder
    private var compactBar: some View {
        if !isExpanded {
            Button(action: onExpand) {
                HStack(alignment: .center) {
                    HStack(spacing: 6) {
                        // "2 hours, 32 minutes" is far wider than the "152 min" this
                        // row was sized for, and it shares the line with the badge
                        // and the fare — clamp rather than letting it push them out.
                        Text(summary.durationText)
                            .font(.system(.body, design: .default, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        LabelBadge(label: option.label, isCompact: true)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("₱").font(.footnote.bold())
                            Text(summary.fareText).font(.body.bold())
                        }
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .transition(.opacity)
        }
    }

    // MARK: Collapsed-only sub-row

    private var collapsedSubRow: some View {
        HStack(spacing: 4) {
            Text(summary.arriveText)
                .font(.caption).foregroundStyle(.secondary)
            if !summary.payments.isEmpty {
                Text("·").font(.caption).foregroundStyle(.secondary)
                Text(summary.payments.map { RouteCardSummary.shortName(forPayment: $0) }
                        .joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: Expanded-only section
    // Duration, fare and arrival, a dashed divider, then the leg list while `showsDetails`.
    // The divider uses `matchedGeometryEffect` so it slides down rather than cross-fading,
    // which reads as one divider splitting into two.

    private var expandedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Row 1: label badge | payment chips
            HStack(spacing: 8) {
                LabelBadge(label: option.label)
                Spacer()
                // Two chips is the practical limit before the row wraps into the
                // duration line on the narrowest devices.
                ForEach(summary.payments.prefix(2), id: \.self) { paymentChip($0) }
            }

            // Row 2: duration leading, fare trailing. "Arrive by" and "TOTAL FARE" align
            // because each is the second child of a top-aligned VStack of equal height.
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        ForEach(summary.durationParts, id: \.self) { part in
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(part.value)
                                    .font(.system(.largeTitle, weight: .heavy))
                                Text(part.unit)
                                    .font(.system(.title3, weight: .heavy))
                            }
                        }
                    }
                    .foregroundStyle(DesignTokens.Colors.ink)

                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Arrive by \(summary.arrivalTime) \(summary.arrivalPeriod)")
                            .font(.caption2.weight(.bold))
                            .kerning(0.2)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("₱").font(.title3.weight(.heavy))
                        Text(summary.fareText).font(.system(.largeTitle, weight: .heavy))
                    }
                    .foregroundStyle(DesignTokens.Colors.ink)
                    Text("TOTAL FARE")
                        .font(.caption2.weight(.bold))
                        .kerning(0.6)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }

            // One divider sits below the arrival row in both states, but which one changes:
            // collapsed it is this copy, expanded it is the copy below the leg list. The
            // shared id makes the original slide down instead of a second one fading in.
            if showsDetails {
                dashedDivider
                    .transition(.opacity)
                RouteLegList(legRows: summary.legRows)
                    .transition(.opacity)
                dashedDivider
                    .matchedGeometryEffect(id: "divider", in: dividerNS)
            } else {
                dashedDivider
                    .matchedGeometryEffect(id: "divider", in: dividerNS)
            }

            // Stats row and the button are one unit so they move together when the leg list
            // pushes them down. Keep the button in the tree and collapse its height to zero
            // rather than removing it: a removal transition fades alpha but never moves the frame.
            VStack(alignment: .leading, spacing: showsDetails ? 0 : 14) {
                // Row: trip stats | details disclosure. Always present — this is the
                // control that reopens the button once details are hidden again.
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(summary.statsText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 8)
                    Button(action: onToggleDetails) {
                        HStack(spacing: 4) {
                            ReelSwap(isAlternate: showsDetails, distance: 22) {
                                Text("See route details")
                                    .font(.subheadline.weight(.bold))
                            } alternate: {
                                Text("Hide route details")
                                    .font(.subheadline.weight(.bold))
                            }
                            ReelSwap(isAlternate: showsDetails, distance: 14) {
                                Image(systemName: "chevron.down")
                                    .font(.caption.weight(.bold))
                            } alternate: {
                                Image(systemName: "chevron.up")
                                    .font(.caption.weight(.bold))
                            }
                        }
                        .foregroundStyle(Color.charcoal)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }

                Button(action: onSelect) {
                    Text("USE THIS ROUTE")
                        .font(.system(.headline, design: .default, weight: .bold))
                        .kerning(1.0)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Capsule().fill(DesignTokens.Colors.action))
                }
                .buttonStyle(.plain)
                .frame(maxHeight: showsDetails ? 0 : nil)
                .opacity(showsDetails ? 0 : 1)
                .clipped()
                .allowsHitTesting(!showsDetails)
            }
        }
        .padding(18)
        .animation(DesignTokens.Motion.morph, value: showsDetails)
    }

    private var dashedDivider: some View {
        // A 1 pt-tall Path rather than Divider(): the dashed rule is part of the
        // card's visual language and Divider has no dash style.
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0.5))
                p.addLine(to: CGPoint(x: geo.size.width, y: 0.5))
            }
            .stroke(DesignTokens.Colors.ink.opacity(0.18),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
        }
        .frame(height: 1)
    }

    @ViewBuilder
    private func paymentChip(_ paymentID: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: RouteCardSummary.symbol(forPayment: paymentID))
                .font(.caption)
            Text(RouteCardSummary.shortName(forPayment: paymentID))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(
            Capsule().strokeBorder(DesignTokens.Colors.ink.opacity(0.25), lineWidth: 1)
        )
    }
}
