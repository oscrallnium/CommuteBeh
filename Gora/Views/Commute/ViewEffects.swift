//
//  ViewEffects.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/10/26.
//

import SwiftUI
import UIKit

// MARK: - Reel Swap

/// A two-state label that swaps by sliding, like a mechanical reel. Both states stay in the
/// view tree, clipped to one line so only one shows.
/// Pass a `distance` that clears the caller's own line height, or the two states overlap.
struct ReelSwap<Primary: View, Alternate: View>: View {
    let isAlternate: Bool
    var distance: CGFloat
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let alternate: () -> Alternate

    var body: some View {
        ZStack {
            primary()
                .offset(y: isAlternate ? -distance : 0)
            alternate()
                .offset(y: isAlternate ? 0 : distance)
        }
        .clipped()
    }
}

// MARK: - Label Badge

/// The FASTEST / CHEAPEST badge: solid fill, white text, shared by the card's compact bar
/// and its expanded section. `.balanced` has no badge.
struct LabelBadge: View {
    let label: RouteOption.Label
    var isCompact: Bool = false

    var body: some View {
        if let (text, fill) = content {
            Text(text)
                .font(isCompact ? .caption2.weight(.heavy) : .subheadline.weight(.heavy))
                .kerning(0.5)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, isCompact ? 7 : 12)
                .padding(.vertical, isCompact ? 3 : 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
                // Fixed, not scalable. A `minimumScaleFactor` compresses the badge by different
                // amounts on each side of the morph, so it visibly changes size.
                .fixedSize()
        }
    }

    private var content: (String, Color)? {
        switch label {
        case .fastest:  return ("FASTEST", DesignTokens.Colors.fastest)
        case .cheapest: return ("CHEAPEST", DesignTokens.Colors.cheapest)
        case .balanced: return nil
        }
    }
}

// MARK: - Justified Label

/// A `UILabel` bridge for `.textAlignment = .justified`, the one alignment SwiftUI's `Text`
/// cannot produce. Justification stretches only the lines a paragraph wraps to, so a last
/// line or a string that never wraps renders left-aligned.
struct JustifiedLabel: UIViewRepresentable {
    let text: String
    let textStyle: UIFont.TextStyle
    let weight: UIFont.Weight
    /// 0 means unlimited, matching `UILabel.numberOfLines`.
    let lineLimit: Int

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.textAlignment = .justified
        label.lineBreakMode = .byWordWrapping
        label.adjustsFontForContentSizeCategory = true
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        // Scaled via UIFontMetrics (not a static point size) so
        // adjustsFontForContentSizeCategory keeps tracking the system Dynamic Type
        // setting after this initial assignment, the same way the preferred-font APIs do.
        let base = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: textStyle).pointSize,
                                      weight: weight)
        label.font = UIFontMetrics(forTextStyle: textStyle).scaledFont(for: base)
        label.text = text
        label.numberOfLines = lineLimit
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.intrinsicContentSize.width
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}

// MARK: - Jelly Effect Modifier

/// Springs the view's container when `trigger` changes. It compresses to `1 - intensity`,
/// then overshoots slightly before settling.
/// Usage: `card.jellyEffect(trigger: isExpanded)`.
struct JellyEffect<T: Equatable>: ViewModifier {
    let trigger: T
    var intensity: CGFloat = 0.04

    @State private var scale: CGFloat = 1.0

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onChange(of: trigger) { _, _ in
                scale = 1.0 - intensity
                withAnimation(.spring(response: 0.38, dampingFraction: 0.28)) {
                    scale = 1.0
                }
            }
    }
}

extension View {
    func jellyEffect(trigger: some Equatable, intensity: CGFloat = 0.04) -> some View {
        modifier(JellyEffect(trigger: trigger, intensity: intensity))
    }
}
