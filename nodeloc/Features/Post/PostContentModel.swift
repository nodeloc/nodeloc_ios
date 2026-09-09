//
//  PostContentModel.swift
//  nodeloc
//
//  Typed intermediate representation for a Discourse post's `cooked` HTML.
//
//  Posts arrive as server-rendered HTML. Rather than stripping it to plain text
//  (which loses formatting, images, quotes, and code) or hosting a WKWebView
//  (heavy, and hard to style consistently), the HTML is parsed once into this
//  block/inline tree and rendered with native SwiftUI views.
//
//  Two levels, mirroring HTML itself:
//    * `PostBlock` — things that stack vertically and own their own layout.
//    * `PostInline` — things that flow inside a line of text.
//
//  Everything is `nonisolated Sendable` so parsing can run off the main actor.
//  The project builds with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so
//  omitting `nonisolated` would silently pin these to the main actor.
//

import Foundation

// MARK: - Inline

/// Inline styling, as a set because Discourse nests `<strong><em>…`.
nonisolated struct PostTextStyle: OptionSet, Sendable, Hashable, Codable {
    let rawValue: Int

    static let bold = PostTextStyle(rawValue: 1 << 0)
    static let italic = PostTextStyle(rawValue: 1 << 1)
    static let strikethrough = PostTextStyle(rawValue: 1 << 2)
    static let code = PostTextStyle(rawValue: 1 << 3)
}

/// An `@user`, `#node` or `#tag` written into a post: a pointer at another page
/// on the site rather than prose.
///
/// One type for all three because they look and behave identically — a capsule
/// badge that opens its target in a half sheet. `href` is kept verbatim from the
/// cooked HTML instead of rebuilt from `slug`, so routing sees exactly what
/// Discourse meant (`/c/{slug}/{id}`, `/tag/{slug}/{id}`) with no guessing.
nonisolated struct PostReference: Sendable, Equatable, Hashable, Identifiable {
    enum Kind: Sendable, Equatable, Hashable {
        case user
        /// `data-type="category"` — a node in this app's vocabulary.
        case node
        case tag
    }

    var kind: Kind
    /// Username, node slug or tag slug.
    var slug: String
    /// What the badge reads. Not always the slug: Discourse cooks `@James` with
    /// the display casing while the href carries `/u/james`.
    var label: String
    var href: String

    /// Kind *and* slug: the same name can be both a tag and a node.
    var id: String { "\(kind)|\(slug)" }

    /// Leading glyph on the badge.
    var symbolName: String {
        switch kind {
        case .user: "at"
        case .node: "square.stack"
        case .tag: "number"
        }
    }

    /// Prefix used in plain-text flattening, where there is no badge to draw.
    var textPrefix: String {
        switch kind {
        case .user: "@"
        case .node, .tag: "#"
        }
    }
}

nonisolated enum PostInline: Sendable, Equatable {
    case text(String)
    case styled(String, PostTextStyle)
    /// Children rather than a flat string so links can contain styled runs.
    case link(href: String, children: [PostInline])
    /// `@user`, `#node`, `#tag` — drawn as a badge, see `PostReference`.
    case reference(PostReference)
    /// `<img class="emoji">`. Carries the shortcode as fallback text, because
    /// SwiftUI's AttributedString has no image-attachment equivalent and the
    /// image may not have loaded yet.
    case emoji(url: String, shortcode: String)
    case lineBreak

    /// Flattened text, used for previews and accessibility labels.
    var plainText: String {
        switch self {
        case .text(let value): value
        case .styled(let value, _): value
        case .link(_, let children): children.map(\.plainText).joined()
        case .reference(let reference): reference.textPrefix + reference.label
        case .emoji(_, let shortcode): shortcode
        case .lineBreak: "\n"
        }
    }
}

nonisolated extension [PostInline] {
    var plainText: String { map(\.plainText).joined() }

    var isEffectivelyEmpty: Bool {
        plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !contains { if case .emoji = $0 { return true } else { return false } }
    }

    /// Whether this run needs the TextKit renderer: badges are text attachments,
    /// which a SwiftUI `Text` can't host. Everything without one keeps the
    /// cheaper `Text` path.
    var containsReference: Bool {
        contains { inline in
            switch inline {
            case .reference: true
            case .link(_, let children): children.containsReference
            default: false
            }
        }
    }
}

// MARK: - Block payloads

