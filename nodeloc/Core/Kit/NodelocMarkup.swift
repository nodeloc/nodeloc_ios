//
//  NodelocMarkup.swift
//  nodeloc
//
//  Rewrites the backend's post HTML into the Discourse "cooked" vocabulary
//  that `PostHTMLParser` and the chat renderer already understand, so the
//  readers did not have to be rewritten along with the API.
//
//  The backend's markup is produced after sanitizing (see the server's
//  internal/markup), so its class names and data attributes are exact and
//  stable; the patterns below match them literally.
//

import Foundation

nonisolated enum NodelocMarkup {
    /// Post body HTML → the cooked shape the post reader parses.
    static func cooked(_ html: String) -> String {
        guard !html.isEmpty else { return html }
        var out = html

        // Polls: `data-poll` → `data-poll-name`.
        out = out.replacingOccurrences(
            of: #"<div class="poll" data-poll="([^"]*)">"#,
            with: #"<div class="poll" data-poll-name="$1">"#,
            options: .regularExpression
        )

        // Uploaded video: the reader resolves `/…/<sha1>.mp4` to the HLS
        // stream through `anyVideo(sha1:)`.
        out = out.replacingOccurrences(
            of: #"<div class="video-embed" data-provider="upload" data-video-id="([0-9a-fA-F]{40})"></div>"#,
            with: #"<div class="video-placeholder-container" data-video-src="/uploads/videos/$1.mp4"></div>"#,
            options: .regularExpression
        )

        // YouTube: the lazy container the reader rebuilds an embed from.
        out = out.replacingOccurrences(
            of: #"<div class="video-embed" data-provider="youtube" data-video-id="([^"]+)">"#,
            with: #"<div class="youtube-onebox lazy-video-container" data-provider-name="youtube" data-video-id="$1">"#,
            options: .regularExpression
        )

        // Bilibili: an iframe, which the reader embeds as is.
        out = out.replacingOccurrences(
            of: #"<div class="video-embed" data-provider="bilibili" data-video-id="([^"]+)">(?s:.*?)</div>"#,
            with: #"<iframe class="bilibili-onebox" src="https://player.bilibili.com/player.html?bvid=$1&amp;autoplay=0"></iframe>"#,
            options: .regularExpression
        )

        // Spoilers, block and inline.
        out = out.replacingOccurrences(of: #"class="post-spoiler""#, with: #"class="spoiler post-spoiler""#)

        // "Log in to see" blocks. Locked: the placeholder span the reader
        // promotes to a locked frame. Unlocked: the content container.
        out = out.replacingOccurrences(
            of: #"<div class="hidden-block" data-hidden="[0-9]+" data-kind="[a-z]*" data-amount="[0-9]*">((?s:.*?))</div>"#,
            with: #"<span class='permission-login-placeholder'>$1</span>"#,
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: #"<div class="hidden-block unlocked">"#,
            with: #"<div class="permission-content" data-type="login">"#
        )

        // #tag references.
        out = out.replacingOccurrences(
            of: #"<a class="mention mn-tag" href="([^"]*)" data-hc="tag:([^"]*)">"#,
            with: #"<a class="hashtag-cooked" href="$1" data-type="tag" data-slug="$2">"#,
            options: .regularExpression
        )

        // $node references carry an avatar chip and `n/slug` text; the reader
        // wants the node's name, which the server put in `title`.
        out = rewriteNodeMentions(out)

        // Tabs: each pane becomes a heading over its content.
        out = out.replacingOccurrences(of: #"<div class="post-tabs" data-tabs>"#, with: "<div>")
        out = out.replacingOccurrences(
            of: #"<div class="tab-pane" data-tab-title="([^"]*)"( data-tab-active)?>"#,
            with: "<div><h4>$1</h4>",
            options: .regularExpression
        )

        // App embeds run in the web page only.
        out = out.replacingOccurrences(
            of: #"<div class="app-embed" data-app-install="([0-9]+)"( data-app-height="[0-9]+")?></div>"#,
            with: "<p><em>\(AppString("这里嵌入了一个应用，请在网页版中打开"))</em></p>",
            options: .regularExpression
        )

        return out
    }

    private static func rewriteNodeMentions(_ html: String) -> String {
        guard html.contains("mn-node") else { return html }
        let pattern = #"<a class="mention mn-node[^"]*" href="/n/([a-z0-9-]+)"([^>]*)>(?s:.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }
        let source = html as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let slug = source.substring(with: match.range(at: 1))
            let attributes = source.substring(with: match.range(at: 2))
            var name = slug
            if let titleRange = attributes.range(of: #"title="([^"]*)""#, options: .regularExpression) {
                name = String(attributes[titleRange].dropFirst(7).dropLast())
            }
            result += #"<a class="hashtag-cooked" href="/c/\#(slug)" data-type="category" data-slug="\#(slug)">\#(name)</a>"#
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
    }

    /// The first image of a post body, for list thumbnails when the server
    /// doesn't send one. Skips emoji, quotes and code, like the server's own
    /// media extraction.
    static func firstImage(in html: String) -> (url: String, width: Int?, height: Int?)? {
        let stripped = html
            .replacingOccurrences(of: #"<blockquote(?s:.*?)</blockquote>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<pre(?s:.*?)</pre>"#, with: "", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: #"<img ([^>]*)>"#) else { return nil }
        let source = stripped as NSString
        for match in regex.matches(in: stripped, range: NSRange(location: 0, length: source.length)) {
            let attributes = source.substring(with: match.range(at: 1))
            if attributes.contains("class=\"emoji") { continue }
            guard let src = attribute("src", in: attributes) else { continue }
            return (src, attribute("width", in: attributes).flatMap(Int.init), attribute("height", in: attributes).flatMap(Int.init))
        }
        return nil
    }

    static func attribute(_ name: String, in attributes: String) -> String? {
        guard let range = attributes.range(of: name + #"="([^"]*)""#, options: .regularExpression) else { return nil }
        return String(attributes[range].dropFirst(name.count + 2).dropLast())
    }

    /// Plain-text excerpt of an HTML body.
    @MainActor
    static func excerpt(_ html: String, limit: Int = 200) -> String {
        let text = DiscourseFormat.plainText(
            html.replacingOccurrences(of: #"<img [^>]*alt="([^"]*)"[^>]*>"#, with: "$1", options: .regularExpression)
        )
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
