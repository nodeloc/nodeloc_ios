//
//  PostHTMLParser.swift
//  nodeloc
//
//  Turns Discourse's `cooked` HTML into a `PostContent` block tree.
//
//  Hand-written rather than pulling in a DOM library, because the input is
//  narrow: `cooked` is server-generated from markdown, so it is well-formed and
//  uses a small, stable tag vocabulary. A survey of real nodeloc topics found
//  only p / img / strong / li / a / ul / br / h2 / hr / svg / span / div in the
//  body, plus the handful of Discourse-specific structures handled below.
//
//  The scanner walks the string by index and keeps an explicit element stack.
//  Regex is deliberately avoided: nested structures (a quote containing a list
//  containing a link) can't be matched correctly by regular expressions, and
//  the naive `<[^>]+>` strip is exactly the behaviour this replaces.
//

import Foundation

// MARK: - Tokenizer

/// One HTML element occurrence. Attributes are lowercased by name; values keep
/// their original case because they carry URLs.
private struct HTMLTag {
    var name: String
    var attributes: [String: String]
    var isClosing: Bool
    var isSelfClosing: Bool
}

private enum HTMLToken {
    case text(String)
    case tag(HTMLTag)
}

/// Elements that never have a closing tag.
///
/// `nonisolated` is required: the project defaults new declarations to the main
/// actor, and the parser reads these from a background task.
private nonisolated let voidElements: Set<String> = [
    "br", "img", "hr", "input", "meta", "link", "source", "col", "area", "wbr",
]

/// Elements whose entire subtree is dropped. Discourse injects inline SVG icon
/// sprites into lightbox chrome; without this their `<use>`/`<path>` contents
/// leak through as stray text.
private nonisolated let droppedElements: Set<String> = ["svg", "script", "style", "head"]

