//
//  PostReferenceTextView.swift
//  nodeloc
//
//  Inline `@user` / `#node` / `#tag` badges, and the TextKit view that hosts
//  them.
//
//  Why TextKit and not SwiftUI. A capsule — padding, rounded corners, a leading
//  glyph — is not expressible in an `AttributedString`, which offers a flat
//  `backgroundColor` and nothing else. The obvious alternative, a wrapping
//  `Layout` of real SwiftUI views, flows *children*: to seat a badge mid
//  sentence the surrounding prose has to be split into pieces small enough to
//  flow around it. That works in English, where the split is on spaces, and
//  fails in Chinese, which has none — a whole sentence becomes one child, wraps
//  as a block, and the badge can only land before or after it. Splitting per
//  character would flow, at the cost of hundreds of views per paragraph and of
//  the CJK line-break rules (禁则 — 。，）must not open a line) that TextKit
//  applies for free. An `NSTextAttachment` gets a real capsule *and* keeps
//  Chinese typography correct, which is why the renderer here is UIKit.
//
//  Only runs that actually contain a reference come through here; everything
//  else keeps the cheaper single-`Text` path in `PostInlineRenderer`.
//

import SwiftUI
import UIKit

// MARK: - Colour

extension PostReference {
    /// One tint per kind, so the three read apart at a glance without needing
    /// the glyph. Drawn from the existing palette rather than new hues: a post
    /// body can hold several of these in one paragraph and off-brand colours
    /// would turn it into confetti.
    ///
    /// People get the brand green (they are the primary thing a post points
    /// at), nodes the secondary orange, and tags the neutral ramp — tags are
    /// loose metadata, and grey says that without competing for attention.
    var tint: Color {
        switch kind {
        case .user: Theme.accent
        case .node: Theme.accent2
        case .tag: Theme.neutral700
        }
    }
}

// MARK: - Badge bitmap

/// Rasterises a reference badge for use as a text attachment.
@MainActor
enum PostReferenceBadge {
    /// Keyed by everything that changes the pixels. A long thread repeats the
    /// same `@user` many times and each miss is a full rasterisation.
    private struct Key: Hashable {
        let symbol: String
        let label: String
        let fontSize: CGFloat
        let isDark: Bool
    }

    private static var cache: [Key: UIImage] = [:]
    /// Labels repeat heavily inside a thread, so the cache earns its keep long
    /// before this; the cap is only here so a long session of distinct tags
    /// can't grow it without bound. Dropping everything is fine — a miss is one
    /// small rasterisation.
    private static let cacheLimit = 256

    static func image(for reference: PostReference, fontSize: CGFloat, isDark: Bool) -> UIImage {
        let key = Key(
            symbol: reference.symbolName,
            label: reference.label,
            fontSize: fontSize,
            isDark: isDark
        )
        if let hit = cache[key] { return hit }
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        let image = render(reference, fontSize: fontSize, isDark: isDark)
        // VoiceOver would otherwise announce the capsule as an unlabelled
        // attachment; the image carries the label since the attributed string
        // has no key for one on UIKit.
        image.accessibilityLabel = reference.textPrefix + reference.label
        cache[key] = image
        return image
    }

    /// Font the badge label is drawn in, and the metric the attachment's
    /// baseline offset is derived from.
    static func labelFont(fontSize: CGFloat) -> UIFont {
        .systemFont(ofSize: max(10, fontSize - 1), weight: .semibold)
    }

    private static let horizontalPadding: CGFloat = 6
    private static let verticalPadding: CGFloat = 2
    private static let glyphGap: CGFloat = 2

