//
//  SocialLoginView.swift
//  nodeloc
//
//  Social sign-in through Discourse's own auth providers (`/auth/<name>`),
//  rather than a User API Key.
//
//  The site drives the whole OAuth round-trip itself: it bounces to Google /
//  GitHub / X / Telegram and, on the way back, sets its ordinary session
//  cookies. So the app just hosts that journey in a web view and, once the
//  `_t` cookie appears, hands the cookies to `DiscourseLogin`, which adopts
//  them exactly as it would after a username/password login.
//
//  A web view (not ASWebAuthenticationSession) because the session lives in
//  cookies we need to read: the auth session hands back only a callback URL,
//  and its cookie jar is not ours to inspect.
//

import SwiftUI
import WebKit

/// One provider as advertised by `site.json`.
struct SocialAuthProvider: Identifiable, Hashable {
    let name: String

    var id: String { name }

    /// Discourse's own route for this provider.
    var url: URL {
        DiscourseConfig.baseURL.appending(path: "auth/\(name)")
    }

    /// Resolved through the catalog here rather than handed to `Text` as a
    /// key, because it is also used as a navigation title and a String.
    var title: String {
        switch name {
        // Apple's own wording. Their guidelines allow only "Sign in with
        // Apple" / "Continue with Apple" / "Sign up with Apple" and the
        // official translations of those — 「通过 Apple 继续」 is the zh-Hans
        // form of the second, and it matches the row's existing phrasing.
        case "apple": return AppString("通过 Apple 继续")
        case "google_oauth2": return AppString("通过 Google 继续")
        case "github": return AppString("通过 GitHub 继续")
        case "twitter": return AppString("通过 X 继续")
        case "telegram": return AppString("通过 Telegram 继续")
        case "discord": return AppString("通过 Discord 继续")
        case "linkedin": return AppString("通过 LinkedIn 继续")
        default: return AppString("通过 \(name.capitalized) 继续")
        }
    }

    /// Brand artwork in the asset catalog (vector SVG, original colours).
    /// Nil for a provider the site has enabled but we ship no mark for.
    var assetName: String? {
        switch name {
        case "google_oauth2": return "SocialGoogle"
        case "github": return "SocialGitHub"
        case "twitter": return "SocialX"
        case "telegram": return "SocialTelegram"
        default: return nil
        }
    }

    /// Fallback glyph for providers without shipped artwork. Apple ships its
    /// own mark as an SF Symbol, which is the sanctioned way to draw it — no
    /// brand artwork to bundle and keep up to date.
    var fallbackSymbol: String {
        name == "apple" ? "apple.logo" : "person.circle"
    }
}

/// One appearance for every sign-in button, Apple's included.
///
/// Apple's row is a *custom* Sign in with Apple button rather than the system
/// control, which their guidelines explicitly provide for — the first reason
/// they give for building one is wanting to "align logos across multiple
/// sign-in buttons", and they also allow adjusting the font, corner radius and
/// bezel to coordinate with the surrounding UI. The system button centres its
/// logo with its title and sizes the logo to its own taste, so it could never
/// line up with a column of leading-aligned provider marks.
///
/// What their guidelines do *not* leave open, and what this type therefore
/// holds fixed for the Apple row:
///
/// - the title is one of the three approved phrases (`SocialAuthProvider.title`);
/// - logo and title are both black or white, never a custom colour;
/// - the title is 43% of the button height (`textHeightRatio`);
/// - the button is no smaller than the others — which is automatic here, since
///   they all share this style.
struct SocialAuthButtonStyle: ButtonStyle {
    var height: CGFloat = SocialAuthButtonStyle.height
    /// Filled for the identity providers, outlined for "use email".
    ///
    /// Apple's ask is parity of *size and prominence*, not identical fills — so
    /// the geometry is shared and the secondary route stays distinguishable,
    /// which is the same distinction their own `.whiteOutline` style draws.
    var filled = true

    @Environment(\.colorScheme) private var colorScheme

