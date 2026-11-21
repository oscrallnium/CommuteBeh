//
//  HostedAnnotationView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/3/26.
//

import SwiftUI
import MapKit

// MARK: - Annotation model

/// A map annotation that a `MapAnnotationDescriptor` describes. The coordinate is observable
/// by key, so assigning it moves the view at once with no animation.
final class CommuteAnnotation: NSObject, MKAnnotation {
    private(set) var descriptor: MapAnnotationDescriptor
    @objc dynamic var coordinate: CLLocationCoordinate2D
    @objc dynamic var title: String?

    init(_ descriptor: MapAnnotationDescriptor) {
        self.descriptor = descriptor
        coordinate = descriptor.coordinate
        title = descriptor.title
        super.init()
    }

    /// Takes the new descriptor. Returns true when the hosted view needs to show again.
    func update(_ next: MapAnnotationDescriptor) -> Bool {
        let needsView = next.content != descriptor.content || next.title != descriptor.title
            || next.revealAt != descriptor.revealAt
        if next.coordinate.latitude != coordinate.latitude || next.coordinate.longitude != coordinate.longitude {
            coordinate = next.coordinate
        }
        if next.title != title { title = next.title }
        descriptor = next
        return needsView
    }
}

// MARK: - Content

/// The SwiftUI view of one annotation. The existing route views draw it.
struct AnnotationContentView: View {
    let content: MapAnnotationContent
    let onSelect: (RouteOption.ID) -> Void

    var body: some View {
        switch content {
        case .stopMarker(let routeID, let kind, let name, let isSelected):
            RouteStopMarker(
                marker: RouteChoiceFrame.Marker(
                    id: "", kind: kind, coordinate: CLLocationCoordinate2D(), name: name, title: ""),
                isSelected: isSelected) { onSelect(routeID) }
        case .callout(let routeID, let text, let label, let accessibilityText, let corner,
                      let isSelected, let isShown, let schedule):
            RouteCallout(
                text: text, label: label, accessibilityText: accessibilityText, corner: corner,
                isSelected: isSelected, isShown: isShown, schedule: schedule) { onSelect(routeID) }
        case .destinationPin:
            DestinationPin().shadow(color: .black.opacity(0.3), radius: 2)
        case .transferDot:
            TransferNode()
        case .stepStart:
            StepStartNode()
        case .connectorTip(let bearing):
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 11))
                .foregroundStyle(.black)
                .rotationEffect(.degrees(bearing))
        case .passengerPuck(let speed, let isHidden):
            PassengerPuck(speed: speed).opacity(isHidden ? 0 : 1)
        }
    }
}

// MARK: - View

/// An annotation view that hosts a SwiftUI view. The map takes the taps: the hosted view
/// ignores touches, and a tap selects the annotation. See `Commute-Map.md`.
final class HostedAnnotationView: MKAnnotationView {

    private enum TitleStyle {
        static let gap: CGFloat = 2
        static let haloWidth: CGFloat = -3
    }

    private enum Pop {
        static let hiddenScale: CGFloat = 0.6
        static let duration: TimeInterval = 0.25
        static let bounce: CGFloat = 0.2
    }

    private enum Zoom {
        static let duration: TimeInterval = 0.25
    }