    private static func render(
        _ reference: PostReference,
        fontSize: CGFloat,
        isDark: Bool
    ) -> UIImage {
        let traits = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        let tint = UIColor(reference.tint).resolvedColor(with: traits)
        // A wash of the badge's own tint rather than a palette token like
        // `accent100`: those are near-white in dark mode and would read as a
        // highlighter pen, and deriving it keeps all three kinds consistent.
        let fill = tint.withAlphaComponent(isDark ? 0.22 : 0.12)

        let font = labelFont(fontSize: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint]
        let label = NSAttributedString(string: reference.label, attributes: attributes)
        let labelSize = label.size()

        let glyphConfig = UIImage.SymbolConfiguration(
            pointSize: max(8, fontSize - 3),
            weight: .semibold
        )
        let glyph = UIImage(systemName: reference.symbolName, withConfiguration: glyphConfig)?
            .withTintColor(tint, renderingMode: .alwaysOriginal)
        let glyphSize = glyph?.size ?? .zero

        let contentWidth = glyphSize.width + (glyphSize.width > 0 ? glyphGap : 0) + labelSize.width
        let size = CGSize(
            width: (horizontalPadding * 2 + contentWidth).rounded(.up),
            height: (max(labelSize.height, glyphSize.height) + verticalPadding * 2).rounded(.up)
        )

        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { _ in
            let bounds = CGRect(origin: .zero, size: size)
            UIBezierPath(roundedRect: bounds, cornerRadius: size.height / 2).addClip()
            fill.setFill()
            UIRectFill(bounds)

            var x = horizontalPadding
            if let glyph {
                glyph.draw(in: CGRect(
                    x: x,
                    y: ((size.height - glyphSize.height) / 2).rounded(),
                    width: glyphSize.width,
                    height: glyphSize.height
                ))
                x += glyphSize.width + glyphGap
            }
            label.draw(at: CGPoint(x: x, y: ((size.height - labelSize.height) / 2).rounded()))
        }
    }
}

// MARK: - Attributed string

/// Builds the UIKit attributed string for a run of inlines, badges included.
@MainActor
enum PostReferenceAttributedBuilder {
    /// Prefix on `NSAttributedString.Key.textItemTag`, so a badge tap is
    /// distinguishable from an ordinary link tap without parsing a URL.
    static let tagPrefix = "nodeloc.reference:"

