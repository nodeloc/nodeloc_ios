//
//  GlassCompat.swift
//  nodeloc
//
//  Liquid Glass, with a floor under it.
//
//  The app's chrome — floating headers, node pills, the compose bar, the
//  search field — is drawn with `.glassEffect` and `.buttonStyle(.glass)`.
//  Both are iOS 26, and the deployment target is 18, so every one of those
//  calls comes through here: glass where the system has it, a material shape
//  of the same geometry where it doesn't.
//
//  Two rules for anything added to this file:
//
//  - the iOS 26 branch says exactly what the call site used to say, so almost
//    every user keeps the appearance that shipped;
//  - the fallback carries the *tint* the call site asked for. Those tints are
//    the app's own (`Theme.bg.opacity(0.34)` and friends) and they are what
//    keeps a header legible over a scrolling feed. Dropping them would leave
//    grey chrome on grey content.
//
//  On the choice of material: glass is more translucent than anything the
//  older system can draw, and it stays readable because of specular edges
//  that come with it. Imitating the translucency with `.ultraThinMaterial`
//  and nothing else gets the look closer and the legibility worse, so the
//  fallback uses `.regularMaterial` plus a hairline where the specular edge
//  would have been. Contrast first.
//

import SwiftUI
import UIKit

/// The only two shapes the app ever draws glass in.
///
/// This exists because the fallback has to *draw* the shape, and
/// `ButtonBorderShape` can't be read back or converted into one.
enum GlassShape {
    case circle
    case capsule
    /// A panel: the floating sidebar.
    case rounded(CGFloat)

    var shape: AnyShape {
        switch self {
        case .circle: AnyShape(Circle())
        case .capsule: AnyShape(Capsule())
        case .rounded(let radius): AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    var borderShape: ButtonBorderShape {
        switch self {
        case .circle: .circle
        case .capsule: .capsule
        case .rounded(let radius): .roundedRectangle(radius: radius)
        }
    }
}

/// Builds the `Glass` value the modifiers used to spell out inline.
///
/// A free function so the `Glass` type — which doesn't exist before 26 — is
/// only ever named inside something the compiler can gate.
@available(iOS 26.0, *)
private func liquidGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}

extension View {
    /// `.buttonStyle(.glass(…))` together with its `.buttonBorderShape(…)`.
    ///
    /// The shape is a parameter rather than a separate modifier because the
    /// fallback needs to know it, and one call is harder to get half-right
    /// than two.
    @ViewBuilder
    func glassButton(tint: Color? = nil, shape: GlassShape = .capsule) -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass(liquidGlass(tint: tint, interactive: false)))
                .buttonBorderShape(shape.borderShape)
        } else {
            buttonStyle(LegacyGlassButtonStyle(tint: tint, shape: shape))
        }
    }

    /// `.glassEffect(…, in:)`.
    ///
    /// `interactive` is the glass's own press response. There is nothing to
    /// imitate it with before 26 — the effect reacts to touches the view
    /// hierarchy never hears about — so the fallback simply doesn't, and the
    /// button variants above keep their `.pressable` style for that.
    @ViewBuilder
    func glassSurface(
        tint: Color? = nil,
        interactive: Bool = false,
        in shape: GlassShape = .capsule
    ) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(liquidGlass(tint: tint, interactive: interactive), in: shape.shape)
        } else {
            background(LegacyGlass(tint: tint, shape: shape))
        }
    }

    /// `.tabBarMinimizeBehavior(.onScrollDown)`.
    ///
    /// The tab bar simply stays put before 26. Nothing else in the app depends
    /// on it having collapsed.
    @ViewBuilder
    func tabBarMinimizesOnScrollDown() -> some View {
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    /// Reports this scroll view's direction to `TabBarScrollState`, so the tab
    /// bar expands as soon as the reader scrolls back up, not only at the top.
    /// Put it on each tab's main scroll view.
    /// `.safeAreaBar(edge: .top)` on 26 — content the scroll-edge effect
    /// treats as part of the bar, so it isn't blurred — and the plain inset
    /// before, where there is no such effect.
    @ViewBuilder
    func topSafeAreaBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .top, spacing: 0, content: bar)
        } else {
            safeAreaInset(edge: .top, spacing: 0, content: bar)
        }
    }

    func tabBarFollowsScrollDirection() -> some View {
        modifier(TabBarScrollDirection())
    }

    /// `.tabViewSearchActivation(.searchTabSelection)`.
    ///
    /// Before 26 the search tab doesn't morph the tab bar into a field; it
    /// behaves as an ordinary tab. That is survivable here only because
    /// `SearchView` already draws its own field and scope bar in both modes —
    /// see the note next to `.searchable` in `MainView`.
    @ViewBuilder
    func searchActivatesOnTabSelection() -> some View {
        if #available(iOS 26.0, *) {
            tabViewSearchActivation(.searchTabSelection)
        } else {
            self
        }
    }
}

