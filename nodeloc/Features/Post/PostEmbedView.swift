//
//  PostEmbedView.swift
//  nodeloc
//
//  Third-party video embeds inside a post — YouTube, TikTok and anything else
//  Discourse cooks as an iframe.
//
//  Lazy on purpose, which is also what Discourse's own web client does: a post
//  shows a poster with a play button, and the web view is only created for the
//  one a reader taps. Rendering every embed as a live `WKWebView` would put
//  several browsers in one scroll view — each with its own process, memory and
//  autoplay behaviour — and a long thread would crawl.
//

import SwiftUI
import WebKit

struct PostEmbedView: View {
    let embed: PostEmbed

    @State private var isPlaying = false
    @Environment(\.openURL) private var openURL

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    var body: some View {
        Group {
            if isPlaying, let url = URL(string: playbackURLString) {
                EmbedWebView(url: url)
            } else {
                poster
            }
        }
        .aspectRatio(embed.aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Theme.divider, lineWidth: 1)
        }
        // Tearing the player down when it scrolls out of view: a `LazyVStack`
        // stops rendering it anyway, and an invisible web view carrying on with
        // the audio is worse than losing the position.
        .onDisappear { isPlaying = false }
    }

    private var poster: some View {
        Button {
            isPlaying = true
        } label: {
            ZStack {
                // Dark rather than the neutral ramp: a video frame is about to
                // replace it, and a bright plate would flash first.
                LinearGradient(
                    colors: [Theme.neutral800.opacity(0.92), Theme.neutral900],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                if let thumbnail = embed.thumbnailURL, let url = URL(string: thumbnail) {
                    CachedRemoteImage(url: url) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                }

                // Keeps one glyph colour legible over any frame.
                Color.black.opacity(0.22)

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) { providerBadge }
            .overlay(alignment: .bottomLeading) { titleLabel }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        // The watch page, for readers who would rather leave the app. Only
        // offered when the markup actually revealed one — an embed address is
        // not something to hand over as a link.
        .contextMenu {
            if let page = embed.pageURL, let url = URL(string: page) {
                Button {
                    openURL(url)
                } label: {
                    Label("在浏览器中打开", systemImage: "safari")
                }
            }
        }
    }

    @ViewBuilder
    private var providerBadge: some View {
        if let provider = embed.provider {
            Text(provider)
                .font(Theme.body(11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(10)
        }
    }

    @ViewBuilder
    private var titleLabel: some View {
        if let title = embed.title, !title.isEmpty {
            Text(title)
                .font(Theme.body(12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .shadow(color: .black.opacity(0.5), radius: 4)
                .padding(10)
        }
    }

    /// The tap *is* the user's play gesture, so ask the provider to start.
    /// Appended here rather than baked into the parsed URL, which stays a plain
    /// embed address.
    private var playbackURLString: String {
        guard embed.provider?.lowercased() == "youtube" else { return embed.embedURL }
        return embed.embedURL + (embed.embedURL.contains("?") ? "&" : "?") + "autoplay=1"
    }
}

/// A web view sized by its container, for one embed.
///
/// The embed is wrapped in a small local document rather than loaded as the
/// main frame. Loading `youtube.com/embed/…` directly gives the page no
/// referrer and a null origin, and YouTube answers that with "视频播放器配置
/// 错误 153" instead of playing. Hosting the iframe inside a document whose
/// `baseURL` is the site makes the request look like what it is — an embed on
/// nodeloc.com, the same origin the video was posted from.
///
/// The wrapper pays for itself twice over: `allow` grants autoplay and
/// full-screen, which an attribute on someone else's page can't be given, and
/// the CSS pins the iframe to the frame so no provider's default margins get a
/// say in the layout.
private struct EmbedWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Without this the provider hands playback to the full-screen native
        // player, which fights the post's own scroll and chrome.
        configuration.allowsInlineMediaPlayback = true
        // The reader already tapped play; requiring a second gesture inside the
        // frame is the kind of thing that reads as broken.
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        // Nothing here is navigable content, so a swipe should scroll the post
        // rather than page the embed's history.
        webView.allowsBackForwardNavigationGestures = false
        webView.loadHTMLString(Self.document(embedding: url), baseURL: DiscourseConfig.baseURL)
        return webView
    }

    /// Minimal host page for one iframe.
    private static func document(embedding url: URL) -> String {
        let source = url.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, \
        maximum-scale=1, user-scalable=no">
        <style>
        html, body { margin: 0; padding: 0; height: 100%; background: #000; overflow: hidden; }
        iframe { position: absolute; inset: 0; width: 100%; height: 100%; border: 0; }
        </style>
        </head>
        <body>
        <iframe src="\(source)"
                allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
                allowfullscreen
                frameborder="0"
                scrolling="no"></iframe>
        </body>
        </html>
        """
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: ()) {
        // Stops the audio immediately; releasing the view alone can let a frame
        // of sound through.
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }
}