    static func attributedString(
        for inlines: [PostInline],
        metrics: PostTextMetrics,
        isDark: Bool,
        emoji: EmojiImageStore
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let traits = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        let textColor = UIColor(Theme.text)
            .resolvedColor(with: traits)
            .withAlphaComponent(metrics.textOpacity)
        let accent = UIColor(Theme.accent).resolvedColor(with: traits)

        append(
            inlines,
            into: result,
            metrics: metrics,
            isDark: isDark,
            textColor: textColor,
            accent: accent,
            emoji: emoji,
            inheritedLink: nil
        )

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = metrics.lineSpacing
        // `.byWordWrapping` is right for Chinese too, and is the whole reason
        // this renderer exists: TextKit breaks on Unicode line-break
        // opportunities (UAX #14), which exist between Han characters, and it
        // applies the CJK rules about which characters may not open or close a
        // line. `.byCharWrapping` would break anywhere and lose that.
        paragraph.lineBreakMode = .byWordWrapping
        result.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    private static func append(
        _ inlines: [PostInline],
        into result: NSMutableAttributedString,
        metrics: PostTextMetrics,
        isDark: Bool,
        textColor: UIColor,
        accent: UIColor,
        emoji: EmojiImageStore,
        inheritedLink: String?
    ) {
        for inline in inlines {
            switch inline {
            case .text(let value):
                result.append(NSAttributedString(string: value, attributes: [
                    .font: Theme.uiBody(metrics.bodySize),
                    .foregroundColor: inheritedLink == nil ? textColor : accent,
                ].merging(linkAttributes(inheritedLink)) { current, _ in current }))

            case .styled(let value, let style):
                result.append(NSAttributedString(
                    string: value,
                    attributes: styledAttributes(
                        style,
                        metrics: metrics,
                        isDark: isDark,
                        textColor: inheritedLink == nil ? textColor : accent,
                        link: inheritedLink
                    )
                ))

            case .link(let href, let children):
                append(
                    children,
                    into: result,
                    metrics: metrics,
                    isDark: isDark,
                    textColor: textColor,
                    accent: accent,
                    emoji: emoji,
                    // Nested links can't exist in cooked HTML; the outermost
                    // href wins if one ever does.
                    inheritedLink: inheritedLink ?? href
                )

            case .reference(let reference):
                result.append(badgeAttachment(reference, metrics: metrics, isDark: isDark))

            case .emoji(let url, let shortcode):
                // The TextKit path can host emoji as attachments too, which is
                // strictly better than the shortcode fallback the `Text` path
                // has to use while an image loads.
                if let image = emoji.image(for: url, pointSize: metrics.bodySize) {
                    result.append(imageAttachment(image, fontSize: metrics.bodySize))
                } else {
                    emoji.loadIfNeeded(url)
                    result.append(NSAttributedString(string: shortcode, attributes: [
                        .font: Theme.uiBody(metrics.bodySize),
                        .foregroundColor: textColor.withAlphaComponent(0.5),
                    ]))
                }

            case .lineBreak:
                result.append(NSAttributedString(string: "\n"))
            }
        }
    }

    private static func linkAttributes(_ href: String?) -> [NSAttributedString.Key: Any] {
        guard let href, let url = PostInlineRenderer.resolvedLink(href) else { return [:] }
        return [.link: url]
    }

    private static func styledAttributes(
        _ style: PostTextStyle,
        metrics: PostTextMetrics,
        isDark: Bool,
        textColor: UIColor,
        link: String?
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: textColor]

        if style.contains(.code) {
            attributes[.font] = UIFont.monospacedSystemFont(
                ofSize: Theme.scaledSize(metrics.bodySize) - 1,
                weight: .regular
            )
            attributes[.backgroundColor] = UIColor(Theme.hover)
                .resolvedColor(with: UITraitCollection(userInterfaceStyle: isDark ? .dark : .light))
        } else {
            var font = Theme.uiBody(metrics.bodySize)
            var symbolic: UIFontDescriptor.SymbolicTraits = []
            if style.contains(.bold) { symbolic.insert(.traitBold) }
            if style.contains(.italic) { symbolic.insert(.traitItalic) }
            if !symbolic.isEmpty,
               let descriptor = font.fontDescriptor.withSymbolicTraits(symbolic) {
                font = UIFont(descriptor: descriptor, size: font.pointSize)
            }
            attributes[.font] = font
        }

        if style.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes.merging(linkAttributes(link)) { current, _ in current }
    }

    /// The badge, plus the tag that turns it into a tappable text item.
    private static func badgeAttachment(
        _ reference: PostReference,
        metrics: PostTextMetrics,
        isDark: Bool
    ) -> NSAttributedString {
        let image = PostReferenceBadge.image(
            for: reference,
            fontSize: Theme.scaledSize(metrics.bodySize),
            isDark: isDark
        )
        let attributed = NSMutableAttributedString(
            attributedString: imageAttachment(image, fontSize: metrics.bodySize)
        )
        let range = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(.textItemTag, value: tag(for: reference), range: range)
        return attributed
    }

    private static func imageAttachment(_ image: UIImage, fontSize: CGFloat) -> NSAttributedString {
        let attachment = NSTextAttachment(image: image)
        let font = Theme.uiBody(fontSize)
        // Attachments sit on the baseline by default, which leaves a capsule
        // hanging below the line. Centring on cap height puts it where a reader
        // expects an inline chip — and does the same favour for emoji.
        attachment.bounds = CGRect(
            x: 0,
            y: ((font.capHeight - image.size.height) / 2).rounded(),
            width: image.size.width,
            height: image.size.height
        )
        return NSAttributedString(attachment: attachment)
    }

    static func tag(for reference: PostReference) -> String {
        "\(tagPrefix)\(kindToken(reference.kind))|\(reference.slug)|\(reference.label)|\(reference.href)"
    }

