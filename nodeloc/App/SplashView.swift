//
//  SplashView.swift
//  nodeloc
//
//  The launch animation: the NODELOC wordmark writing itself, stroke by
//  stroke, in the order you'd draw it by hand (n·o·d·e·l·o·c).
//
//  It writes the *real* brand artwork rather than a hand-traced imitation:
//  `WordmarkStrokes` is a skeleton following each letter's pen path, stroked
//  thick enough to cover the glyphs and animated with `trim`, then used as a
//  mask over `NodelocWordmark`. So the shapes are always exactly the brand's,
//  and only their reveal is animated.
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

    /// The wordmark asset's own pixel aspect (252 × 73).
    private let wordmarkAspect: CGFloat = 252.0 / 73.0
    private let wordmarkWidth: CGFloat = 210

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            Image("NodelocWordmark")
                .resizable()
                .scaledToFit()
                .frame(width: wordmarkWidth, height: wordmarkWidth / wordmarkAspect)
                .mask {
                    WordmarkStrokes()
                        .trim(from: 0, to: penProgress)
                        .stroke(
                            style: StrokeStyle(
                                // The glyphs are 8 units thick in the
                                // skeleton's 252-wide space; 15 covers them
                                // with margin so no edge is left behind.
                                lineWidth: 15 * (wordmarkWidth / 252),
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                        .frame(width: wordmarkWidth, height: wordmarkWidth / wordmarkAspect)
                }
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

/// Pen paths for "nodeloc", in the wordmark asset's own 252 × 73 space.
///
/// Every coordinate is measured from the artwork: x-height runs y 28…61,
/// ascenders start at y 11, and the strokes are 8 units thick — so letter
/// centre-lines sit 4 units inside each glyph's bounding box.
private struct WordmarkStrokes: Shape {
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
        path.addArc(
            center: point(229, midline),
            radius: 11.5 * scale,
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
}

#Preview("Splash") {
    SplashView(onFinished: {})
}