    /// One height for every auth button in the app, Apple's included.
    ///
    /// 44 is Apple's documented default and recommended height for a Sign in
    /// with Apple button on iOS. It is also what fixes the oversized labels:
    /// the title is a fixed *proportion* of the height (below), so the 48 this
    /// used to be forced a ~21pt title on every row.
    static let height: CGFloat = 44
    static let cornerRadius: CGFloat = 8

    /// Apple's required proportion for a custom Sign in with Apple button:
    /// "the title's font size would be 43% of the button's height". Their own
    /// worked examples are 44pt → 19pt and 56pt → 24pt.
    ///
    /// This is a constraint, not a preference — a custom button "needs to use
    /// the same proportions that the system uses". To make the text smaller,
    /// lower `height`; don't break the ratio.
    static let textHeightRatio: CGFloat = 0.43

    static func titleSize(for height: CGFloat) -> CGFloat {
        (height * textHeightRatio).rounded()
    }

    /// The system font, which Apple asks custom buttons to prefer. Weight is
    /// explicitly ours to choose.
    static func titleFont(for height: CGFloat) -> Font {
        .system(size: titleSize(for: height), weight: .medium)
    }

    /// Box for a provider mark, tied to the text so the two scale together.
    ///
    /// Slightly larger than the title, because these marks are drawn to fill
    /// their box while a glyph at the same nominal point size only fills part
    /// of its line. Apple sanctions matching their logo to the others: the
    /// artwork ships in three sizes "so you can match logo sizes in all the
    /// sign-up buttons you display".
    static func glyphSize(for height: CGFloat) -> CGFloat {
        (titleSize(for: height) * 1.15).rounded()
    }

    func makeBody(configuration: Configuration) -> some View {
        // Inverted against the scheme, the same way `.black` / `.white` are
        // chosen for the Apple button.
        let fill: Color = colorScheme == .dark ? .white : .black
        let onFill: Color = colorScheme == .dark ? .black : .white
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)

        return configuration.label
            .font(Self.titleFont(for: height))
            .foregroundStyle(filled ? onFill : Theme.text)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background {
                if filled {
                    shape.fill(fill)
                } else {
                    shape.strokeBorder(Theme.text.opacity(0.42), lineWidth: 1.25)
                }
            }
            .opacity(configuration.isPressed ? 0.82 : 1)
            // A button's tappable region follows what it *draws*, not the frame
            // it occupies — and what these draw is a mark, a title, and a
            // background, none of which is hit-testable. Without this only the
            // text responded, which on the outlined rows left almost the whole
            // button dead.
            .contentShape(shape)
    }
}

/// The contents of an auth button: mark on the leading edge, title centred.
///
/// Shared so the rows can't drift apart. They already had: the brand marks are
/// drawn `.resizable().scaledToFit()` and so fill their box exactly, while the
/// email row set its symbol with `.font(.system(size:))` — at which an SF
/// Symbol draws a glyph well short of the nominal size. Same number, visibly
/// smaller icon. Anything in a row of these should come through here.
struct AuthButtonLabel<Mark: View>: View {
    let title: String
    var height: CGFloat = SocialAuthButtonStyle.height
    @ViewBuilder var mark: Mark

    var body: some View {
        let glyph = SocialAuthButtonStyle.glyphSize(for: height)

        HStack(spacing: 8) {
            mark.frame(width: glyph, height: glyph)
            Text(title)
                .frame(maxWidth: .infinity)
            // Balances the mark so the title stays optically centred while the
            // icon sits at the leading edge.
            Color.clear.frame(width: glyph, height: 1)
        }
        .padding(.horizontal, 14)
    }
}

/// A symbol drawn to fill an `AuthButtonLabel` mark box, the way the brand
/// artwork does.
struct AuthButtonSymbol: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
    }
}

/// One provider row.
struct SocialProviderButton: View {
    let provider: SocialAuthProvider
    var height: CGFloat = SocialAuthButtonStyle.height
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            AuthButtonLabel(title: provider.title, height: height) {
                SocialProviderIcon(
                    provider: provider,
                    size: SocialAuthButtonStyle.glyphSize(for: height),
                    // A glyph has to take the button's foreground or it
                    // disappears into the fill.
                    monochromeTint: colorScheme == .dark ? .black : .white,
                    // The fill is inverted relative to the page, so the
                    // monochrome marks need the opposite appearance.
                    assetColorScheme: colorScheme == .dark ? .light : .dark
                )
            }
        }
        .buttonStyle(SocialAuthButtonStyle(height: height))
    }
}