/// `GlassEffectContainer`, which lets nearby glass shapes merge as they move.
///
/// Nothing merges before 26, so the fallback is the content, untouched.
struct GlassContainer<Content: View>: View {
    var spacing: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// What glass degrades to: a material fill in the same shape, the call site's
/// tint over it, and a hairline standing in for the specular edge.
private struct LegacyGlass: View {
    let tint: Color?
    let shape: GlassShape

    var body: some View {
        let outline = shape.shape

        ZStack {
            outline.fill(.regularMaterial)
            if let tint {
                outline.fill(tint)
            }
        }
        // `.stroke`, not `.strokeBorder`: `AnyShape` isn't insettable.
        .overlay {
            outline.stroke(Theme.divider.opacity(0.7), lineWidth: 0.5)
        }
    }
}

/// The pre-26 stand-in for `.buttonStyle(.glass)`.
private struct LegacyGlassButtonStyle: ButtonStyle {
    let tint: Color?
    let shape: GlassShape

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // `.glass` insets its label by 7pt, which is how the app's 34pt
            // labels become 48pt controls. Two call sites already reproduce
            // that number by hand to line a plain capsule up with a glass
            // button (`ProfileView`, `NodeDetailOverlay`) — matching it here
            // keeps every header the same height on both systems.
            .padding(7)
            .background(LegacyGlass(tint: tint, shape: shape))
            .contentShape(shape.shape)
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

// MARK: - Navigation bar

extension View {
    /// `.scrollEdgeEffectStyle(.soft, for: .top)`: content passing under the
    /// navigation bar fades out softly instead of under a hard material edge.
    ///
    /// Before 26 the bar keeps the system's own scroll-edge appearance.
    @ViewBuilder
    func softTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}


// MARK: - Tab bar scroll direction

/// Whether the tab bar may minimize right now.
///
/// `.tabBarMinimizeBehavior(.onScrollDown)` alone only re-expanded the bar
/// once the list was back at the very top. There's no call to expand it, so
/// scrolling back up briefly switches the behaviour to `.never`, which
/// expands the bar at once, then restores `.onScrollDown`.
@MainActor
@Observable
final class TabBarScrollState {
    static let shared = TabBarScrollState()
    private(set) var allowsMinimize = true
    private var restoreTask: Task<Void, Never>?

    /// Expands the bar: `.never` for a moment, then back to `.onScrollDown`.
    /// Restoring right away matters — the system only starts tracking a
    /// minimize again on a fresh drag, so leaving `.never` in place until the
    /// reader scrolled down meant that whole first swipe didn't collapse it.
    ///
    /// Done on the UIKit tab bar controller rather than through SwiftUI's
    /// `.tabBarMinimizeBehavior`: a SwiftUI change to that value snapped the
    /// bar open in one frame (recorded at 30 fps), and `withAnimation` around
    /// it made no difference. Setting the controller's property inside a
    /// UIKit spring animation lets the bar grow back the way it shrank.
    /// Whether the bar has probably minimized: set after a downward run long
    /// enough for the system to have collapsed it, cleared on expand or at
    /// the top. Without it the grow replayed on an already-open bar — one
    /// upward swipe produced several upward runs, and each squeezed the bar
    /// and grew it again.
    /// Not observed: nothing renders from it, and it's written from scroll
    /// handlers on every frame.
    @ObservationIgnored private(set) var likelyMinimized = false

    func noteScrolledDown() {
        if !likelyMinimized { likelyMinimized = true }
        if !chromeCollapsed { chromeCollapsed = true }
    }
    func noteAtTop() {
        if likelyMinimized { likelyMinimized = false }
        if chromeCollapsed { chromeCollapsed = false }
    }

    /// The bar's state as the scroll rules decide it — collapsed after a
    /// downward run, open again on a fast pull back, a fast fling, or the
    /// top — for chrome that should move with the bottom bar (首页's tab
    /// strip). Observed, and written only when it flips.
    private(set) var chromeCollapsed = false

    /// Whether the bar really is minimized right now, read off the tab bar
    /// itself: when collapsed the system hides the tab capsule (the subview
    /// much wider than tall) and shows a small button in its place — measured
    /// on iOS 26: [48 visible, 62, 290 hidden] collapsed, [48 hidden, 62, 290]
    /// open. A remembered flag went stale across tab switches and played the
    /// grow on a bar that was already open.
    /// Whether there is a UIKit tab bar to read at all (not on iPad's top bar).
    static var hasTabBar: Bool { tabBarController() != nil }

