//
//  KnotLoadingView.swift
//  nodeloc
//
//  The knot logo as a loading animation, drawn natively: a faint track of the
//  whole knot, a runner dash travelling round it once every 1.8 s, and the
//  four orange nodes pulsing in turn as the runner passes. Over and under are
//  kept: where a strand passes under another it is cut away, the runner
//  included, and each node sits in a small clearing.
//
//  Geometry is in a 100 × 100 box. The launch screen's still image
//  (`LaunchKnot`) is this view's track look at rest, so the hand-over from the
//  system launch screen to the animation doesn't jump.
//

import SwiftUI

struct KnotLoadingView: View {
    var size: CGFloat = 96

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The moment the runner starts, so every frame is timed from one clock.
    @State private var start = Date()

    var body: some View {
        // `TimelineView` only ticks while the view is on screen, and not at
        // all with Reduce Motion, where the logo stands still.
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            Canvas { context, canvasSize in
                let time = timeline.date.timeIntervalSince(start)
                KnotDrawing.draw(
                    in: &context,
                    size: canvasSize,
                    time: reduceMotion ? nil : time,
                    green: colorScheme == .dark ? KnotDrawing.darkGreen : KnotDrawing.lightGreen
                )
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(AppString("加载中"))
    }
}

enum KnotDrawing {
    static let lightGreen = Color(red: 0x02 / 255, green: 0x9A / 255, blue: 0x68 / 255)
    static let darkGreen = Color(red: 0x5C / 255, green: 0xC7 / 255, blue: 0x9A / 255)
    static let nodeOrange = Color(red: 0xFF / 255, green: 0x9C / 255, blue: 0x38 / 255)

    static let period: Double = 1.8
    static let lineWidth: CGFloat = 5.5
    static let cutWidth: CGFloat = 10.5
    static let clearingRadius: CGFloat = 7.5
    static let nodeRadius: CGFloat = 6
    static let trackOpacity: Double = 0.22
    static let runnerFraction: CGFloat = 0.26

    /// Node centres with the moment (seconds into the runner's loop) each
    /// one's pulse begins: bottom, left, top, right.
    static let nodes: [(center: CGPoint, pulseStart: Double)] = [
        (CGPoint(x: 50, y: 87), 0.05),
        (CGPoint(x: 13, y: 50), 0.50),
        (CGPoint(x: 50, y: 13), 0.95),
        (CGPoint(x: 87, y: 50), 1.40),
    ]

    /// First quarter, right node to bottom node.
    private static let quarter: [CGPoint] = [
        (87.0, 50.0), (87.0, 48.9), (86.8, 47.7), (86.6, 46.7), (86.3, 45.6), (85.9, 44.6),
        (85.4, 43.7), (84.8, 42.8), (84.2, 42.0), (83.4, 41.3), (82.6, 40.7), (81.7, 40.2),
        (80.7, 39.9), (79.6, 39.6), (78.4, 39.5), (77.2, 39.5), (75.9, 39.7), (74.6, 39.9),
        (73.1, 40.4), (71.7, 40.9), (70.1, 41.5), (68.6, 42.3), (67.0, 43.2), (65.3, 44.2),
        (63.7, 45.3), (62.0, 46.5), (60.3, 47.8), (58.6, 49.2), (57.0, 50.7), (55.3, 52.2),
        (53.7, 53.7), (52.2, 55.3), (50.7, 57.0), (49.2, 58.6), (47.8, 60.3), (46.5, 62.0),
        (45.3, 63.7), (44.2, 65.3), (43.2, 67.0), (42.3, 68.6), (41.5, 70.1), (40.9, 71.7),
        (40.4, 73.1), (39.9, 74.6), (39.7, 75.9), (39.5, 77.2), (39.5, 78.4), (39.6, 79.6),
        (39.9, 80.7), (40.2, 81.7), (40.7, 82.6), (41.3, 83.4), (42.0, 84.2), (42.8, 84.8),
        (43.7, 85.4), (44.6, 85.9), (45.6, 86.3), (46.7, 86.6), (47.7, 86.8), (48.9, 87.0),
        (50.0, 87.0),
    ].map { CGPoint(x: $0.0, y: $0.1) }

    /// The over strand of the first quarter (indices 23…32 between its two
    /// ends), and the band cut out beneath it, which runs a little further.
    private static let overStart = CGPoint(x: 66.6, y: 43.4)
    private static let overEnd = CGPoint(x: 50.24, y: 57.14)
    private static let cutEnd = CGPoint(x: 49.8, y: 58.0)
    private static let overInterior = Array(quarter[23...32])

    /// (x, y) → (100 − y, x): a quarter turn.
    private static func rotate(_ p: CGPoint, times: Int) -> CGPoint {
        var p = p
        for _ in 0..<times { p = CGPoint(x: 100 - p.y, y: p.x) }
        return p
    }

    /// The whole closed knot, in the listed order.
    static let points: [CGPoint] = (0..<4).flatMap { turn in
        quarter.dropLast().map { rotate($0, times: turn) }
    }

