//
//  DiscourseFormat.swift
//  nodeloc
//
//  Display helpers for server text: dates, relative times, excerpts, titles.
//  Moved out of DiscourseAPI.swift unchanged.
//

import Foundation

enum DiscourseFormat {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// A shared `DateFormatter` per (locale, template or pattern).
    ///
    /// Creating one is expensive — it loads ICU data for the locale — and
    /// call sites built one per formatted value, often per row per render.
    /// Formatting with a configured `DateFormatter` is thread-safe; they are
    /// never mutated after being cached.
    static func cachedFormatter(
        locale: Locale,
        template: String? = nil,
        format: String? = nil,
        calendar: Calendar? = nil
    ) -> DateFormatter {
        let key = "\(locale.identifier)|\(template ?? "")|\(format ?? "")|\(calendar.map { "\($0.identifier)" } ?? "")"
        formatterLock.lock()
        defer { formatterLock.unlock() }
        if let cached = formatters[key] { return cached }
        let formatter = DateFormatter()
        if let calendar { formatter.calendar = calendar }
        formatter.locale = locale
        if let template { formatter.setLocalizedDateFormatFromTemplate(template) }
        if let format { formatter.dateFormat = format }
        formatters[key] = formatter
        return formatter
    }

    private static let formatterLock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        // The hand parser covers every shape the API sends; the formatters
        // stay as a fallback for anything odd.
        return NLDate.parse(string) ?? iso.date(from: string) ?? isoNoFraction.date(from: string)
    }

    /// Compact relative time like "2h", "3d", "5m".
    static func relative(_ string: String?) -> String {
        guard let date = date(string) else { return "" }
        let seconds = max(0, Date().timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        case ..<2_629_800: return "\(Int(seconds / 604_800))w"
        default: return "\(Int(seconds / 2_629_800))mo"
        }
    }

    /// Strips HTML tags and decodes a few common entities for plain-text excerpts.
    /// Excerpt text for list rows. Post *bodies* go through `PostHTMLParser`
    /// instead; this is only for previews where formatting isn't wanted.
    ///
    /// Long tokens are made breakable, because a bare URL in an excerpt has no
    /// wrap opportunity and would widen the row past the screen.
    private static let htmlTagPattern = /<[^>]+>/

    static func plainText(_ html: String?) -> String {
        guard let html else { return "" }
        if html.isEmpty { return "" }
        // Rows call this from `body`, so every re-render of every visible row
        // re-ran the regex and the entity passes. The answer only depends on
        // the input, so keep it.
        let key = html as NSString
        if let cached = plainTextCache.object(forKey: key) { return cached as String }
        let result = uncachedPlainText(html)
        plainTextCache.setObject(result as NSString, forKey: key)
        return result
    }

    nonisolated(unsafe) private static let plainTextCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 2000
        return cache
    }()

    private static func uncachedPlainText(_ html: String) -> String {
        var text = html.replacing(htmlTagPattern, with: "")
        // Cooked titles carry the typographic set too — `fancy_title` renders
        // an apostrophe as `&rsquo;`, which used to reach the screen literally.
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                        "&#39;": "'", "&hellip;": "…", "&nbsp;": " ",
                        "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“",
                        "&rdquo;": "”", "&mdash;": "—", "&ndash;": "–"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .breakingLongTokens()
    }

    /// Prose from the server, which arrives as HTML, rendered as text that
    /// keeps its paragraph breaks.
    ///
    /// `plainText` is for excerpts and titles, where every tag collapses to
    /// nothing on purpose — a one-line excerpt wants no newlines. That is
    /// wrong for a message meant to be *read*: Discourse's own
    /// `login.activate_email` is
    /// `<p>…activate your account.</p><p>If it doesn't arrive…</p>`, and
    /// dropping the tags outright runs the two sentences together.
    static func plainTextParagraphs(_ html: String?) -> String {
        guard let html else { return "" }
        // Block boundaries become breaks before the tags are stripped.
        var text = html.replacing(/<\s*br\s*\/?>/.ignoresCase(), with: "\n")
        text = text.replacing(/<\s*\/\s*(p|div|li|h[1-6])\s*>/.ignoresCase(), with: "\n\n")
        return plainText(text)
            // Collapse the runs the substitutions above can leave behind, so a
            // trailing `</p>` doesn't end the message with blank lines.
            .replacing(/\n{3,}/, with: "\n\n")
            .replacing(/[ \t]+\n/, with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The title to display for a topic, translated when a translation exists.
    ///
    /// Content localization only rewrites `fancy_title`, so a localized topic
    /// has to be read from there. `title` stays the original and is otherwise
    /// preferable — it holds real emoji and no entities — so it keeps winning
    /// whenever `fancy_title_localized` is false.
    static func displayTitle(for topic: TopicListItem) -> String {
        displayTitle(
            title: topic.title,
            fancyTitle: topic.fancyTitle,
            isLocalized: topic.fancyTitleLocalized
        )
    }

    /// Same rule for the topic detail, which carries the fields separately.
    static func displayTitle(title: String, fancyTitle: String?, isLocalized: Bool?) -> String {
        guard isLocalized == true, let fancyTitle, !fancyTitle.isEmpty else { return title }
        return localizedTitle(fancyTitle)
    }

    /// Cleans up a cooked title for display as plain text.
    ///
    /// Emoji arrive as `:shortcode:` and are dropped rather than mapped: the
    /// chat renderer already found that a shortcode→character table covers only
    /// a fraction of the set and leaves the rest showing as literal text
    /// (`:grinning_face:`), and a row of plain text has nowhere to put the
    /// images Discourse serves instead. Losing the emoji from a *translated*
    /// title is the smaller loss — the alternative is not translating it.
    static func localizedTitle(_ fancyTitle: String) -> String {
        var text = plainText(fancyTitle)
        text = text.replacing(emojiShortcodePattern, with: " ")
        return text
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `:name:` / `:name_1:` — Discourse's shortcode form.
    ///
    /// The body must contain a letter, which keeps a timestamp intact: a naive
    /// `:[a-z0-9_+-]{2,}:` matches the `:30:` inside "10:30:45" and would turn
    /// it into "10 45". `:+1:` and `:-1:` are the two real shortcodes with no
    /// letter in them, so they are spelled out.
    private static let emojiShortcodePattern = /:(?:\+1|-1|[a-z0-9_+-]*[a-z][a-z0-9_+-]*):/

    static func mediaItems(for topic: TopicListItem) -> [PostMedia] {
        // Prefer the responsive thumbnail set: it carries the topic's
        // representative image at several widths, so each display site can pick
        // a size that matches how big it draws.
        if let media = responsiveMedia(from: topic.thumbnails) {
            return [media]
        }

        // Fall back to the single image_url when no thumbnail set is present.
        guard let raw = topic.imageUrl, let url = absoluteURL(raw) else { return [] }
        let dimensions = dimensions(from: raw)
        return [PostMedia(url: url, width: dimensions.width, height: dimensions.height)]
    }

    /// Builds one `PostMedia` from a thumbnail set: variants ascending by width,
    /// `url`/dimensions taken from the largest (the original).
    private static func responsiveMedia(from thumbnails: [TopicThumbnail]?) -> PostMedia? {
        guard let thumbnails else { return nil }
        let variants = thumbnails
            .compactMap { thumb -> ImageVariant? in
                guard let width = thumb.width, width > 0,
                      let url = thumb.url.flatMap(absoluteURL) else { return nil }
                return ImageVariant(width: width, url: url)
            }
            .sorted { $0.width < $1.width }

        guard let largest = variants.last else { return nil }
        let original = thumbnails.max { ($0.width ?? 0) < ($1.width ?? 0) }
        return PostMedia(
            url: largest.url,
            width: original?.width,
            height: original?.height,
            variants: variants
        )
    }

    private static func absoluteURL(_ raw: String) -> URL? {
        if raw.hasPrefix("http") { return URL(string: raw) }
        return URL(string: raw, relativeTo: DiscourseConfig.baseURL)?.absoluteURL
    }

    private static func dimensions(from raw: String) -> (width: Int?, height: Int?) {
        guard let range = raw.range(of: #"(\d+)x(\d+)"#, options: .regularExpression) else {
            return (nil, nil)
        }

        let parts = raw[range].split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { return (nil, nil) }
        return (parts[0], parts[1])
    }
}

