//
//  OverlayShared.swift
//  nodeloc
//
//  Pieces used by more than one overlay. These lived at the top of
//  Overlays.swift as `private` declarations; splitting that file into one file
//  per feature meant they had to become internal so the new files can reach
//  them.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared page header

/// The one header every settings-style page uses: a glass button, the title,
/// and optional trailing items on a 56pt row.
///
/// `.back` (‹) for a page pushed onto a stack, `.close` (✕) for a full-screen
/// modal or sheet that goes away entirely — so the glyph tells the reader
/// where the button takes them.
struct PageHeader<Trailing: View>: View {
    enum Leading {
        case back
        case close

        var systemImage: String {
            switch self {
            case .back: "chevron.left"
            case .close: "xmark"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .back: AppString("返回")
            case .close: AppString("关闭")
            }
        }
    }

    let title: String
    var leading: Leading = .back
    let onClose: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    init(
        title: String,
        leading: Leading = .back,
        onClose: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.leading = leading
        self.onClose = onClose
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: leading.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .frame(width: FloatingHeader.controlHeight, height: FloatingHeader.controlHeight)
            }
            .glassButton(tint: FloatingHeader.glassTint, shape: .circle)
            .shadow(color: FloatingHeader.shadow, radius: 9, y: 6)
            .accessibilityLabel(leading.accessibilityLabel)

            Text(title)
                .font(Theme.body(15, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)

            Spacer(minLength: 8)

            trailing()
        }
        .padding(.horizontal, Theme.pagePadding)
        .frame(height: 56)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, leading: Leading = .back, onClose: @escaping () -> Void) {
        self.init(title: title, leading: leading, onClose: onClose) { EmptyView() }
    }
}

func closeOverlay(_ app: AppState) {
    if app.overlay == .post {
        withAnimation(.panelSlide) {
            app.overlay = nil
        }
    } else {
        withAnimation(.quick) {
            app.overlay = nil
        }
    }
}

/// Presents the in-place auth overlay (AuthFlowOverlay) over whatever the
/// guest was reading, rather than tearing down to the cold-start AuthView.
@MainActor
func presentAuth(_ app: AppState, mode: AuthMode = .login) {
    app.authMode = mode
    withAnimation(.overlayPush) {
        app.overlay = .auth
    }
}