    /// Rebuilds the reference a tap arrived on. The tag carries everything
    /// needed, so the view doesn't have to hold a lookup table keyed by range.
    static func reference(fromTag tag: String) -> PostReference? {
        guard tag.hasPrefix(tagPrefix) else { return nil }
        let parts = tag.dropFirst(tagPrefix.count).split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, let kind = kind(fromToken: String(parts[0])) else { return nil }
        return PostReference(
            kind: kind,
            slug: String(parts[1]),
            label: String(parts[2]),
            href: String(parts[3])
        )
    }

    private static func kindToken(_ kind: PostReference.Kind) -> String {
        switch kind {
        case .user: "user"
        case .node: "node"
        case .tag: "tag"
        }
    }

    private static func kind(fromToken token: String) -> PostReference.Kind? {
        switch token {
        case "user": .user
        case "node": .node
        case "tag": .tag
        default: nil
        }
    }
}

// MARK: - View

/// A paragraph that contains at least one reference badge.
struct PostReferenceTextView: UIViewRepresentable {
    let inlines: [PostInline]
    let metrics: PostTextMetrics
    let onTapReference: (PostReference) -> Void
    let onTapLink: (URL) -> Void
    /// A tap inside this paragraph that hit neither a badge nor a link. The
    /// text view swallows its own touches, so the reply's collapse action has
    /// to be handed back rather than left to an ancestor gesture.
    var onTapBackground: () -> Void = {}

    @Environment(EmojiImageStore.self) private var emoji
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.isEditable = false
        // Selectable is required for text items to receive taps at all; the
        // gestures that would start a selection are suppressed below.
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        // Nothing here should look tappable except the badges and real links,
        // and an underline on every link fights the app's flat styling.
        view.linkTextAttributes = [
            .foregroundColor: UIColor(Theme.accent),
            .underlineStyle: 0,
        ]
        // A post body is not a text field: no caret, no magnifier, no drag.
        view.tintColor = .clear

