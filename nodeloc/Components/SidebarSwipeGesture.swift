//
//  SidebarSwipeGesture.swift
//  nodeloc
//
//  The swipe that opens (and closes) the drawer sidebar: a UIKit pan whose
//  delegate decides at the start (`SidebarSwipeDecision`) and simply does not
//  begin for a vertical drag, so it never competes mid-gesture. It also stays
//  out of the way of a scroll view that is already moving or refreshing, and
//  of a horizontal scroller that can still scroll the way the finger goes.
//

import SwiftUI
import UIKit

struct SidebarSwipeRecognizer: UIGestureRecognizerRepresentable {
    let direction: SidebarSwipeDecision.Direction
    let isEnabled: Bool
    /// Translation, start point and velocity, on release.
    let onEnded: (CGSize, CGPoint, CGSize) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var direction: SidebarSwipeDecision.Direction = .opening
        var start: CGPoint = .zero

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return false }
            let t = pan.translation(in: view)
            let v = pan.velocity(in: view)
            guard SidebarSwipeDecision.accepts(
                translation: CGSize(width: t.x, height: t.y),
                velocity: CGSize(width: v.x, height: v.y),
                direction: direction
            ) else { return false }
            let location = pan.location(in: view)
            start = CGPoint(x: location.x - t.x, y: location.y - t.y)
            return !scrollerClaims(view.hitTest(start, with: nil))
        }

        /// A scroll view under the finger keeps the touch when it is already
        /// dragging, decelerating or refreshing, or when it scrolls sideways
        /// and still has room the way the finger is going.
        private func scrollerClaims(_ hit: UIView?) -> Bool {
            var view = hit
            while let current = view {
                if let scroll = current as? UIScrollView {
                    if scroll.isDragging || scroll.isDecelerating { return true }
                    if scroll.refreshControl?.isRefreshing == true { return true }
                    let scrollsSideways = scroll.contentSize.width > scroll.bounds.width + 1
                    if scrollsSideways {
                        let minX = -scroll.adjustedContentInset.left
                        let maxX = scroll.contentSize.width - scroll.bounds.width + scroll.adjustedContentInset.right
                        // Rightwards drags reveal what is to the left.
                        if direction == .opening, scroll.contentOffset.x > minX + 0.5 { return true }
                        if direction == .closing, scroll.contentOffset.x < maxX - 0.5 { return true }
                    }
                }
                view = current.superview
            }
            return false
        }

        /// Scroll views wait for this pan to decide, which it does within the
        /// slop; it refuses vertical starts, so their scrolling is untouched.
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }

        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.isEnabled = isEnabled
        // Taps and long presses (text selection) never reach a pan that has
        // not begun; once it has, the content shouldn't act on the touch.
        pan.cancelsTouchesInView = true
        context.coordinator.direction = direction
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
        context.coordinator.direction = direction
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        guard recognizer.state == .ended, let view = recognizer.view else { return }
        let t = recognizer.translation(in: view)
        let v = recognizer.velocity(in: view)
        onEnded(CGSize(width: t.x, height: t.y), context.coordinator.start, CGSize(width: v.x, height: v.y))
    }
}