/// `div.lightbox-wrapper > a.lightbox[href=full] > img[src=thumb, width, height]`.
/// The intrinsic size matters: without it the layout reflows when each image
/// finishes loading.
nonisolated struct PostImage: Sendable, Equatable, Identifiable {
    let id = UUID()
    var src: String
    /// Full-resolution target from the enclosing lightbox link, when present.
    var href: String?
    var alt: String?
    var width: Int?
    var height: Int?

    /// Width ÷ height from the HTML attributes. Used to reserve layout space so
    /// the page doesn't reflow when the image finishes loading.
    var aspectRatio: CGFloat? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return CGFloat(width) / CGFloat(height)
    }

    /// Prefer the lightbox href for full-screen viewing, else the inline source.
    var fullSizeURLString: String { href ?? src }

    private enum CodingKeys: String, CodingKey {
        case src, href, alt, width, height
    }
}

/// `<aside class="quote">` — a quote of another post, with attribution chrome.
nonisolated struct PostQuote: Sendable, Equatable {
    var username: String?
    var avatarURL: String?
    var topicTitle: String?
    var blocks: [PostBlock]
}

/// `<div class="video-placeholder-container" data-video-src="…">` — how core
/// Discourse cooks `![name|video](upload://…)`.
///
/// `discourse-anyvideo` transcodes the upload; `AnyVideoResolver` swaps in that
/// HLS rendition before anything plays, and keeps `src` as the fallback.
nonisolated struct PostVideo: Sendable, Equatable, Identifiable {
    let id = UUID()
    var src: String
    /// Present when the server cooked an optimized variant.
    var originalSrc: String?
    /// `data-thumbnail-src`, attached server-side by matching an upload named
    /// after the video's SHA1 (see `pretty_text.rb`). Often absent.
    var posterSrc: String?

    /// Upload SHA1, taken from the filename.
    ///
    /// Deliberately not the plugin's regex: that one matches a fixed directory
    /// depth (`/original/\dX/<one-segment>/<sha1>`) and returns nil for real
    /// nodeloc URLs like `/original/3X/0/d/<sha1>.mp4`. The basename is always
    /// `<sha1>.<ext>` at any depth.
    var sha1: String? {
        let path = src.components(separatedBy: "?").first ?? src
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard stem.count == 40, stem.allSatisfy(\.isHexDigit) else { return nil }
        return stem.lowercased()
    }

    private enum CodingKeys: String, CodingKey {
        case src, originalSrc, posterSrc
    }
}

/// A third-party video embed — YouTube, TikTok and anything else Discourse
/// cooks as an iframe.
///
/// Held as its own block rather than folded into `PostVideo`: those are files
/// AVPlayer can open, while these only exist inside a web view. The two need
/// different players, so keeping them apart stops one from being handed to the
/// wrong one.
nonisolated struct PostEmbed: Sendable, Equatable, Identifiable {
    let id = UUID()
    /// What a web view loads to play it.
    var embedURL: String
    /// The human page for the same video, when the markup reveals it — used by
    /// "在浏览器中打开". Nil when only the embed address is known.
    var pageURL: String?
    /// `data-provider-name`, or the host as a fallback. Shown on the card.
    var provider: String?
    var title: String?
    var thumbnailURL: String?
    /// Most embeds are 16:9; the ones that aren't (TikTok is portrait) say so.
    var aspectRatio: CGFloat = 16 / 9

    private enum CodingKeys: String, CodingKey {
        case embedURL, pageURL, provider, title, thumbnailURL, aspectRatio
    }
}

/// `<aside class="onebox">` — an unfurled link preview.
nonisolated struct PostOnebox: Sendable, Equatable {
    var url: String?
    var title: String?
    var descriptionText: String?
    var imageURL: String?
    var faviconURL: String?
}

// MARK: - Block