        // Belt and braces alongside the delegate. Whether UIKit raises a text
        // item for an attachment range is not something the docs commit to, and
        // badges were dead on arrival, so this resolves the tap from the
        // attributed string directly. Both paths firing is harmless: each ends
        // in the same assignment.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onTapReference = onTapReference
        context.coordinator.onTapLink = onTapLink
        context.coordinator.onTapBackground = onTapBackground
        view.attributedText = PostReferenceAttributedBuilder.attributedString(
            for: inlines,
            metrics: metrics,
            isDark: colorScheme == .dark,
            emoji: emoji
        )
    }

    /// `isScrollEnabled = false` makes the view self-size, but SwiftUI still
    /// needs the height for the proposed width — without this the paragraph
    /// collapses or overruns inside the post's scroll view.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0, width.isFinite else { return nil }
        let fitted = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: ceil(fitted.height))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onTapReference: onTapReference,
            onTapLink: onTapLink,
            onTapBackground: onTapBackground
        )
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var onTapReference: (PostReference) -> Void
        var onTapLink: (URL) -> Void
        var onTapBackground: () -> Void

        init(
            onTapReference: @escaping (PostReference) -> Void,
            onTapLink: @escaping (URL) -> Void,
            onTapBackground: @escaping () -> Void
        ) {
            self.onTapReference = onTapReference
            self.onTapLink = onTapLink
            self.onTapBackground = onTapBackground
        }

        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            #if DEBUG
            print("[PostReference] text item \(textItem.content) at \(textItem.range)")
            #endif

            // A badge range holds an attachment *and* a tag, and UIKit may
            // report either as the item's content — an attachment classified as
            // `.textAttachment` used to fall through and return nil, which is
            // why badges appeared dead. Reading the tag off the range settles
            // it without depending on that classification.
            if let reference = reference(in: textView, at: textItem.range) {
                return UIAction { [onTapReference] _ in onTapReference(reference) }
            }

            switch textItem.content {
            case .link(let url):
                return UIAction { [onTapLink] _ in onTapLink(url) }
            default:
                // Suppresses the system menu on a plain attachment (emoji).
                return nil
            }
        }

        /// Resolves a tap straight from the attributed string, independent of
        /// UIKit's text-item machinery.
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView = gesture.view as? UITextView else { return }
            let point = gesture.location(in: textView)

            if let target = target(in: textView, at: point) {
                switch target {
                case .reference(let reference): onTapReference(reference)
                case .link(let url): onTapLink(url)
                }
                return
            }

            // Plain text, or the margin past the end of a line. The text view
            // consumed the touch, so the collapse has to be reported from here
            // or tapping a paragraph with a badge in it would do nothing.
            onTapBackground()
        }

        private enum TapTarget {
            case reference(PostReference)
            case link(URL)
        }

        private func target(in textView: UITextView, at point: CGPoint) -> TapTarget? {
            guard let attributed = textView.attributedText else { return nil }

            // Badges are matched on their own rect, not on the nearest
            // insertion point. A badge is a *single* attachment character, so
            // its insertion points sit at the capsule's two edges: a tap past
            // the halfway mark is nearer the one belonging to the *following*
            // character, which is why only a sliver at the left edge used to
            // respond. Testing the drawn rect makes the whole capsule live.
            if let reference = badge(in: textView, attributed: attributed, at: point) {
                return .reference(reference)
            }

            // Links are ordinary text. Glyphs there are narrow enough that the
            // nearest insertion point is reliably inside the run.
            guard let position = textView.closestPosition(to: point) else { return nil }
            let index = textView.offset(from: textView.beginningOfDocument, to: position)
            guard index >= 0, index < attributed.length,
                  let url = attributed.attribute(.link, at: index, effectiveRange: nil) as? URL,
                  hitsGlyph(in: textView, at: position, point: point)
            else { return nil }
            return .link(url)
        }

        /// The badge whose drawn rect contains `point`, if any.
        private func badge(
            in textView: UITextView,
            attributed: NSAttributedString,
            at point: CGPoint
        ) -> PostReference? {
            var found: PostReference?
            attributed.enumerateAttribute(
                .textItemTag,
                in: NSRange(location: 0, length: attributed.length)
            ) { value, range, stop in
                guard let tag = value as? String,
                      let reference = PostReferenceAttributedBuilder.reference(fromTag: tag),
                      let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                      let end = textView.position(from: start, offset: range.length),
                      let textRange = textView.textRange(from: start, to: end)
                else { return }

                // `selectionRects` rather than `firstRect`, which would only
                // describe the first line a range occupies. A badge never
                // wraps, but this is exact for free.
                let hit = textView.selectionRects(for: textRange).contains { selection in
                    !selection.rect.isEmpty
                        && selection.rect.insetBy(dx: -4, dy: -4).contains(point)
                }
                if hit {
                    found = reference
                    stop.pointee = true
                }
            }
            return found
        }

        /// Whether the tap actually landed on the character at `position`.
        /// `closestPosition` answers for a tap anywhere, including well past the
        /// end of a line.
        private func hitsGlyph(
            in textView: UITextView,
            at position: UITextPosition,
            point: CGPoint
        ) -> Bool {
            guard let end = textView.position(from: position, offset: 1),
                  let characterRange = textView.textRange(from: position, to: end)
            else { return true }
            let rect = textView.firstRect(for: characterRange)
            return !rect.isNull && rect.insetBy(dx: -4, dy: -4).contains(point)
        }

        private func reference(in textView: UITextView, at range: NSRange) -> PostReference? {
            guard let attributed = textView.attributedText,
                  range.location >= 0,
                  range.location < attributed.length,
                  let tag = attributed.attribute(
                      .textItemTag,
                      at: range.location,
                      effectiveRange: nil
                  ) as? String
            else { return nil }
            return PostReferenceAttributedBuilder.reference(fromTag: tag)
        }

        /// No selection: clearing it on change keeps the body feeling like prose
        /// rather than an editable field, while leaving text items tappable.
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard textView.selectedRange.length > 0 else { return }
            textView.selectedRange = NSRange(location: 0, length: 0)
        }
    }
}
