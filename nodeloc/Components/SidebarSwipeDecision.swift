//
//  SidebarSwipeDecision.swift
//  nodeloc
//
//  Which way a drag is going, decided once at its start. The sidebar's pan
//  asks this when it is about to begin (after UIKit's ~10 pt of slop) and
//  never again, so a drag that starts as a scroll stays a scroll however the
//  finger moves afterwards. Plain Foundation, so it can be checked on its own.
//

import CoreGraphics

enum SidebarSwipeDecision {
    enum Direction { case opening, closing }

    /// Horizontal at least this many times vertical: within about 30° of
    /// level (tan 30° ≈ 0.58, 1 / 0.58 ≈ 1.73).
    static let dominance: CGFloat = 1.73
    /// Below this much travel the velocity says more than the translation.
    static let minimumTravel: CGFloat = 4

    /// True when the drag starts sideways, the right way: rightwards to open
    /// the sidebar, leftwards to close it.
    static func accepts(translation: CGSize, velocity: CGSize, direction: Direction) -> Bool {
        let travel = abs(translation.width) + abs(translation.height)
        let sample = travel >= minimumTravel ? translation : velocity
        let along = direction == .opening ? sample.width : -sample.width
        guard along > 0 else { return false }
        guard along >= abs(sample.height) * dominance else { return false }
        // The speed must agree where there is any: a vertical flick that
        // drifted sideways for the first few points still reads as vertical.
        let speed = abs(velocity.width) + abs(velocity.height)
        if speed > 50 {
            let speedAlong = direction == .opening ? velocity.width : -velocity.width
            return speedAlong > 0 && speedAlong >= abs(velocity.height) * dominance
        }
        return true
    }
}