/// A provider's brand mark, sized to sit in a row of buttons.
struct SocialProviderIcon: View {
    let provider: SocialAuthProvider
    var size: CGFloat = 20
    /// Colour for the SF Symbol fallback. Nil keeps the old `Theme.text`, which
    /// is right on a plain background and invisible on a filled button.
    var monochromeTint: Color?
    /// Which appearance the asset catalog should resolve to, when it shouldn't
    /// follow the system.
    ///
    /// GitHub and X ship `*-light` / `*-dark` variants of a *monochrome* mark,
    /// picked by luminosity so the glyph contrasts with the **page**. A filled
    /// button inverts that background, so following the system there gave a
    /// black mark on a black button — it simply vanished. Passing the opposite
    /// scheme picks the variant that contrasts with the button instead.
    /// Google and Telegram ship one full-colour asset and are unaffected.
    var assetColorScheme: ColorScheme?

    var body: some View {
        Group {
            if let assetName = provider.assetName {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .environment(\.colorScheme, assetColorScheme ?? systemScheme)
            } else {
                Image(systemName: provider.fallbackSymbol)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(monochromeTint ?? Theme.text)
            }
        }
        .frame(width: size, height: size)
    }

    @Environment(\.colorScheme) private var systemScheme
}

struct SocialLoginView: View {
    let provider: SocialAuthProvider
    /// Called with the site's cookies once the provider round-trip lands back
    /// on nodeloc with a session.
    let onAuthenticated: ([HTTPCookie]) -> Void
    let onCancel: () -> Void

    @State private var isWorking = true

    var body: some View {
        NavigationStack {
            ProviderWebView(
                url: provider.url,
                onAuthenticated: onAuthenticated,
                onNavigationChange: { isWorking = $0 }
            )
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) {
                if isWorking {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                }
            }
            .navigationTitle(provider.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: onCancel)
                }
            }
        }
    }
}

private struct ProviderWebView: UIViewRepresentable {
    let url: URL
    let onAuthenticated: ([HTTPCookie]) -> Void
    let onNavigationChange: (Bool) -> Void

    func makeUIView(context: Context) -> WKWebView {
        // The default (persistent) store, so a provider session the user
        // already has in the app is reused instead of asking every time.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onAuthenticated: onAuthenticated, onNavigationChange: onNavigationChange)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onAuthenticated: ([HTTPCookie]) -> Void
        private let onNavigationChange: (Bool) -> Void
        private var hasFinished = false

        init(
            onAuthenticated: @escaping ([HTTPCookie]) -> Void,
            onNavigationChange: @escaping (Bool) -> Void
        ) {
            self.onAuthenticated = onAuthenticated
            self.onNavigationChange = onNavigationChange
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onNavigationChange(true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onNavigationChange(false)
            checkForSession(in: webView)
        }

        /// Success is "we're back on nodeloc and it has given us a `_t`".
        /// Checked on every completed navigation because Discourse can land
        /// on the homepage, on `/`, or on a returnTo path depending on setup.
        private func checkForSession(in webView: WKWebView) {
            guard !hasFinished,
                  let host = webView.url?.host?.lowercased(),
                  let siteHost = DiscourseConfig.baseURL.host?.lowercased(),
                  strip(host) == strip(siteHost),
                  webView.url?.path.hasPrefix("/auth/") == false
            else { return }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.hasFinished else { return }
                let siteCookies = cookies.filter { strip($0.domain) .hasSuffix(strip(siteHost)) }
                guard siteCookies.contains(where: { $0.name == "_t" }) else { return }
                self.hasFinished = true
                self.onAuthenticated(siteCookies)
            }
        }
    }
}

/// www.nodeloc.com and nodeloc.com are the same site.
private func strip(_ host: String) -> String {
    var value = host.lowercased()
    if value.hasPrefix(".") { value.removeFirst() }
    if value.hasPrefix("www.") { value.removeFirst(4) }
    return value
}