/// 登录, as a tab root's trailing toolbar item while browsing as a guest.
/// Plain text: the toolbar draws the glass capsule around it.
struct GuestLoginButton: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Button {
            presentAuth(app)
        } label: {
            Text("登录")
                .font(Theme.body(15, weight: .semibold))
                .foregroundStyle(Theme.text)
                // Never let a tight bar squeeze the label to nothing.
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// Copies a link as *both* a URL and plain text, then says so.
///
/// `UIPasteboard.url = …` writes only the `public.url` representation. A chat
/// box, a `UITextField`, or anything else that reads `public.utf8-plain-text`
/// then pastes nothing at all — which is what made 复制链接 look broken. One
/// pasteboard item carrying both types satisfies either reader.
func copyLink(_ url: URL, message: String = AppString("链接已复制")) {
    UIPasteboard.general.setItems([[
        UTType.url.identifier: url,
        UTType.utf8PlainText.identifier: url.absoluteString,
    ]])
    ToastCenter.shared.show(message)
}

/// Opens a place name in Maps.
///
/// `UIApplication.shared.open`, not the SwiftUI environment's `openURL`: the app
/// funnels every link through one root handler that keeps nodeloc URLs native and
/// sends the rest to the in-app browser, and a map belongs in Maps.
func openInMaps(_ place: String) {
    let trimmed = place.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://maps.apple.com/?q=\(query)")
    else { return }
    UIApplication.shared.open(url)
}

/// Opens a profile's website in the in-app browser.
///
/// `websiteName` is only a host — "example.com" — so it needs the scheme back
/// before it is a URL at all.
func openProfileWebsite(url: URL?, displayText: String?) {
    if let url {
        BrowserState.shared.open(url)
        return
    }
    guard let displayText, !displayText.isEmpty else { return }
    // Only when it looks like a host. `URL(string:)` accepts far more than it
    // should — "我的博客" comes back as `https://xn--9krq6qeqfkxx`, a valid URL
    // pointing at nothing — so a dot and no whitespace are the gate.
    let candidate = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
    let looksLikeHost = candidate.contains("://")
        || (candidate.contains(".") && !candidate.contains(where: \.isWhitespace))
    guard looksLikeHost else { return }
    let normalized = candidate.contains("://") ? candidate : "https://\(candidate)"
    guard let url = URL(string: normalized), url.host != nil else { return }
    BrowserState.shared.open(url)
}

func nodelocSiteURL(_ path: String) -> URL? {
    if path.hasPrefix("http") { return URL(string: path) }
    if path.hasPrefix("/") {
        return URL(string: path, relativeTo: DiscourseConfig.baseURL)?.absoluteURL
    }
    return URL(string: "/\(path)", relativeTo: DiscourseConfig.baseURL)?.absoluteURL
}

// MARK: - Safe area

extension UIApplication {
    /// Status-bar height, for views that ignore the safe area and have to add
    /// it back themselves.
    ///
    /// `max` rather than `first` because scene order is not defined, and the
    /// fallback is a real status-bar height rather than zero: the list is empty
    /// until a window attaches, and returning zero there collapses the banner
    /// that this value is sizing and slides it under the notch.
    static var topSafeAreaInset: CGFloat {
        shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }
            .max() ?? 47
    }

    /// The home-indicator inset. Zero on a device with a button, so anything
    /// reaching into this space has to cope with it being absent.
    static var bottomSafeAreaInset: CGFloat {
        shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom }
            .max() ?? 0
    }

    /// Whether a sheet or full-screen cover is on screen.
    ///
    /// Asked of UIKit rather than tracked in `AppState`: every `.sheet` and
    /// `.fullScreenCover` is a presented view controller, wherever in the view
    /// tree it was declared, so one question covers all of them — including the
    /// ones a screen presents locally, which no app-level flag knows about.
    ///
    /// `AppState` uses it to decide whether a routed page may be drawn in the
    /// content column: content drawn there lands *underneath* any cover, so a
    /// page opened from inside one has to be a cover itself.
    static var isPresentingContext: Bool {
        shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .contains { $0.presentedViewController != nil }
    }
}

// MARK: - Node identity

/// Two nodes side by side, for the two-column browse grid.
struct NodeCardPair: Identifiable {
    let first: SidebarNodeSummary
    let second: SidebarNodeSummary?

    var id: Int { first.id }
}

struct NodeAvatar: View {
    let node: SidebarNodeSummary
    var size: CGFloat = 40
    var cornerRadius: CGFloat = 12

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if let logoURL = node.logoURL {
                CachedRemoteImage(url: logoURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(nodeAccentColor(node.colorHex).opacity(0.16), in: shape)
        .clipShape(shape)
    }

    private var fallback: some View {
        NodeGlyph(node: node, size: size, letterRatio: 0.4)
    }
}

/// Like `NodeAvatar` but bordered, used in list rows rather than headers.
struct NodeSummaryIcon: View {
    let node: SidebarNodeSummary
    var size: CGFloat = 42
    var cornerRadius: CGFloat = 13

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if let logoURL = node.logoURL {
                CachedRemoteImage(url: logoURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(nodeAccentColor(node.colorHex).opacity(0.16), in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Theme.divider, lineWidth: 1)
        }
    }

