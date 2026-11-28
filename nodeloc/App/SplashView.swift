//
//  SplashView.swift
//  nodeloc
//
//  The launch animation: the knot logo's loading loop (`KnotLoadingView`),
//  centred on the page background, for the same short beat the app has
//  always held at launch while it restores the session and loads behind it.
//
//  The static launch screen (Info.plist UILaunchScreen) shows `LaunchKnot`,
//  this view's track look at rest, at the same size in the same place, so the
//  hand-over is the runner starting rather than the logo appearing.
//

import SwiftUI

struct SplashView: View {
    /// Called once the animation has finished and faded out.
    let onFinished: () -> Void

    @State private var isFadingOut = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The launch image's size in points; the two must match.
    static let knotSize: CGFloat = 96

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            KnotLoadingView(size: Self.knotSize)
                .accessibilityLabel("NodeLoc")
        }
        .opacity(isFadingOut ? 0 : 1)
        .task { await run() }
    }

    private func run() async {
        // The same hold as before: 2.3 s, or 0.45 s with Reduce Motion.
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 450 : 2_300))
        withAnimation(.easeOut(duration: 0.32)) { isFadingOut = true }
        try? await Task.sleep(for: .milliseconds(320))
        onFinished()
    }
}

#Preview("Splash") {
    SplashView(onFinished: {})
}