nonisolated enum PostHTMLParser {

    // MARK: Entry points

    /// Parses off the main actor. `@concurrent` is required: this project sets
    /// SWIFT_APPROACHABLE_CONCURRENCY, under which a plain `nonisolated async
    /// func` called from a @MainActor context still runs on the main thread.
    @concurrent
    static func parse(_ html: String?) async -> PostContent {
        parseSync(html)
    }

    static func parseSync(_ html: String?) -> PostContent {
        guard let html, !html.isEmpty else { return .empty }
        let tokens = tokenize(promotePermissionPlaceholders(in: html))
        var index = 0
        let blocks = parseBlocks(tokens, index: &index, until: nil)
        return PostContent(blocks: normalize(blocks))
    }

    /// Rewrites discourse-permission's locked placeholders from a `<span>` into
    /// a block element.
    ///
    /// The plugin emits them inline — `<span class='permission-reply-placeholder'>`
    /// — usually inside whatever paragraph the BBCode sat in. But a locked
    /// section has to be *framed* so the reader can see the post continues
    /// behind a requirement, and a frame is a block. Rewriting the element here
    /// is far less invasive than teaching the inline path to emit blocks and
    /// then unwrapping the paragraph around it.
    ///
    /// The whole element is replaced, opening and closing tag together: turning
    /// only the `<span>` into a `<div>` would leave a stray `</span>` and throw
    /// the nesting out for the rest of the post. Their content is a plain
    /// locale string with no nested markup, so a reluctant match to `</span>`
    /// is safe.
    ///
    /// The unlocked form already arrives as `<div class='permission-content'>`
    /// and needs none of this.
    private static func promotePermissionPlaceholders(in html: String) -> String {
        guard html.contains("-placeholder") else { return html }
        // One pass for all three kinds; the kind itself is captured, along with
        // any remaining attributes (the pay placeholder carries `data-amount`
        // and `data-content-id`) and the notice text.
        let pattern = /<span class='permission-(reply|login|pay)-placeholder'([^>]*)>(.*?)<\/span>/
            .dotMatchesNewlines()
        return html.replacing(pattern) { match in
            let kind = match.output.1
            let attributes = match.output.2
            let notice = match.output.3
            return "<div class='permission-locked' data-type='\(kind)'\(attributes)>\(notice)</div>"
        }
    }

    /// Which requirement a permission element describes.
    ///
    /// `data-type` is on both forms; the amount only on pay. A missing or
    /// unparseable amount still yields `.pay`, because the *requirement* is
    /// what the frame communicates — the number is decoration on top.
    private static func permissionRequirement(from tag: HTMLTag) -> PostPermissionBlock.Requirement {
        let amount = Int(tag.attributes["data-amount"] ?? "") ?? 0
        switch tag.attributes["data-type"] {
        case "login": return .login
        case "reply": return .reply
        case "pay": return .pay(amount: amount)
        default:
            // Fall back to the class name, which carries the type too.
            let classes = classList(tag)
            if classes.contains("permission-login-content") { return .login }
            if classes.contains("permission-reply-content") { return .reply }
            return .pay(amount: amount)
        }
    }

    /// The buyer count from an unlocked pay block's
    /// `<span class='buyers-count'>N …</span>` header.
    ///
    /// Read from the token stream rather than an attribute because the plugin
    /// only puts it in the header text. Nil when absent, which is every
    /// non-pay block.
    private static func permissionBuyersCount(_ tokens: [HTMLToken], from start: Int) -> Int? {
        var index = start
        // The header is the first child, so this only ever looks a few tokens
        // ahead — bounded so a malformed body can't turn into a scan of the
        // whole post.
        let limit = min(tokens.count, start + 24)
        while index < limit {
            if case .tag(let tag) = tokens[index],
               tag.name == "span",
               classList(tag).contains("buyers-count"),
               index + 1 < tokens.count,
               case .text(let value) = tokens[index + 1] {
                let digits = value.prefix { $0.isNumber }
                return Int(digits)
            }
            index += 1
        }
        return nil
    }

    // MARK: Scanning

    private static func tokenize(_ html: String) -> [HTMLToken] {
        var tokens: [HTMLToken] = []
        let scalars = Array(html)
        var index = 0
        var textStart = 0

        func flushText(upTo end: Int) {
            guard end > textStart else { return }
            let raw = String(scalars[textStart..<end])
            let decoded = decodeEntities(raw)
            if !decoded.isEmpty { tokens.append(.text(decoded)) }
        }

        while index < scalars.count {
            guard scalars[index] == "<" else {
                index += 1
                continue
            }

            // `<` not followed by a name is literal text, not a tag.
            let next = index + 1 < scalars.count ? scalars[index + 1] : " "
            guard next == "/" || next == "!" || next.isLetter else {
                index += 1
                continue
            }

            flushText(upTo: index)

            // Comments and doctypes carry nothing we render.
            if next == "!" {
                if let close = find("-->", in: scalars, from: index) {
                    index = close + 3
                } else if let close = find(">", in: scalars, from: index) {
                    index = close + 1
                } else {
                    index = scalars.count
                }
                textStart = index
                continue
            }

            guard let tagEnd = findTagEnd(in: scalars, from: index) else {
                // Unterminated `<`: drop the partial tag rather than emitting it
                // as text. `textStart` has to advance too, or the tail already
                // flushed above would be emitted a second time.
                index = scalars.count
                textStart = index
                break
            }

            let rawTag = String(scalars[(index + 1)..<tagEnd])
            if let tag = parseTag(rawTag) {
                tokens.append(.tag(tag))
            }
            index = tagEnd + 1
            textStart = index
        }

        flushText(upTo: scalars.count)
        return tokens
    }

    /// Finds the `>` that closes a tag, skipping any inside quoted attributes.
    private static func findTagEnd(in scalars: [Character], from start: Int) -> Int? {
        var index = start + 1
        var quote: Character?
        while index < scalars.count {
            let character = scalars[index]
            if let active = quote {
                if character == active { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func find(_ needle: String, in scalars: [Character], from start: Int) -> Int? {
        let target = Array(needle)
        guard !target.isEmpty, scalars.count >= target.count else { return nil }
        var index = start
        while index <= scalars.count - target.count {
            if Array(scalars[index..<(index + target.count)]) == target { return index }
            index += 1
        }
        return nil
    }

    private static func parseTag(_ raw: String) -> HTMLTag? {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }

        let isClosing = body.hasPrefix("/")
        if isClosing { body.removeFirst() }
        var isSelfClosing = false
        if body.hasSuffix("/") {
            isSelfClosing = true
            body.removeLast()
        }

        let characters = Array(body)
        var index = 0
        while index < characters.count, !characters[index].isWhitespace { index += 1 }
        let name = String(characters[0..<index]).lowercased()
        guard !name.isEmpty else { return nil }

        let attributes = isClosing ? [:] : parseAttributes(Array(characters[index...]))
        return HTMLTag(
            name: name,
            attributes: attributes,
            isClosing: isClosing,
            isSelfClosing: isSelfClosing || voidElements.contains(name)
        )
    }

    private static func parseAttributes(_ characters: [Character]) -> [String: String] {
        var attributes: [String: String] = [:]
        var index = 0

        while index < characters.count {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count else { break }

            var nameEnd = index
            while nameEnd < characters.count,
                  !characters[nameEnd].isWhitespace,
                  characters[nameEnd] != "=" {
                nameEnd += 1
            }
            let name = String(characters[index..<nameEnd]).lowercased()
            index = nameEnd

            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count, characters[index] == "=" else {
                // Valueless attribute, e.g. `hidden`.
                if !name.isEmpty { attributes[name] = "" }
                continue
            }
            index += 1
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count else { break }

            var value = ""
            if characters[index] == "\"" || characters[index] == "'" {
                let quote = characters[index]
                index += 1
                let valueStart = index
                while index < characters.count, characters[index] != quote { index += 1 }
                value = String(characters[valueStart..<index])
                if index < characters.count { index += 1 }
            } else {
                let valueStart = index
                while index < characters.count, !characters[index].isWhitespace { index += 1 }
                value = String(characters[valueStart..<index])
            }

            if !name.isEmpty { attributes[name] = decodeEntities(value) }
        }
        return attributes
    }

    // MARK: Recursion guard

    /// Nesting deeper than this degrades to plain text. Both block and inline
    /// assembly recurse one stack frame per tag level, and a pathological post
    /// (hundreds of nested tags) otherwise overflows the cooperative thread's
    /// 512 KB stack — the "one specific post kills the app" crash that
    /// surfaced in ___chkstk_darwin. Real content tops out well under this.
    private static let maxNestingDepth = 40
    @TaskLocal private static var nestingDepth = 0

    /// Over-depth fallback: consumes the subtree keeping only its text.
    private static func flattenedText(
        _ tokens: [HTMLToken],
        index: inout Int,
        closing: String?
    ) -> String {
        var open = 1
        var text = ""
        while index < tokens.count {
            switch tokens[index] {
            case .text(let value):
                text += value
            case .tag(let tag):
                if let closing, tag.name == closing {
                    if tag.isClosing {
                        open -= 1
                        if open == 0 {
                            index += 1
                            return text
                        }
                    } else if !tag.isSelfClosing {
                        open += 1
                    }
                }
            }
            index += 1
        }
        return text
    }

    // MARK: Block assembly

    /// Consumes tokens until `until`'s closing tag (or the end) and returns the
    /// blocks found. Inline runs between block elements are collected into
    /// implicit paragraphs so bare text isn't lost.
    private static func parseBlocks(
        _ tokens: [HTMLToken],
        index: inout Int,
        until closing: String?
    ) -> [PostBlock] {
        guard nestingDepth < maxNestingDepth else {
            let text = flattenedText(tokens, index: &index, closing: closing)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.paragraph([.text(trimmed)])]
        }
        return $nestingDepth.withValue(nestingDepth + 1) {
            parseBlocksBody(tokens, index: &index, until: closing)
        }
    }

    private static func parseBlocksBody(
        _ tokens: [HTMLToken],
        index: inout Int,
        until closing: String?
    ) -> [PostBlock] {
        var blocks: [PostBlock] = []
        var pendingInlines: [PostInline] = []

        func flushInlines() {
            let trimmed = trimEdges(pendingInlines)
            if !trimmed.isEffectivelyEmpty { blocks.append(.paragraph(trimmed)) }
            pendingInlines = []
        }

        while index < tokens.count {
            switch tokens[index] {
            case .text(let value):
                pendingInlines.append(.text(value))
                index += 1

            case .tag(let tag):
                if tag.isClosing {
                    if let closing, tag.name == closing {
                        index += 1
                        flushInlines()
                        return blocks
                    }
                    // Stray or mismatched close: ignore and keep going, the way
                    // a browser would, rather than aborting the whole subtree.
                    index += 1
                    continue
                }

                if droppedElements.contains(tag.name) {
                    index += 1
                    if !tag.isSelfClosing { skipSubtree(tokens, index: &index, name: tag.name) }
                    continue
                }

                if isBlockLevel(tag) {
                    flushInlines()
                    index += 1
                    if let block = parseBlockElement(tag, tokens: tokens, index: &index) {
                        blocks.append(contentsOf: block)
                    }
                } else {
                    let inlines = parseInlineElement(tag, tokens: tokens, index: &index)
                    pendingInlines.append(contentsOf: inlines)
                }
            }
        }

        flushInlines()
        return blocks
    }

    private static func isBlockLevel(_ tag: HTMLTag) -> Bool {
        switch tag.name {
        case "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li",
             "blockquote", "aside", "pre", "hr", "table", "details", "figure",
             "section", "article", "video", "iframe":
            return true
        case "img":
            // A bare image is a block; an emoji is inline.
            return !isEmoji(tag)
        case "a":
            // Only the lightbox flavour, which wraps a full-width image.
            return classList(tag).contains("lightbox")
        default:
            return false
        }
    }

    /// `<video>` without a `src` carries one or more `<source>` children.
    /// Consumes the element either way.
    private static func nestedVideoSource(
        _ tokens: [HTMLToken],
        index: inout Int,
        closing: String
    ) -> String? {
        var source: String?
        while index < tokens.count {
            switch tokens[index] {
            case .text:
                index += 1
            case .tag(let tag):
                if tag.isClosing, tag.name == closing {
                    index += 1
                    return source
                }
                if tag.name == "source", source == nil {
                    source = tag.attributes["src"]
                }
                index += 1
            }
        }
        return source
    }

    /// Pulls the `<img>` out of a lightbox anchor and skips the rest of its
    /// subtree, which is presentation chrome rather than content.
    private static func extractLightboxImage(
        _ tokens: [HTMLToken],
        index: inout Int,
        href: String?
    ) -> PostImage? {
        var image: PostImage?
        var depth = 1

        while index < tokens.count {
            switch tokens[index] {
            case .text:
                index += 1
            case .tag(let tag):
                if tag.isClosing {
                    if tag.name == "a" {
                        depth -= 1
                        index += 1
                        if depth == 0 { return image }
                        continue
                    }
                    index += 1
                    continue
                }
                if tag.name == "a" { depth += 1 }
                if tag.name == "img", image == nil, !isEmoji(tag) {
                    image = imageBlock(from: tag, href: href)
                }
                index += 1
            }
        }
        return image
    }

    /// Handles one block-level element. Returns multiple blocks when a wrapper
    /// (like `<div>`) contains several.
    private static func parseBlockElement(
        _ tag: HTMLTag,
        tokens: [HTMLToken],
        index: inout Int
    ) -> [PostBlock]? {
        let classes = classList(tag)

        switch tag.name {
        case "hr":
            return [.divider]

        case "img":
            return [.image(imageBlock(from: tag, href: nil))]

        case "br":
            return nil

        case "a":
            // `a.lightbox` wraps the thumbnail and carries the full-size href.
            // Its subtree also holds `.meta` chrome (filename, dimensions, an
            // SVG icon) that must not surface as text.
            let image = extractLightboxImage(tokens, index: &index, href: tag.attributes["href"])
            return image.map { [.image($0)] }

        case "video":
            // A bare `<video>` element, e.g. from raw HTML in a post.
            let source = tag.attributes["src"] ?? nestedVideoSource(tokens, index: &index, closing: "video")
            guard let source, !source.isEmpty else { return nil }
            return [.video(PostVideo(src: source, originalSrc: nil, posterSrc: tag.attributes["poster"]))]

        case "p", "div", "section", "article", "figure":
            // Discourse markers that change what the container means.
            if classes.contains("poll") {
                let name = tag.attributes["data-poll-name"] ?? "poll"
                skipSubtree(tokens, index: &index, name: tag.name)
                return [.pollPlaceholder(name: name)]
            }
            // How core cooks `![name|video](upload://…)`. The element is empty;
            // everything lives in its data attributes.
            if classes.contains("video-placeholder-container"),
               let source = tag.attributes["data-video-src"], !source.isEmpty {
                skipSubtree(tokens, index: &index, name: tag.name)
                return [.video(PostVideo(
                    src: source,
                    originalSrc: tag.attributes["data-orig-src"],
                    posterSrc: tag.attributes["data-thumbnail-src"]
                ))]
            }
            // `<div class="youtube-onebox lazy-video-container" data-video-id=…>`.
            // There is no iframe to find: Discourse ships a thumbnail and builds
            // the player in JS on click, so the embed address has to be
            // reconstructed from the data attributes. Parsing the children
            // instead would yield the bare thumbnail image and lose the video.
            if classes.contains("lazy-video-container") || classes.contains("youtube-onebox"),
               let embed = lazyVideoEmbed(from: tag) {
                skipSubtree(tokens, index: &index, name: tag.name)
                return [.embed(embed)]
            }
            if classes.contains("spoiler") || classes.contains("spoiled") {
                let inner = parseBlocks(tokens, index: &index, until: tag.name)
                return [.spoiler(inner)]
            }
            // The plugin's own header inside an unlocked block. Dropped:
            // `PostPermissionView` draws the frame's header from the
            // requirement, so keeping this would print the same words twice —
            // once as the frame's title and once as the first line of content.
            if classes.contains("permission-header") {
                skipSubtree(tokens, index: &index, name: tag.name)
                return nil
            }
            // discourse-permission, unlocked: the server already decided this
            // reader may see it and cooked the content inside
            // `<div class="permission-body">`. Framed anyway, so the reader can
            // tell the author had gated it — see `PostPermissionView`.
            if classes.contains("permission-content") {
                let requirement = permissionRequirement(from: tag)
                let buyers = permissionBuyersCount(tokens, from: index)
                let inner = parseBlocks(tokens, index: &index, until: tag.name)
                return [.permission(PostPermissionBlock(
                    requirement: requirement,
                    isUnlocked: true,
                    // The header sits inside the same container, so drop it —
                    // the view draws its own from `requirement`.
                    blocks: inner,
                    notice: "",
                    buyersCount: buyers
                ))]
            }
            // Locked — normalised from a `<span>` by
            // `promotePermissionPlaceholders`. The notice is the server's own
            // wording, already in the site's language and already carrying the
            // amount and buyer count the plugin chose to disclose.
            if classes.contains("permission-locked") {
                let requirement = permissionRequirement(from: tag)
                let notice = flattenedText(tokens, index: &index, closing: tag.name)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return [.permission(PostPermissionBlock(
                    requirement: requirement,
                    isUnlocked: false,
                    blocks: [],
                    notice: notice,
                    buyersCount: nil
                ))]
            }
            // The pay block whose amount exceeded the site maximum. Nothing to
            // reveal and nothing to buy; the server's message explains it.
            if classes.contains("permission-pay-error") {
                let text = flattenedText(tokens, index: &index, closing: tag.name)
                return [.permission(PostPermissionBlock(
                    requirement: .pay(amount: 0),
                    isUnlocked: false,
                    blocks: [],
                    notice: text,
                    buyersCount: nil
                ))]
            }
            let inner = parseBlocks(tokens, index: &index, until: tag.name)
            return inner.isEmpty ? nil : inner

        case "iframe":
            // TikTok and every other provider Discourse embeds directly. The
            // element used to fall through to the default branch, which parsed
            // its (empty) children and dropped the video without a trace.
            let source = tag.attributes["src"] ?? ""
            // `index` already sits past the opening tag here, so a self-closing
            // iframe needs no advance at all — only a paired one has a subtree
            // to discard.
            if !tag.isSelfClosing {
                skipSubtree(tokens, index: &index, name: "iframe")
            }
            guard !source.isEmpty, let embed = iframeEmbed(from: tag, source: source) else {
                return nil
            }
            return [.embed(embed)]

        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(tag.name.dropFirst()) ?? 1
            let inlines = parseInlinesUntil(tokens, index: &index, closing: tag.name)
            let trimmed = trimEdges(inlines)
            return trimmed.isEffectivelyEmpty ? nil : [.heading(level: level, trimmed)]

        case "pre":
            return [parseCodeBlock(tokens, index: &index)]

        case "blockquote":
            let inner = parseBlocks(tokens, index: &index, until: "blockquote")
            return inner.isEmpty ? nil : [.blockquote(inner)]

        case "aside":
            if classes.contains("quote") {
                return [.quote(parseQuote(tag, tokens: tokens, index: &index))]
            }
            if classes.contains("onebox") {
                return [.onebox(parseOnebox(tokens, index: &index, closing: "aside"))]
            }
            let inner = parseBlocks(tokens, index: &index, until: "aside")
            return inner.isEmpty ? nil : inner

        case "details":
            return [parseDetails(tokens, index: &index)]

        case "ul", "ol":
            return [parseList(ordered: tag.name == "ol", tokens: tokens, index: &index)]

        case "li":
            // A list item outside a list; treat its contents as loose blocks.
            let inner = parseBlocks(tokens, index: &index, until: "li")
            return inner.isEmpty ? nil : inner

        case "table":
            return [parseTable(tokens, index: &index)]

        default:
            let inner = parseBlocks(tokens, index: &index, until: tag.name)
            return inner.isEmpty ? nil : inner
        }
    }

    // MARK: Specific structures

    private static func parseCodeBlock(_ tokens: [HTMLToken], index: inout Int) -> PostBlock {
        var language: String?
        var code = ""

        while index < tokens.count {
            switch tokens[index] {
            case .text(let value):
                code += value
                index += 1
            case .tag(let tag):
                if tag.isClosing, tag.name == "pre" {
                    index += 1
                    return .codeBlock(language: language, code: trimTrailingNewlines(code))
                }
                if !tag.isClosing, tag.name == "code" {
                    // Discourse marks the language with `lang-swift`/`language-swift`.
                    language = classList(tag)
                        .first { $0.hasPrefix("lang-") || $0.hasPrefix("language-") }?
                        .replacingOccurrences(of: "language-", with: "")
                        .replacingOccurrences(of: "lang-", with: "")
                }
                if !tag.isClosing, tag.name == "br" { code += "\n" }
                index += 1
            }
        }
        return .codeBlock(language: language, code: trimTrailingNewlines(code))
    }

    private static func parseQuote(
        _ tag: HTMLTag,
        tokens: [HTMLToken],
        index: inout Int
    ) -> PostQuote {
        // Discourse puts the author on the aside itself and repeats it in a
        // `<div class="title">` header that also holds the avatar.
        var quote = PostQuote(
            username: tag.attributes["data-username"],
            avatarURL: nil,
            topicTitle: nil,
            blocks: []
        )
        var blocks: [PostBlock] = []
        var depth = 1

        while index < tokens.count {
            switch tokens[index] {
            case .text:
                // Loose text inside the aside chrome; the blockquote carries
                // the real content.
                index += 1

            case .tag(let inner):
                if inner.isClosing {
                    if inner.name == "aside" {
                        depth -= 1
                        index += 1
                        if depth == 0 {
                            quote.blocks = blocks
                            return quote
                        }
                        continue
                    }
                    index += 1
                    continue
                }

                if inner.name == "aside" { depth += 1 }

                let classes = classList(inner)
                if inner.name == "img", quote.avatarURL == nil, !isEmoji(inner) {
                    quote.avatarURL = inner.attributes["src"]
                    index += 1
                    continue
                }
                if inner.name == "blockquote" {
                    index += 1
                    blocks.append(contentsOf: parseBlocks(tokens, index: &index, until: "blockquote"))
                    continue
                }
                if inner.name == "a", classes.contains("badge-category") == false,
                   quote.topicTitle == nil,
                   inner.attributes["href"]?.contains("/t/") == true {
                    index += 1
                    let inlines = parseInlinesUntil(tokens, index: &index, closing: "a")
                    let title = inlines.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty { quote.topicTitle = title }
                    continue
                }
                index += 1
            }
        }

        quote.blocks = blocks
        return quote
    }

    /// Discourse's onebox markup is `<header class="source">` (favicon + site
    /// link) followed by `<article class="onebox-body">` holding an `<h3>` title
    /// and description paragraphs. The heading is the real title — the header
    /// link is just the domain — so the two regions are tracked separately.
    private static func parseOnebox(
        _ tokens: [HTMLToken],
        index: inout Int,
        closing: String
    ) -> PostOnebox {
        var onebox = PostOnebox()
        var depth = 1
        var bodyRuns: [String] = []
        var inHeading = false
        var inHeader = false

        while index < tokens.count {
            switch tokens[index] {
            case .text(let value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if inHeading {
                        onebox.title = (onebox.title ?? "") + trimmed
                    } else if !inHeader {
                        bodyRuns.append(trimmed)
                    }
                }
                index += 1

            case .tag(let tag):
                let classes = classList(tag)
                if tag.isClosing {
                    switch tag.name {
                    case closing:
                        depth -= 1
                        index += 1
                        if depth == 0 { return finishOnebox(onebox, bodyRuns: bodyRuns) }
                        continue
                    case "h1", "h2", "h3", "h4", "h5", "h6":
                        inHeading = false
                    case "header":
                        inHeader = false
                    default:
                        break
                    }
                    index += 1
                    continue
                }

                if tag.name == closing { depth += 1 }
                if tag.name == "header" || classes.contains("source") { inHeader = true }
                if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(tag.name) { inHeading = true }

                if tag.name == "a", onebox.url == nil {
                    onebox.url = tag.attributes["href"]
                }
                if tag.name == "img" {
                    if classes.contains("site-icon") || classes.contains("favicon") {
                        onebox.faviconURL = onebox.faviconURL ?? tag.attributes["src"]
                    } else if onebox.imageURL == nil, !isEmoji(tag) {
                        onebox.imageURL = tag.attributes["src"]
                    }
                }
                index += 1
            }
        }
        return finishOnebox(onebox, bodyRuns: bodyRuns)
    }

    private static func finishOnebox(_ onebox: PostOnebox, bodyRuns: [String]) -> PostOnebox {
        var result = onebox
        if result.title == nil { result.title = bodyRuns.first }
        let description = result.title == bodyRuns.first ? Array(bodyRuns.dropFirst()) : bodyRuns
        if result.descriptionText == nil, !description.isEmpty {
            result.descriptionText = description.joined(separator: " ")
        }
        return result
    }

    private static func parseDetails(_ tokens: [HTMLToken], index: inout Int) -> PostBlock {
        var summary: [PostInline] = []
        var blocks: [PostBlock] = []
        var pendingInlines: [PostInline] = []

        func flushInlines() {
            let trimmed = trimEdges(pendingInlines)
            if !trimmed.isEffectivelyEmpty { blocks.append(.paragraph(trimmed)) }
            pendingInlines = []
        }

        while index < tokens.count {
            switch tokens[index] {
            case .text(let value):
                pendingInlines.append(.text(value))
                index += 1

            case .tag(let tag):
                if tag.isClosing, tag.name == "details" {
                    index += 1
                    flushInlines()
                    return .details(summary: summary, blocks: blocks)
                }
                if tag.isClosing {
                    index += 1
                    continue
                }
                if tag.name == "summary" {
                    index += 1
                    summary = trimEdges(parseInlinesUntil(tokens, index: &index, closing: "summary"))
                    continue
                }
                if droppedElements.contains(tag.name) {
                    index += 1
                    if !tag.isSelfClosing { skipSubtree(tokens, index: &index, name: tag.name) }
                    continue
                }
                if isBlockLevel(tag) {
                    flushInlines()
                    index += 1
                    if let inner = parseBlockElement(tag, tokens: tokens, index: &index) {
                        blocks.append(contentsOf: inner)
                    }
                } else {
                    pendingInlines.append(contentsOf: parseInlineElement(tag, tokens: tokens, index: &index))
                }
            }
        }

        flushInlines()
        return .details(summary: summary, blocks: blocks)
    }

    private static func parseList(
        ordered: Bool,
        tokens: [HTMLToken],
        index: inout Int
    ) -> PostBlock {
        var items: [[PostBlock]] = []
        let listTag = ordered ? "ol" : "ul"

        while index < tokens.count {
            switch tokens[index] {
            case .text:
                index += 1
            case .tag(let tag):
                if tag.isClosing, tag.name == listTag {
                    index += 1
                    return .list(ordered: ordered, items: items)
                }
                if tag.isClosing {
                    index += 1
                    continue
                }
                if tag.name == "li" {
                    index += 1
                    items.append(parseBlocks(tokens, index: &index, until: "li"))
                    continue
                }
                index += 1
            }
        }
        return .list(ordered: ordered, items: items)
    }

    private static func parseTable(_ tokens: [HTMLToken], index: inout Int) -> PostBlock {
        var headers: [[PostInline]] = []
        var rows: [[[PostInline]]] = []
        var currentRow: [[PostInline]] = []
        var rowIsHeader = false

        while index < tokens.count {
            switch tokens[index] {
            case .text:
                index += 1
            case .tag(let tag):
                if tag.isClosing {
                    if tag.name == "table" {
                        index += 1
                        if !currentRow.isEmpty { rows.append(currentRow) }
                        return .table(headers: headers, rows: rows)
                    }
                    if tag.name == "tr" {
                        if rowIsHeader {
                            headers = currentRow
                        } else if !currentRow.isEmpty {
                            rows.append(currentRow)
                        }
                        currentRow = []
                        rowIsHeader = false
                    }
                    index += 1
                    continue
                }
                if tag.name == "tr" {
                    currentRow = []
                    rowIsHeader = false
                    index += 1
                    continue
                }
                if tag.name == "th" || tag.name == "td" {
                    if tag.name == "th" { rowIsHeader = true }
                    index += 1
                    currentRow.append(trimEdges(parseInlinesUntil(tokens, index: &index, closing: tag.name)))
                    continue
                }
                index += 1
            }
        }

        if !currentRow.isEmpty { rows.append(currentRow) }
        return .table(headers: headers, rows: rows)
    }

    // MARK: Inline assembly

    private static func parseInlinesUntil(
        _ tokens: [HTMLToken],
        index: inout Int,
        closing: String
    ) -> [PostInline] {
        guard nestingDepth < maxNestingDepth else {
            return [.text(flattenedText(tokens, index: &index, closing: closing))]
        }
        return $nestingDepth.withValue(nestingDepth + 1) {
            parseInlinesUntilBody(tokens, index: &index, closing: closing)
        }
    }

    private static func parseInlinesUntilBody(
        _ tokens: [HTMLToken],
        index: inout Int,
        closing: String
    ) -> [PostInline] {
        var inlines: [PostInline] = []

        while index < tokens.count {
            switch tokens[index] {
            case .text(let value):
                inlines.append(.text(value))
                index += 1
            case .tag(let tag):
                if tag.isClosing {
                    index += 1
                    if tag.name == closing { return inlines }
                    continue
                }
                if droppedElements.contains(tag.name) {
                    index += 1
                    if !tag.isSelfClosing { skipSubtree(tokens, index: &index, name: tag.name) }
                    continue
                }
                inlines.append(contentsOf: parseInlineElement(tag, tokens: tokens, index: &index))
            }
        }
        return inlines
    }

    private static func parseInlineElement(
        _ tag: HTMLTag,
        tokens: [HTMLToken],
        index: inout Int
    ) -> [PostInline] {
        let classes = classList(tag)

        switch tag.name {
        case "br":
            index += 1
            return [.lineBreak]

        case "img":
            index += 1
            if isEmoji(tag) {
                let shortcode = tag.attributes["alt"] ?? tag.attributes["title"] ?? ""
                return [.emoji(url: tag.attributes["src"] ?? "", shortcode: shortcode)]
            }
            // A non-emoji image reached inline (e.g. inside a link); keep its
            // alt text so the sentence still reads.
            return tag.attributes["alt"].map { [.text($0)] } ?? []

        case "a":
            index += 1
            let children = parseInlinesUntil(tokens, index: &index, closing: "a")
            let href = tag.attributes["href"] ?? ""
            if classes.contains("mention") {
                let username = children.plainText.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
                guard !username.isEmpty else { return children }
                return [.reference(PostReference(
                    kind: .user,
                    // The href is authoritative for the slug: the label carries
                    // display casing (`@James`) that `/u/james` does not.
                    slug: Self.mentionSlug(fromHref: href) ?? username,
                    label: username,
                    href: href.isEmpty ? "/u/\(username)" : href
                ))]
            }
            if classes.contains("hashtag-cooked") || classes.contains("hashtag") {
                if let reference = Self.hashtagReference(tag: tag, href: href, children: children) {
                    return [reference]
                }
            }
            if children.isEffectivelyEmpty { return [] }
            return href.isEmpty ? children : [.link(href: href, children: children)]

        case "strong", "b":
            index += 1
            return styled(parseInlinesUntil(tokens, index: &index, closing: tag.name), adding: .bold)

        case "em", "i":
            index += 1
            return styled(parseInlinesUntil(tokens, index: &index, closing: tag.name), adding: .italic)

        case "del", "s", "strike":
            index += 1
            return styled(parseInlinesUntil(tokens, index: &index, closing: tag.name), adding: .strikethrough)

        case "code":
            index += 1
            return styled(parseInlinesUntil(tokens, index: &index, closing: "code"), adding: .code)

        case "span":
            index += 1
            let children = parseInlinesUntil(tokens, index: &index, closing: "span")
            if classes.contains("spoiler") || classes.contains("spoiled") {
                // Inline spoilers are rendered as a redacted run; represent them
                // as styled text so they survive into the attributed string.
                return styled(children, adding: .code)
            }
            return children

        default:
            index += 1
            if tag.isSelfClosing { return [] }
            return parseInlinesUntil(tokens, index: &index, closing: tag.name)
        }
    }

    private static func styled(_ inlines: [PostInline], adding style: PostTextStyle) -> [PostInline] {
        inlines.map { inline in
            switch inline {
            case .text(let value):
                return .styled(value, style)
            case .styled(let value, let existing):
                return .styled(value, existing.union(style))
            case .link(let href, let children):
                return .link(href: href, children: styled(children, adding: style))
            default:
                return inline
            }
        }
    }

    // MARK: Embeds

    /// Rebuilds a YouTube embed from the lazy container's data attributes.
    ///
    /// Only YouTube is reconstructed by hand, because it is the only provider
    /// that cooks *without* a src. Anything else arriving in this shape without
    /// a recognisable id is left alone rather than guessed at.
    private static func lazyVideoEmbed(from tag: HTMLTag) -> PostEmbed? {
        guard let videoID = tag.attributes["data-video-id"], !videoID.isEmpty else {
            return nil
        }
        let provider = tag.attributes["data-provider-name"]?.lowercased() ?? "youtube"
        guard provider == "youtube" else { return nil }

        var embedURL = "https://www.youtube.com/embed/\(videoID)?playsinline=1"
        // Discourse keeps the `?t=` a reader linked with; honour it.
        if let start = tag.attributes["data-video-start-time"], !start.isEmpty, Int(start) != nil {
            embedURL += "&start=\(start)"
        }
        if let list = tag.attributes["data-video-list-id"], !list.isEmpty {
            embedURL += "&list=\(list)"
        }

        return PostEmbed(
            embedURL: embedURL,
            pageURL: "https://www.youtube.com/watch?v=\(videoID)",
            provider: "YouTube",
            title: tag.attributes["data-video-title"].flatMap { $0.isEmpty ? nil : $0 },
            thumbnailURL: "https://img.youtube.com/vi/\(videoID)/hqdefault.jpg"
        )
    }

    /// A provider Discourse embedded directly, e.g.
    /// `<iframe class="tiktok-onebox" src="https://www.tiktok.com/embed/v2/…">`.
    private static func iframeEmbed(from tag: HTMLTag, source: String) -> PostEmbed? {
        let url = URL(string: source)
        let host = url?.host?.replacingOccurrences(of: "www.", with: "")
        // `class="tiktok-onebox"` names the provider more precisely than the
        // host of an embed subdomain would.
        let fromClass = (tag.attributes["class"] ?? "")
            .split(separator: " ")
            .first { $0.hasSuffix("-onebox") }
            .map { $0.replacingOccurrences(of: "-onebox", with: "") }

        return PostEmbed(
            embedURL: source,
            // An embed address is not something to hand a reader as "open in
            // browser"; only use it when it is clearly the watch page too.
            pageURL: nil,
            provider: providerDisplayName(fromClass ?? host),
            title: tag.attributes["title"].flatMap { $0.isEmpty ? nil : $0 },
            thumbnailURL: nil,
            aspectRatio: embedAspectRatio(tag: tag, provider: fromClass ?? host ?? "")
        )
    }

    /// House styling for the names readers recognise; anything else is just
    /// capitalised, which is right for a bare host.
    private static func providerDisplayName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased().replacingOccurrences(of: ".com", with: "") {
        case "tiktok": return "TikTok"
        case "youtube", "youtu.be": return "YouTube"
        case "bilibili": return "Bilibili"
        case "twitter", "x": return "X"
        case "vimeo": return "Vimeo"
        default: return raw.capitalized
        }
    }

    /// Declared dimensions when the markup has them, else a per-provider guess.
    /// TikTok is portrait and would be badly letterboxed at 16:9.
    private static func embedAspectRatio(tag: HTMLTag, provider: String) -> CGFloat {
        if let width = tag.attributes["width"].flatMap(Double.init),
           let height = tag.attributes["height"].flatMap(Double.init),
           width > 0, height > 0 {
            return CGFloat(width / height)
        }
        return provider.contains("tiktok") ? 9 / 16 : 16 / 9
    }

    // MARK: Helpers

    /// Slug out of `/u/{username}`, ignoring anything deeper.
    private static func mentionSlug(fromHref href: String) -> String? {
        let segments = href.split(separator: "/").map(String.init)
        guard let index = segments.firstIndex(of: "u"), index + 1 < segments.count else {
            return nil
        }
        let slug = segments[index + 1]
        return slug.isEmpty ? nil : slug
    }

    /// `<a class="hashtag-cooked" href="/tag/aff/39" data-type="tag"
    /// data-slug="AFF">…<span>AFF</span></a>`, and the `data-type="category"`
    /// variant pointing at `/c/{slug}/{id}`.
    ///
    /// The label comes from the children rather than `data-slug` so it keeps the
    /// author's casing. Those children also hold an icon placeholder —
    /// `<span class="hashtag-icon-placeholder"><svg><use/></svg></span>` — which
    /// contributes no text, so flattening them is enough to isolate the name.
    private static func hashtagReference(
        tag: HTMLTag,
        href: String,
        children: [PostInline]
    ) -> PostInline? {
        let kind: PostReference.Kind = tag.attributes["data-type"] == "category" ? .node : .tag
        let dataSlug = tag.attributes["data-slug"]
        let flattened = children.plainText.trimmingCharacters(in: CharacterSet(charactersIn: "# \n\t"))
        // Prefer the href's slug: it is the lowercased, route-ready form.
        let slug = hashtagSlug(fromHref: href, kind: kind) ?? dataSlug ?? flattened
        let label = flattened.isEmpty ? (dataSlug ?? slug) : flattened

        guard !slug.isEmpty, !label.isEmpty else { return nil }
        return .reference(PostReference(kind: kind, slug: slug, label: label, href: href))
    }

    /// `/tag/{slug}/{id}` or `/c/{slug}/{id}` — the slug is the last segment
    /// that isn't the trailing numeric id.
    private static func hashtagSlug(fromHref href: String, kind: PostReference.Kind) -> String? {
        let segments = href.split(separator: "/").map(String.init)
        let marker = kind == .node ? "c" : "tag"
        guard let index = segments.firstIndex(of: marker) else { return nil }
        let rest = segments[segments.index(after: index)...].filter { Int($0) == nil }
        return rest.last
    }

    private static func imageBlock(from tag: HTMLTag, href: String?) -> PostImage {
        PostImage(
            src: tag.attributes["src"] ?? "",
            href: href ?? tag.attributes["data-download-href"],
            alt: tag.attributes["alt"],
            width: tag.attributes["width"].flatMap { Int($0) },
            height: tag.attributes["height"].flatMap { Int($0) }
        )
    }

    private static func classList(_ tag: HTMLTag) -> [String] {
        (tag.attributes["class"] ?? "")
            .split(separator: " ")
            .map { String($0).lowercased() }
    }

    private static func isEmoji(_ tag: HTMLTag) -> Bool {
        classList(tag).contains { $0 == "emoji" || $0.hasPrefix("emoji-") }
    }

    /// Advances past the matching close tag, honouring nesting.
    private static func skipSubtree(_ tokens: [HTMLToken], index: inout Int, name: String) {
        var depth = 1
        while index < tokens.count {
            if case .tag(let tag) = tokens[index] {
                if tag.name == name, !tag.isSelfClosing {
                    depth += tag.isClosing ? -1 : 1
                    if depth == 0 {
                        index += 1
                        return
                    }
                }
            }
            index += 1
        }
    }

    private static func trimEdges(_ inlines: [PostInline]) -> [PostInline] {
        var result = inlines

        while let first = result.first {
            if case .text(let value) = first, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.removeFirst()
            } else if case .lineBreak = first {
                result.removeFirst()
            } else {
                break
            }
        }
        while let last = result.last {
            if case .text(let value) = last, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.removeLast()
            } else if case .lineBreak = last {
                result.removeLast()
            } else {
                break
            }
        }

        // Collapse the newlines Discourse leaves between tags; they are source
        // formatting, not content.
        return result.map { inline in
            if case .text(let value) = inline {
                return .text(value.replacingOccurrences(of: "\n", with: " "))
            }
            return inline
        }
    }

    private static func trimTrailingNewlines(_ code: String) -> String {
        var result = code
        while result.hasSuffix("\n") || result.hasSuffix("\r") { result.removeLast() }
        while result.hasPrefix("\n") || result.hasPrefix("\r") { result.removeFirst() }
        return result
    }

    /// Drops empty paragraphs and merges adjacent dividers.
    private static func normalize(_ blocks: [PostBlock]) -> [PostBlock] {
        var result: [PostBlock] = []
        for block in blocks {
            if case .paragraph(let inlines) = block, inlines.isEffectivelyEmpty { continue }
            if case .divider = block, case .divider = result.last { continue }
            result.append(block)
        }
        return result
    }

    // MARK: Entities

    private static let namedEntities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
        "&apos;": "'", "&hellip;": "…", "&nbsp;": "\u{00A0}", "&mdash;": "—",
        "&ndash;": "–", "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}",
        "&lsquo;": "\u{2018}", "&rsquo;": "\u{2019}", "&middot;": "·",
        "&times;": "×", "&copy;": "©", "&reg;": "®", "&trade;": "™",
    ]

    /// Named plus numeric (decimal and hex) entities. Mirrors the decoder used
    /// for chat messages in `Stores.swift`, extended with a few more names.
    static func decodeEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        var text = value
        for (entity, replacement) in namedEntities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        guard text.contains("&#") else { return text }

        var result = ""
        var remainder = Substring(text)
        while let start = remainder.range(of: "&#") {
            result += remainder[remainder.startIndex..<start.lowerBound]
            let afterMarker = remainder[start.upperBound...]
            guard let semicolon = afterMarker.firstIndex(of: ";") else {
                result += remainder[start.lowerBound...]
                return result
            }
            let digits = afterMarker[afterMarker.startIndex..<semicolon]
            let isHex = digits.first == "x" || digits.first == "X"
            let number = isHex ? digits.dropFirst() : digits
            if let code = UInt32(number, radix: isHex ? 16 : 10),
               let scalar = UnicodeScalar(code) {
                result.append(Character(scalar))
            } else {
                result += remainder[start.lowerBound...semicolon]
            }
            remainder = afterMarker[afterMarker.index(after: semicolon)...]
        }
        result += remainder
        return result
    }
}