    private var fallback: some View {
        NodeGlyph(node: node, size: size, letterRatio: 0.36)
    }
}

/// What a node shows when it has no uploaded logo.
///
/// Discourse's own ladder: `style_type: "icon"` draws a Font Awesome / Lucide
/// glyph named by `icon`, `"emoji"` draws that emoji, and `"square"` is just the
/// colour. Only 82 of nodeloc's 176 categories have a logo, so without this most
/// nodes came out as an initial on a coloured tile — which is what made 常去节点
/// look wrong.
struct NodeGlyph: View {
    let node: SidebarNodeSummary
    let size: CGFloat
    let letterRatio: CGFloat

    var body: some View {
        Group {
            if let asset = node.iconName.flatMap(Self.assetName) {
                Image(asset)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.26)
                    .foregroundStyle(nodeAccentColor(node.colorHex))
            } else if let emojiURL = node.emoji.flatMap(Self.emojiImageURL) {
                CachedRemoteImage(url: emojiURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    letter
                }
                .padding(size * 0.22)
            } else {
                letter
            }
        }
        .frame(width: size, height: size)
    }

    private var letter: some View {
        Text(node.name.first.map(String.init) ?? "#")
            .font(Theme.heading(size * letterRatio, weight: .bold))
            .foregroundStyle(nodeAccentColor(node.colorHex))
    }

    /// `laptop-code` → `FaLaptopCode`, `lc-rss` → `LucideRss`. Only names whose
    /// glyph was extracted from the site's SVG sprite resolve; anything else
    /// falls through to the initial rather than drawing a blank tile.
    static func assetName(_ icon: String) -> String? {
        let parts = icon.split(separator: "-").map { $0.capitalized }
        guard !parts.isEmpty else { return nil }
        let name = parts.first == "Lc"
            ? "Lucide" + parts.dropFirst().joined()
            : "Fa" + parts.joined()
        return UIImage(named: name) == nil ? nil : name
    }

    /// A category's `emoji` is a shortcode; Discourse serves the standard set at
    /// a predictable path. The site's *custom* emoji (`xhj001`) live under
    /// `/uploads` instead and 404 here, which the placeholder handles by drawing
    /// the initial.
    static func emojiImageURL(_ shortcode: String) -> URL? {
        let cleaned = shortcode.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        guard !cleaned.isEmpty else { return nil }
        return nodelocSiteURL("/images/emoji/twemoji/\(cleaned).png")
    }
}

func nodeAccentColor(_ hex: String) -> Color {
    let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard let value = UInt32(cleaned, radix: 16) else { return Theme.accent }
    return Color(hex: value)
}

extension Color {
    static let neutral900Scrim = Theme.neutral900.opacity(0.55)
}

// MARK: - App identity

struct AppLogo: View {
    let app: DirectoryApp
    var size: CGFloat = 64
    var cornerRadius: CGFloat = 16

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if let url = NodeSummaryFactory.resolvedURL(app.logoUrl) {
                CachedRemoteImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(Theme.surface, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.divider, lineWidth: 1))
    }

    private var fallback: some View {
        Text(app.name.first.map(String.init) ?? "#")
            .font(Theme.heading(size * 0.38, weight: .bold))
            .foregroundStyle(Theme.accent)
    }
}

// MARK: - Sheet scaffolding

extension View {
    /// The detent + drag-indicator pair every sheet in the app repeats.
    func standardSheet(_ detents: Set<PresentationDetent> = [.medium, .large]) -> some View {
        presentationDetents(detents)
            .presentationDragIndicator(.visible)
    }

    /// A sheet holding a *form*, which wants more room than the default.
    ///
    /// Full height on the phone rather than opening at `.medium`, where a
    /// couple of fields and a footer already reach the bottom. `.page` on iPad,
    /// because the system's form sheet there is narrow enough that the same
    /// content feels cramped — which is what a reader reads as "too small".
    func formSheet() -> some View {
        standardSheet([.large])
            .presentationSizing(.page)
    }
}

/// Icon over a short message, for a list with nothing in it.
struct EmptyStateView: View {
    let icon: String
    let message: String
    var iconSize: CGFloat = 30

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(Theme.textFaint)
            Text(message)
                .font(Theme.body(14, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
        }
    }
}
