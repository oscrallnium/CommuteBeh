//
//  WalkARScreenChevron.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import SwiftUI

/// A chevron that points to the top of its frame before the rotation.
private struct ChevronShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

private struct ChevronMark: View {
    let angle: Double
    let size: CGFloat

    var body: some View {
        ZStack {
            ChevronShape().stroke(.black.opacity(0.5), style: strokeStyle(width: size * 0.32))
            ChevronShape().stroke(TransportMode.walk.color, style: strokeStyle(width: size * 0.22))
        }
        .frame(width: size, height: size * 0.7)
        .rotationEffect(.radians(angle))
        .animation(.linear(duration: WalkARViewModel.guideInterval), value: angle)
        .frame(width: size * 1.3, height: size * 1.3)
    }

    private func strokeStyle(width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }
}

/// The one screen-space chevron renderer. It draws the centre and the edge placements.
/// It reads the guide itself, so only this view renders again at the guide rate.
struct WalkARScreenChevronLayer: View {
    static let edgeInsets = EdgeInsets(top: 170, leading: 44, bottom: 240, trailing: 44)

    let viewModel: WalkARViewModel

    var body: some View {
        GeometryReader { proxy in
            if let guide = viewModel.screenGuide {
                switch guide.placement {
                case .center:
                    WalkARCenterChevron(guide: guide, secondary: viewModel.hud.warning)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                case .edge:
                    edgeChevron(guide, in: proxy.size)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func edgeChevron(_ guide: WalkARScreenGuide, in size: CGSize) -> some View {
        VStack(spacing: DesignTokens.Space.xxs) {
            ChevronMark(angle: guide.angle, size: 30)
            Text(guide.title)
                .font(DesignTokens.TypeScale.controlLabel)
                .foregroundStyle(.white)
                .padding(.horizontal, DesignTokens.Space.s)
                .padding(.vertical, DesignTokens.Space.xxs)
                .background(.black.opacity(0.65), in: Capsule())
        }
        .position(Self.edgePosition(angle: guide.angle, in: size))
        .animation(.linear(duration: WalkARViewModel.guideInterval), value: guide.angle)
    }

    /// The point where a ray from the screen centre at `angle` meets the inset screen rectangle.
    static func edgePosition(angle: Double, in size: CGSize) -> CGPoint {
        let insets = edgeInsets
        let rect = CGRect(x: insets.leading, y: insets.top,
                          width: size.width - insets.leading - insets.trailing,
                          height: size.height - insets.top - insets.bottom)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let (dx, dy) = (sin(angle), -cos(angle))
        let tx = abs(dx) < 1e-6 ? Double.infinity : ((dx > 0 ? rect.maxX : rect.minX) - center.x) / dx
        let ty = abs(dy) < 1e-6 ? Double.infinity : ((dy > 0 ? rect.maxY : rect.minY) - center.y) / dy
        let t = min(tx, ty)
        return CGPoint(x: center.x + dx * t, y: center.y + dy * t)
    }
}

/// Large chevron with the direction text. It pulses unless Reduce Motion is on.
private struct WalkARCenterChevron: View {
    let guide: WalkARScreenGuide
    let secondary: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsed = false

    var body: some View {
        VStack(spacing: DesignTokens.Space.s) {
            ChevronMark(angle: guide.angle, size: 110)
                .scaleEffect(isPulsed ? 1.06 : 1)
            Text(guide.title)
                .font(DesignTokens.TypeScale.instruction)
                .foregroundStyle(.white)
            if let secondary {
                Text(secondary)
                    .font(DesignTokens.TypeScale.subtitleEmphasis)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .multilineTextAlignment(.center)
        .padding(DesignTokens.Space.l)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
        .padding(.horizontal, DesignTokens.Space.l)
        .onAppear { startPulse() }
    }

    private func startPulse() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { isPulsed = true }
    }
}