nonisolated indirect enum PostBlock: Sendable, Equatable, Identifiable {
    case paragraph([PostInline])
    case heading(level: Int, [PostInline])
    case image(PostImage)
    case video(PostVideo)
    /// A third-party embed that only plays inside a web view.
    case embed(PostEmbed)
    case codeBlock(language: String?, code: String)
    case quote(PostQuote)
    case blockquote([PostBlock])
    case list(ordered: Bool, items: [[PostBlock]])
    case table(headers: [[PostInline]], rows: [[[PostInline]]])
    case details(summary: [PostInline], blocks: [PostBlock])
    case spoiler([PostBlock])
    case onebox(PostOnebox)
    case divider
    /// Marks where `<div class="poll">` sat in the source. The poll itself is
    /// rendered from `post.polls`, matched on this name — keeping the poll at
    /// its authored position instead of appending it to the end.
    case pollPlaceholder(name: String)
    /// discourse-permission: a stretch of the post gated behind a requirement.
    case permission(PostPermissionBlock)

    var id: String { stableKey }

    /// Whether this block renders through `PostReferenceTextView`.
    ///
    /// Read per block, not per post, so a body-level tap gesture can be
    /// attached to every *other* block: that renderer is a
    /// `UIViewRepresentable`, and a SwiftUI tap wrapped around it cancels the
    /// touch before the text view can tell which badge was hit.
    var containsReference: Bool {
        switch self {
        case .paragraph(let inlines), .heading(_, let inlines):
            return inlines.containsReference
        case .blockquote(let nested), .spoiler(let nested):
            return nested.contains(where: \.containsReference)
        case .details(_, let nested):
            return nested.contains(where: \.containsReference)
        case .permission(let block):
            return block.blocks.contains(where: \.containsReference)
        case .list(_, let items):
            return items.contains { $0.contains(where: \.containsReference) }
        default:
            return false
        }
    }

    /// Structural identity for `ForEach`. Content-derived rather than a UUID so
    /// that re-parsing the same HTML doesn't churn view identity.
    private var stableKey: String {
        switch self {
        case .paragraph(let inlines): "p:\(inlines.plainText.prefix(48))"
        case .heading(let level, let inlines): "h\(level):\(inlines.plainText.prefix(48))"
        case .image(let image): "img:\(image.src)"
        case .video(let video): "video:\(video.src)"
        case .embed(let embed): "embed:\(embed.embedURL)"
        case .codeBlock(let language, let code): "code:\(language ?? "")\(code.prefix(32))"
        case .quote(let quote): "quote:\(quote.username ?? "")\(quote.blocks.count)"
        case .blockquote(let blocks): "bq:\(blocks.count):\(blocks.first?.stableKey ?? "")"
        case .list(let ordered, let items): "list:\(ordered):\(items.count):\(items.first?.first?.stableKey ?? "")"
        case .table(let headers, let rows): "table:\(headers.count)x\(rows.count)"
        case .details(let summary, _): "details:\(summary.plainText.prefix(32))"
        case .spoiler(let blocks): "spoiler:\(blocks.count):\(blocks.first?.stableKey ?? "")"
        case .onebox(let onebox): "onebox:\(onebox.url ?? onebox.title ?? "")"
        case .divider: "hr"
        case .pollPlaceholder(let name): "poll:\(name)"
        case .permission(let block): "perm:\(block.requirement.key):\(block.isUnlocked):\(block.blocks.count)"
        }
    }

    /// Flattened text for excerpts and quote previews.
    var plainText: String {
        switch self {
        case .paragraph(let inlines): inlines.plainText
        case .heading(_, let inlines): inlines.plainText
        case .image(let image): image.alt ?? ""
        case .video: AppString("[视频]")
        case .embed(let embed): embed.title ?? AppString("[视频]")
        case .codeBlock(_, let code): code
        case .quote(let quote): quote.blocks.map(\.plainText).joined(separator: "\n")
        case .blockquote(let blocks): blocks.map(\.plainText).joined(separator: "\n")
        case .list(_, let items): items.map { $0.map(\.plainText).joined() }.joined(separator: "\n")
        case .table(let headers, let rows):
            ([headers.map(\.plainText)] + rows.map { $0.map(\.plainText) })
                .map { $0.joined(separator: " ") }
                .joined(separator: "\n")
        case .details(let summary, let blocks):
            ([summary.plainText] + blocks.map(\.plainText)).joined(separator: "\n")
        case .spoiler(let blocks): blocks.map(\.plainText).joined(separator: "\n")
        case .onebox(let onebox): [onebox.title, onebox.descriptionText].compactMap { $0 }.joined(separator: " ")
        case .divider: ""
        case .pollPlaceholder: ""
        case .permission(let block):
            // Locked: the notice is all there is to say. Unlocked: the content
            // itself, so an excerpt of a gated post reads normally.
            block.isUnlocked ? block.blocks.map(\.plainText).joined(separator: "\n") : block.notice
        }
    }
}