    static func isActuallyMinimized() -> Bool {
        guard let bar = tabBarController()?.tabBar, bar.bounds.width > 0 else { return false }
        // By what is on screen, not by which piece is flagged hidden: the
        // open bar's tab capsule spans most of the bar; minimised, only the
        // small buttons remain. A hidden-flag test can read "minimised" on a
        // layout where some other wide piece is hidden while the bar is open.
        let visible = bar.subviews.filter { !$0.isHidden && $0.alpha > 0.05 && $0.bounds.width > 0 }
        guard let widest = visible.map(\.bounds.width).max() else { return false }
        return widest < bar.bounds.width * 0.5
    }

    func expand() {
        if chromeCollapsed { chromeCollapsed = false }
        guard restoreTask == nil, Self.isActuallyMinimized() else {
            likelyMinimized = false
            return
        }
        likelyMinimized = false
        guard #available(iOS 26.0, *), let controller = Self.tabBarController() else { return }
        allowsMinimize = false
        // The system never animates this change (a spring or a cross-fade
        // around it still opens the bar in one frame, recorded at 30 fps),
        // and it offers no expand call. So: switch without animation, then
        // grow the real bar out of the collapsed button — start it squeezed
        // to the button's width against the leading edge and spring it open,
        // mirroring the native collapse.
        // Where each piece sits while collapsed, to grow it from there.
        let bar = controller.tabBar
        let collapsedFrames = Dictionary(
            bar.subviews.map { (ObjectIdentifier($0), $0.frame) },
            uniquingKeysWith: { first, _ in first }
        )
        UIView.performWithoutAnimation {
            controller.tabBarMinimizeBehavior = .never
            controller.view.layoutIfNeeded()
        }
        // The tab capsule grows out of the collapsed button against the
        // leading edge (picked by shape — much wider than tall — not by
        // UIKit's private class names). The separate search button is
        // grown uniformly from its collapsed frame, in step with it, so it
        // neither blinks nor jumps size.
        var animated: [(view: UIView, fades: Bool)] = []
        for piece in bar.subviews where piece.bounds.width > 0 {
            let expanded = piece.frame
            let isCapsule = piece.bounds.width > piece.bounds.height * 2
            if isCapsule {
                let width = expanded.width
                let startScale = min(max(expanded.height / width, 0.12), 1)
                piece.transform = CGAffineTransform(translationX: -(width - width * startScale) / 2, y: 0)
                    .scaledBy(x: startScale, y: 1)
                piece.alpha = 0.5
                animated.append((piece, true))
            } else if let collapsed = collapsedFrames[ObjectIdentifier(piece)], collapsed != expanded,
                      collapsed.width > 0, expanded.width > 0 {
                let scale = collapsed.width / expanded.width
                let dx = collapsed.midX - expanded.midX
                let dy = collapsed.midY - expanded.midY
                piece.transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
                animated.append((piece, false))
            }
        }
        UIView.animate(springDuration: 0.38, bounce: 0.1, initialSpringVelocity: 0, delay: 0, options: [.allowUserInteraction]) {
            for item in animated {
                item.view.transform = .identity
                if item.fades { item.view.alpha = 1 }
            }
        }
        restoreTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            controller.tabBarMinimizeBehavior = .onScrollDown
            allowsMinimize = true
            restoreTask = nil
        }
    }

    /// Found once and kept weakly. `expand` can run on many scroll frames in
    /// a row, and walking every scene's controller tree each time was a
    /// measurable cost in the middle of a fling.
    private static weak var cachedTabBarController: UITabBarController?

    /// The app's tab bar controller — the one SwiftUI's `TabView` hosts.
    private static func tabBarController() -> UITabBarController? {
        if let cached = cachedTabBarController, cached.viewIfLoaded?.window != nil {
            return cached
        }
        let found = searchTabBarController()
        cachedTabBarController = found
        return found
    }

    private static func searchTabBarController() -> UITabBarController? {
        let roots = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
        func find(_ controller: UIViewController) -> UITabBarController? {
            if let tabs = controller as? UITabBarController { return tabs }
            for child in controller.children {
                if let found = find(child) { return found }
            }
            return nil
        }
        return roots.lazy.compactMap(find).first
    }
}

/// Accumulates upward travel and expands the bar once it passes `threshold`,
/// so jitter in a slow drag doesn't toggle it.
private struct ScrollSample: Equatable {
    let raw: CGFloat
    let inset: CGFloat
}

private struct TabBarScrollDirection: ViewModifier {
    /// Per-frame bookkeeping in a plain reference box: as `@State` values,
    /// every scroll frame wrote state and re-ran this modifier's body.
    private final class Tracker {
        var lastOffset: CGFloat?
        /// The raw content offset and top inset of the last frame. Direction
        /// and speed come from the raw offset, and a frame where the inset
        /// moved is skipped: collapsing a bar changes the inset, which used to
        /// read as a fast pull back and open both bars again — every scroll
        /// ended with them expanded.
        var lastRaw: CGFloat?
        var lastInset: CGFloat?
        var lastTime: CFTimeInterval = 0
        var downTravel: CGFloat = 0
        var dragStartOffset: CGFloat?
        /// Only a finger (or the fling it started) counts. Offsets reported
        /// while idle — the first layout, a tab appearing, content loading, a
        /// programmatic scroll — used to read as an "upward scroll" and play
        /// the grow on an open bar when switching tabs.
        var isUserScrolling = false
        /// Whether the last offset was in the top region, so arriving there
        /// expands once rather than on every frame spent there.
        var wasAtTop = false
    }