    private var controller: UIHostingController<AnnotationContentView>?
    private var hosted: UIView? { controller?.view }
    private let titleLabel = UILabel()
    private var contentAnchor = CGPoint.zero
    private var contentSize = CGSize.zero
    /// False while the draw-on has not reached the annotation. Content and title are then
    /// scaled down and transparent.
    private(set) var isRevealed = true
    /// Scale of the content about the anchor. The title keeps its size.
    private(set) var zoomScale: CGFloat = 1

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        collisionMode = .none
        displayPriority = .required
        isAccessibilityElement = false
        titleLabel.isUserInteractionEnabled = false
        titleLabel.isHidden = true
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows `view` with its `anchor` point on the annotation coordinate. `title` draws as a
    /// label centered under the content, outside `bounds`, so the anchor refers to the content only.
    func show(_ view: AnnotationContentView, anchor: UnitPoint, title: String?) {
        // The hosting controller ignores every safe-area region, so the measured size does not depend on where the view sits on the screen.
        let contentView: UIView
        if let controller {
            controller.rootView = view
            contentView = controller.view
        } else {
            let controller = UIHostingController(rootView: view)
            controller.safeAreaRegions = []
            controller.sizingOptions = .intrinsicContentSize
            contentView = controller.view
            contentView.isUserInteractionEnabled = false
            contentView.backgroundColor = .clear
            addSubview(contentView)
            self.controller = controller
            accessibilityElements = [contentView]
        }
        contentView.transform = .identity
        titleLabel.transform = .identity
        contentView.layoutIfNeeded()
        let size = contentView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        contentSize = size
        contentAnchor = CGPoint(x: anchor.x * size.width, y: anchor.y * size.height)
        contentView.frame = CGRect(origin: .zero, size: size)
        bounds = contentView.bounds
        centerOffset = CGPoint(x: (0.5 - anchor.x) * size.width, y: (0.5 - anchor.y) * size.height)
        showTitle(title, belowContentOfSize: size)
        applyRevealState()
    }

    /// Hides or shows the content. Showing pops it in with a spring when `animated` is true.
    func setRevealed(_ revealed: Bool, animated: Bool) {
        guard revealed != isRevealed else { return }
        isRevealed = revealed
        guard animated, revealed else {
            applyRevealState()
            return
        }
        UIView.animate(springDuration: Pop.duration, bounce: Pop.bounce) { self.applyRevealState() }
    }

    /// Scales the content about the anchor point with no new hosting pass. Animates when `animated` is true.
    func setZoomScale(_ scale: CGFloat, animated: Bool) {
        guard scale != zoomScale else { return }
        zoomScale = scale
        guard animated else {
            applyRevealState()
            return
        }
        UIView.animate(withDuration: Zoom.duration, delay: 0, options: .curveEaseInOut) { self.applyRevealState() }
    }

    /// Scales content and title about the anchor point, so the anchor stays on its map point.
    private func applyRevealState() {
        let revealScale = isRevealed ? 1 : Pop.hiddenScale
        for subview in [hosted, titleLabel] as [UIView?] {
            guard let subview else { continue }
            let scale = subview === hosted ? revealScale * zoomScale : revealScale
            subview.alpha = isRevealed ? 1 : 0
            subview.transform = CGAffineTransform(
                a: scale, b: 0, c: 0, d: scale,
                tx: (1 - scale) * (contentAnchor.x - subview.center.x),
                ty: (1 - scale) * (contentAnchor.y - subview.center.y))
        }
    }

    private func showTitle(_ title: String?, belowContentOfSize size: CGSize) {
        guard let title, !title.isEmpty else {
            titleLabel.isHidden = true
            return
        }
        let font = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .semibold)
        titleLabel.attributedText = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: UIColor.label,
            .strokeColor: UIColor.systemBackground,
            .strokeWidth: TitleStyle.haloWidth
        ])
        titleLabel.sizeToFit()
        titleLabel.center = CGPoint(x: size.width / 2, y: size.height + TitleStyle.gap + titleLabel.bounds.height / 2)
        titleLabel.isHidden = false
    }
}

#if DEBUG
extension HostedAnnotationView {
    /// Content size that `show` measured.
    var debugMeasuredSize: CGSize { contentSize }

    /// Frame of the hosted content view, including any transform.
    var debugContentFrame: CGRect? { hosted?.frame }

    /// Size the hosted content reports now. Measuring reads layout only and leaves the transform and frame alone.
    var debugFittingSize: CGSize? { hosted?.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize) }
}
#endif