    private static let overStrands: [[CGPoint]] = (0..<4).map { turn in
        ([overStart] + overInterior + [overEnd]).map { rotate($0, times: turn) }
    }

    private static let cutBands: [[CGPoint]] = (0..<4).map { turn in
        ([overStart] + overInterior + [cutEnd]).map { rotate($0, times: turn) }
    }

    /// Arc length along the knot to each over strand's start, so the runner's
    /// dash lines up on the strand drawn over the cut.
    private static let overStartLengths: [CGFloat] = (0..<4).map { turn in
        let quarterLength = length(of: quarter)
        // Up to index 22, then on to the strand's start.
        let lead = length(of: Array(quarter[0...22])) + distance(quarter[22], overStart)
        return CGFloat(turn) * quarterLength + lead
    }

    static let totalLength: CGFloat = length(of: points + [points[0]])

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func length(of polyline: [CGPoint]) -> CGFloat {
        zip(polyline, polyline.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    private static func path(_ polyline: [CGPoint], closed: Bool, scale: CGFloat) -> Path {
        var path = Path()
        guard let first = polyline.first else { return path }
        path.move(to: CGPoint(x: first.x * scale, y: first.y * scale))
        for point in polyline.dropFirst() {
            path.addLine(to: CGPoint(x: point.x * scale, y: point.y * scale))
        }
        if closed { path.closeSubpath() }
        return path
    }

    /// One frame. `time` nil draws a still: with `solid`, the logo at full
    /// strength (Reduce Motion); without, the animation's resting look — the
    /// faint track and the nodes at rest — which is the launch screen image.
    static func draw(in context: inout GraphicsContext, size: CGSize, time: Double?, green: Color, solid: Bool = true) {
        let scale = min(size.width, size.height) / 100
        let knot = path(points, closed: true, scale: scale)
        let overs = overStrands.map { path($0, closed: false, scale: scale) }
        let bands = cutBands.map { path($0, closed: false, scale: scale) }
        let line = StrokeStyle(lineWidth: lineWidth * scale, lineCap: .round, lineJoin: .round)
        let cut = StrokeStyle(lineWidth: cutWidth * scale, lineCap: .round, lineJoin: .round)

        /// Draws `under` everywhere, cuts the bands and the node clearings out
        /// of it, then draws `over` on top of each band.
        func woven(opacity: Double, under: (inout GraphicsContext) -> Void, over: (inout GraphicsContext, Int) -> Void) {
            // The opacity applies to the finished layer, so the over strands
            // and what is left of the strands below come out the same.
            var composite = context
            composite.opacity = opacity
            composite.drawLayer { layer in
                under(&layer)
                layer.blendMode = .destinationOut
                for band in bands { layer.stroke(band, with: .color(.black), style: cut) }
                layer.blendMode = .normal
                for index in overs.indices { over(&layer, index) }
                layer.blendMode = .destinationOut
                for node in nodes {
                    let r = clearingRadius * scale
                    let c = CGPoint(x: node.center.x * scale, y: node.center.y * scale)
                    layer.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.black))
                }
            }
        }

        // Track.
        woven(opacity: time == nil && solid ? 1 : trackOpacity) { layer in
            layer.stroke(knot, with: .color(green), style: line)
        } over: { layer, index in
            layer.stroke(overs[index], with: .color(green), style: line)
        }

        // Runner: 26 % dash, 74 % gap, once round per period, forwards.
        if let time {
            let total = totalLength * scale
            let dash = total * runnerFraction
            let progress = CGFloat(time.truncatingRemainder(dividingBy: period) / period)
            let phase = -progress * total
            woven(opacity: 1) { layer in
                layer.stroke(knot, with: .color(green), style: StrokeStyle(
                    lineWidth: lineWidth * scale, lineCap: .round, lineJoin: .round,
                    dash: [dash, total - dash], dashPhase: phase
                ))
            } over: { layer, index in
                layer.stroke(overs[index], with: .color(green), style: StrokeStyle(
                    lineWidth: lineWidth * scale, lineCap: .round, lineJoin: .round,
                    dash: [dash, total - dash], dashPhase: phase + overStartLengths[index] * scale
                ))
            }
        }

        // Nodes.
        for node in nodes {
            var nodeScale: CGFloat = 1
            var opacity: Double = time == nil && solid ? 1 : 0.7
            if let time {
                var local = (time - node.pulseStart).truncatingRemainder(dividingBy: period)
                if local < 0 { local += period }
                let u = local / period
                if u < 0.3 {
                    let t = u / 0.3
                    let eased = 1 - (1 - t) * (1 - t) * (1 - t)   // ease-out
                    nodeScale = 1.35 - 0.35 * eased
                    opacity = 1 - 0.3 * eased
                } else {
                    opacity = 0.7
                }
            }
            let r = nodeRadius * scale * nodeScale
            let c = CGPoint(x: node.center.x * scale, y: node.center.y * scale)
            context.fill(
                Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                with: .color(nodeOrange.opacity(opacity))
            )
        }
    }
}

#Preview("Knot") {
    KnotLoadingView(size: 120)
}
