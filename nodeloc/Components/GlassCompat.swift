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

/// The only two shapes the app ever draws glass in.
///
/// This exists because the fallback has to *draw* the shape, and
/// `ButtonBorderShape` can't be read back or converted into one.
enum GlassShape {
    case circle
    case capsule

    var shape: AnyShape {
        switch self {
        case .circle: AnyShape(Circle())
        case .capsule: AnyShape(Capsule())
        }
    }

    var borderShape: ButtonBorderShape {
        switch self {
        case .circle: .circle
        case .capsule: .capsule
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