    @State private var tracker = Tracker()

    /// Upward speed, in points per second, that counts as a deliberate flick
    /// back. A slow reading drag stays well under it; tune here.
    static let expandSpeed: CGFloat = 1000

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { oldPhase, newPhase, context in
                let tracker = tracker
                let wasUserScrolling = tracker.isUserScrolling
                tracker.isUserScrolling = newPhase == .interacting || newPhase == .decelerating
                // A drag starting at the top counts as arriving there, the
                // same as the old every-frame expand did.
                if tracker.isUserScrolling, !wasUserScrolling { tracker.wasAtTop = false }
                if newPhase == .interacting {
                    tracker.dragStartOffset = context.geometry.contentOffset.y
                    return
                }
                // The finger lifted: a fast fling back toward the top expands.
                if oldPhase == .interacting, let start = tracker.dragStartOffset {
                    tracker.dragStartOffset = nil
                    let travelled = context.geometry.contentOffset.y - start
                    if travelled < 0, isFastFling(context.velocity?.dy) {
                        TabBarScrollState.shared.expand()
                    }
                }
            }
            .onScrollGeometryChange(for: ScrollSample.self) { geometry in
                ScrollSample(raw: geometry.contentOffset.y, inset: geometry.contentInsets.top)
            } action: { _, sample in
                let tracker = tracker
                let now = CACurrentMediaTime()
                let lastTime = tracker.lastTime
                let offset = sample.raw + sample.inset
                let lastRaw = tracker.lastRaw
                let insetMoved = tracker.lastInset.map { abs($0 - sample.inset) > 0.5 } ?? false
                defer {
                    tracker.lastOffset = offset
                    tracker.lastRaw = sample.raw
                    tracker.lastInset = sample.inset
                    tracker.lastTime = now
                }
                // The first report after appearing is a baseline, not a move.
                guard tracker.lastOffset != nil, let lastRaw else { return }
                let state = TabBarScrollState.shared
                // At (or pulled past) the top the bar is always expanded —
                // done on arrival, not on every frame spent up there.
                if offset <= 1 {
                    tracker.downTravel = 0
                    if tracker.isUserScrolling, !tracker.wasAtTop {
                        tracker.wasAtTop = true
                        state.expand()
                    }
                    state.noteAtTop()
                    return
                }
                tracker.wasAtTop = false
                guard tracker.isUserScrolling, !insetMoved else { return }
                let delta = sample.raw - lastRaw
                if delta > 0 {
                    tracker.downTravel += delta
                    // Scrolling down is the system's own `.onScrollDown`.
                    if tracker.downTravel >= 30 { state.noteScrolledDown() }
                    return
                }
                tracker.downTravel = 0
                // Mid-drag: only a fast pull back expands, never a slow read.
                let dt = now - lastTime
                guard dt > 0.001, delta < 0 else { return }
                let speed = -delta / CGFloat(dt)
                if speed >= Self.expandSpeed { state.expand() }
            }
            .onAppear {
                tracker.lastOffset = nil
                tracker.downTravel = 0
                tracker.wasAtTop = false
                // Back on a tab root (a tab switch, or a pushed page popped)
                // with the bar still collapsed from the page that was on top:
                // open it. `expand` checks the real bar, so an open one is left
                // alone rather than replaying the grow.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    TabBarScrollState.shared.expand()
                }
            }
            .onDisappear {
                tracker.lastOffset = nil
                tracker.isUserScrolling = false
                tracker.dragStartOffset = nil
            }
    }

    /// The release velocity's sign convention isn't documented, so direction
    /// comes from the offset travelled (above) and only the magnitude is used.
    /// `ScrollPhaseChangeContext.velocity` is in points per second.
    private func isFastFling(_ dy: CGFloat?) -> Bool {
        abs(dy ?? 0) >= Self.expandSpeed
    }
}


extension ToolbarContent {
    /// `.sharedBackgroundVisibility(.hidden)` on 26: the item draws its own
    /// background instead of sharing the bar's glass with its neighbours.
    @ToolbarContentBuilder
    func sharedBackgroundVisibilityHiddenIfAvailable() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
