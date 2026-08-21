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

nonisolated enum PostInline: Sendable, Equatable {
    case text(String)
    case styled(String, PostTextStyle)
    /// Children rather than a flat string so links can contain styled runs.
    case link(href: String, children: [PostInline])
    case mention(username: String)
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
        case .mention(let username): "@\(username)"
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
/// `discourse-anyvideo` upgrades the same element in the web client by looking
/// up an HLS rendition; that plugin isn't installed on this site, so playback
/// uses the original upload URL directly.
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

    var id: String { stableKey }

    /// Structural identity for `ForEach`. Content-derived rather than a UUID so
    /// that re-parsing the same HTML doesn't churn view identity.
    private var stableKey: String {
        switch self {
        case .paragraph(let inlines): "p:\(inlines.plainText.prefix(48))"
        case .heading(let level, let inlines): "h\(level):\(inlines.plainText.prefix(48))"
        case .image(let image): "img:\(image.src)"
        case .video(let video): "video:\(video.src)"
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
        }
    }

    /// Flattened text for excerpts and quote previews.
    var plainText: String {
        switch self {
        case .paragraph(let inlines): inlines.plainText
        case .heading(_, let inlines): inlines.plainText
        case .image(let image): image.alt ?? ""
        case .video: "[视频]"
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
        }
    }
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
