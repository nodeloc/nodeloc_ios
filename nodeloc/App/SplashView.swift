//
//  SplashView.swift
//  nodeloc
//
//  The launch animation: the nodeloc wordmark writing itself, stroke by
//  stroke, in the order you'd draw it by hand (n·o·d·e·l·o·c).
//
//  The visible mark is the canonical wordmark artwork. The vector path below is
//  only a reveal mask, so the finished frame matches the logo asset exactly
//  instead of redrawing the letters from approximate centre-lines.
//
//  The static launch screen (Info.plist UILaunchScreen) is background-only so
//  it hands over to this without the mark popping in fully drawn first.
//

import SwiftUI

struct SplashView: View {
    /// Called once the animation has finished and faded out.
    let onFinished: () -> Void

    @State private var penProgress: CGFloat = 0
    @State private var isFadingOut = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let wordmarkWidth: CGFloat = 210

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            RevealedWordmark(progress: penProgress, width: wordmarkWidth)
                .accessibilityLabel("NodeLoc")
        }
        .opacity(isFadingOut ? 0 : 1)
        .task { await run() }
    }

    private func run() async {
        if reduceMotion {
            penProgress = 1
            try? await Task.sleep(for: .milliseconds(450))
        } else {
            withAnimation(.easeInOut(duration: 1.05)) { penProgress = 1 }
            // Hold on the finished mark for a beat before handing over.
            try? await Task.sleep(for: .milliseconds(1_250))
        }
        withAnimation(.easeOut(duration: 0.32)) { isFadingOut = true }
        try? await Task.sleep(for: .milliseconds(320))
        onFinished()
    }
}

private struct RevealedWordmark: View {
    let progress: CGFloat
    let width: CGFloat

    private let aspect: CGFloat = 960.0 / 280.0
    private var height: CGFloat { width / aspect }
    private var scale: CGFloat { width / 252 }

    var body: some View {
        Image("NodelocWordmark")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: width, height: height)
            .mask {
                WordmarkRevealPath()
                    .trim(from: 0, to: progress)
                    .stroke(
                        style: StrokeStyle(
                            // Wider than the pen path so the mask reveals the
                            // real anti-aliased wordmark edges as it moves.
                            lineWidth: 15 * scale,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .frame(width: width, height: height)
            }
    }
}

/// Pen paths for the reveal mask, in the original 252 × 73 wordmark grid.
///
/// These coordinates describe how the virtual pen travels; the visible shape
/// still comes from the artwork asset above.
private struct WordmarkRevealPath: Shape {
    // Letter centre-lines, measured from the asset.
    private let baseline: CGFloat = 57      // 61 − 4
    private let xHeightTop: CGFloat = 32    // 28 + 4
    private let ascender: CGFloat = 15      // 11 + 4
    private let midline: CGFloat = 44.5
    private let ringRadius: CGFloat = 12.5

    func path(in rect: CGRect) -> Path {
        let scale = rect.width / 252
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }

        var path = Path()

        // n — up the stem, over the arch, down the right leg.
        path.move(to: point(8, baseline))
        path.addLine(to: point(8, 41))
        path.addCurve(
            to: point(33, 41),
            control1: point(8, xHeightTop - 1),
            control2: point(33, xHeightTop - 1)
        )
        path.addLine(to: point(33, baseline))

        // o
        addRing(&path, center: point(60, midline), radius: ringRadius * scale)

        // d — bowl first, then the ascender down its right side.
        addRing(&path, center: point(99.5, midline), radius: ringRadius * scale)
        path.move(to: point(112, ascender))
        path.addLine(to: point(112, baseline))

        // e — the bar, then round from its right end over the top, down the
        // left and back out to the lower-right opening.
        path.move(to: point(126.5, midline))
        path.addLine(to: point(151, midline))
        path.addArc(
            center: point(138.5, midline),
            radius: ringRadius * scale,
            startAngle: .degrees(0),
            endAngle: .degrees(-295),
            clockwise: true
        )

        // l
        path.move(to: point(164.5, ascender))
        path.addLine(to: point(164.5, baseline))

        // o
        addRing(&path, center: point(191, midline), radius: ringRadius * scale)

        // c — open to the right.
        let cCenter = point(229, midline)
        let cRadius = 11.5 * scale
        path.move(to: pointOnCircle(center: cCenter, radius: cRadius, degrees: -55))
        path.addArc(
            center: cCenter,
            radius: cRadius,
            startAngle: .degrees(-55),
            endAngle: .degrees(-305),
            clockwise: true
        )

        return path
    }

    /// A closed ring drawn from the top, the way a pen circles a bowl.
    private func addRing(_ path: inout Path, center: CGPoint, radius: CGFloat) {
        path.move(to: CGPoint(x: center.x, y: center.y - radius))
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(270),
            clockwise: false
        )
    }

    private func pointOnCircle(center: CGPoint, radius: CGFloat, degrees: CGFloat) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(
            x: center.x + cos(radians) * radius,
            y: center.y + sin(radians) * radius
        )
    }
}

#Preview("Splash") {
    SplashView(onFinished: {})
}