/// discourse-permission: a stretch of a post the author gated behind a
/// requirement — replying, signing in, or paying points.
///
/// The server decides what this reader may see, and cooks accordingly: an
/// unlocked block arrives with its content, a locked one as a short notice and
/// nothing else. The app never holds content it wasn't given, which is the only
/// safe arrangement — the check is server-side and stays there.
nonisolated struct PostPermissionBlock: Sendable, Equatable {
    enum Requirement: Sendable, Equatable {
        case login
        case reply
        /// `amount` is in points (能量), as the author set it.
        case pay(amount: Int)

        var key: String {
            switch self {
            case .login: "login"
            case .reply: "reply"
            case .pay(let amount): "pay:\(amount)"
            }
        }
    }

    let requirement: Requirement
    /// Whether the server sent the real content. When false, `blocks` is empty.
    let isUnlocked: Bool
    /// The content, when unlocked.
    let blocks: [PostBlock]
    /// The server's own explanation of the requirement, shown when locked.
    /// Used verbatim: it is already in the site's language and carries the
    /// amount and buyer count the plugin chose to disclose.
    let notice: String
    /// Pay blocks only — how many people have bought it.
    let buyersCount: Int?
}

// MARK: - Parsed document

/// A parsed post body plus the derived bits the UI needs often enough that
/// recomputing them per frame would be wasteful.
nonisolated struct PostContent: Sendable, Equatable {
    var blocks: [PostBlock]

    static let empty = PostContent(blocks: [])

    var isEmpty: Bool { blocks.isEmpty }

    /// Every image in reading order, for the full-screen viewer's paging.
    var images: [PostImage] {
        Self.collectImages(in: blocks)
    }

    /// Every video in reading order, so the full-screen player can page between
    /// them the way Reddit does.
    var videos: [PostVideo] {
        Self.collectVideos(in: blocks)
    }

    /// Whether any paragraph renders through `PostReferenceTextView`.
    ///
    /// Callers need this to decide gestures, not styling: that renderer is a
    /// `UIViewRepresentable`, and a SwiftUI `onTapGesture` wrapped around it
    /// cancels the touch before the text view can resolve which badge was hit.
    var containsReference: Bool {
        blocks.contains(where: \.containsReference)
    }

    var plainText: String {
        blocks
            .map(\.plainText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Short single-line summary, used for reply previews.
    func excerpt(limit: Int = 120) -> String {
        let flattened = plainText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }

    /// Whether anything here is still gated behind replying.
    ///
    /// Replying unlocks it *server-side*, so this is what tells `TopicStore`
    /// that a just-posted reply changed the body the server would now render
    /// for this viewer. Nothing about the local copy changes on its own.
    var hasReplyLockedContent: Bool {
        Self.containsReplyLock(in: blocks)
    }

    private static func containsReplyLock(in blocks: [PostBlock]) -> Bool {
        blocks.contains { block in
            switch block {
            case .permission(let permission):
                if case .reply = permission.requirement, !permission.isUnlocked { return true }
                return containsReplyLock(in: permission.blocks)
            case .quote(let quote): return containsReplyLock(in: quote.blocks)
            case .blockquote(let nested): return containsReplyLock(in: nested)
            case .list(_, let items): return items.contains { containsReplyLock(in: $0) }
            case .details(_, let nested): return containsReplyLock(in: nested)
            case .spoiler(let nested): return containsReplyLock(in: nested)
            default: return false
            }
        }
    }

    private static func collectImages(in blocks: [PostBlock]) -> [PostImage] {
        blocks.flatMap { block -> [PostImage] in
            switch block {
            case .image(let image): [image]
            case .quote(let quote): collectImages(in: quote.blocks)
            case .blockquote(let nested): collectImages(in: nested)
            case .list(_, let items): items.flatMap { collectImages(in: $0) }
            case .details(_, let nested): collectImages(in: nested)
            case .spoiler(let nested): collectImages(in: nested)
            default: []
            }
        }
    }

    private static func collectVideos(in blocks: [PostBlock]) -> [PostVideo] {
        blocks.flatMap { block -> [PostVideo] in
            switch block {
            case .video(let video): [video]
            case .quote(let quote): collectVideos(in: quote.blocks)
            case .blockquote(let nested): collectVideos(in: nested)
            case .list(_, let items): items.flatMap { collectVideos(in: $0) }
            case .details(_, let nested): collectVideos(in: nested)
            case .spoiler(let nested): collectVideos(in: nested)
            default: []
            }
        }
    }
}
