//
//  SavedPlacesPanInstaller.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import SwiftUI
import UIKit

/// Adds one vertical-pan recognizer to the `UIScrollView` that encloses this view. Place it in
/// the scroll content. The recognizer begins only for a mostly vertical start on a chip, so a
/// horizontal pan reaches the scroll view. Locations use the window space, which equals SwiftUI's
/// global space.
struct SavedPlacesPanInstaller: UIViewRepresentable {
    /// Returns the chip under a window-space point, or nil.
    let chipID: (CGPoint) -> SavedPlace.ID?
    let onBegan: (SavedPlace.ID, CGPoint) -> Void
    let onChanged: (CGPoint) -> Void
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: InstallerView, context: Context) {
        context.coordinator.parent = self
    }

    final class InstallerView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            var ancestor = superview
            while let current = ancestor, !(current is UIScrollView) { ancestor = current.superview }
            if let scrollView = ancestor as? UIScrollView { coordinator?.attach(to: scrollView) }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SavedPlacesPanInstaller
        private let pan = UIPanGestureRecognizer()
        private var touchDown: CGPoint = .zero

        init(_ parent: SavedPlacesPanInstaller) {
            self.parent = parent
            super.init()
            pan.delegate = self
            pan.addTarget(self, action: #selector(handle))
        }

        func attach(to scrollView: UIScrollView) {
            guard pan.view !== scrollView else { return }
            pan.view?.removeGestureRecognizer(pan)
            scrollView.addGestureRecognizer(pan)
        }

        @objc private func handle(_ recognizer: UIPanGestureRecognizer) {
            let location = recognizer.location(in: nil)
            switch recognizer.state {
            case .began:
                if let id = parent.chipID(touchDown) { parent.onBegan(id, location) }
            case .changed:
                parent.onChanged(location)
            case .ended, .cancelled, .failed:
                parent.onEnded()
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            touchDown = touch.location(in: nil)
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.y) > abs(velocity.x) && parent.chipID(touchDown) != nil
        }

        /// The scroll view's own pan waits for this pan to fail. A horizontal start fails it at once.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other === pan.view.flatMap { ($0 as? UIScrollView)?.panGestureRecognizer }
        }
    }
}
