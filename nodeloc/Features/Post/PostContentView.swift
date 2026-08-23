//
//  PostContentView.swift
//  nodeloc
//
//  Renders a parsed `PostContent` tree as native SwiftUI.
//
//  One view per block type, stacked vertically. Inline runs become
//  `AttributedString` where possible, with one exception: SwiftUI's
//  AttributedString has no image-attachment equivalent to NSTextAttachment, so
//  inline emoji are spliced in by concatenating `Text` values. That is the only
//  way to keep emoji in the text flow without giving up line wrapping.
//

import AVKit
import SwiftUI

// MARK: - Emoji

/// Loads and caches inline emoji images. Emoji repeat constantly within a
/// topic, so one shared store keyed by URL avoids refetching per post.
@MainActor
@Observable
final class EmojiImageStore {
    static let shared = EmojiImageStore()

    /// Emoji repeat heavily, so these stay cached across topics — but they were
    /// two dictionaries that only ever grew. NSCache bounds them and drops them
    /// under pressure; a re-decode is cheap at this size.
    private let images = NSCache<NSString, UIImage>()
    private var loading: Set<String> = []
    /// Scaled copies keyed by url + point size. `Text(Image(...))` renders an
    /// image at its intrinsic size and ignores `.resizable()`, so the UIImage
    /// itself has to be redrawn at the text's size.
    private let scaled = NSCache<NSString, UIImage>()
    /// See `VideoPosterStore.generation`: NSCache mutations are invisible to
    /// `@Observable`, and a loaded emoji must replace its `:shortcode:`.
    private var generation = 0

    private init() {
        images.countLimit = 256
        images.totalCostLimit = 8 * 1024 * 1024
        scaled.countLimit = 512
        scaled.totalCostLimit = 8 * 1024 * 1024
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.images.removeAllObjects()
                self.scaled.removeAllObjects()
            }
        }
    }

    func image(for urlString: String) -> UIImage? {
        _ = generation
        return images.object(forKey: urlString as NSString)
    }

    /// Emoji sized to sit on a line of `pointSize` text.
    func image(for urlString: String, pointSize: CGFloat) -> UIImage? {
        _ = generation
        // Round so a handful of body sizes don't spawn a cache entry each.
        let side = (pointSize * 1.15).rounded()
        let key = "\(urlString)@\(Int(side))" as NSString
        if let cached = scaled.object(forKey: key) { return cached }
        guard let original = images.object(forKey: urlString as NSString) else { return nil }

        let resized = Self.resize(original, to: side)
        scaled.setObject(resized, forKey: key, cost: Self.cost(resized))
        return resized
    }

    private func store(_ image: UIImage, for urlString: String) {
        images.setObject(image, forKey: urlString as NSString, cost: Self.cost(image))
        generation &+= 1
    }

    private static func cost(_ image: UIImage) -> Int {
        max(Int(image.size.width * image.scale * image.size.height * image.scale * 4), 1)
    }

    /// Aspect-fits into a square box; custom emoji aren't always square.
    private static func resize(_ image: UIImage, to side: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(side / size.width, side / size.height)
        let target = CGSize(width: size.width * scale, height: size.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 0 // Match the screen so Retina emoji stay sharp.
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Kicks off a load if needed. Returns immediately; the `@Observable`
    /// mutation re-renders whatever `Text` was showing the fallback shortcode.
    func loadIfNeeded(_ urlString: String) {
        guard images.object(forKey: urlString as NSString) == nil,
              !loading.contains(urlString) else { return }
        guard let url = resolvedURL(urlString) else { return }

        loading.insert(urlString)
        // Emoji are drawn at text size and get redrawn again in `resize`, so
        // there is no reason to inflate Discourse's 72pt+ source art.
        let maxPixel = Self.sourceMaxPixel
        Task { [weak self] in
            if let cached = RemoteImageMemoryCache.shared.image(for: url, atLeast: maxPixel) {
                self?.store(cached, for: urlString)
                self?.loading.remove(urlString)
                return
            }
            let loaded = await RemoteImageDiskCache.shared.image(for: url, maxPixel: maxPixel)
            if let loaded {
                RemoteImageMemoryCache.shared.insert(loaded, for: url, maxPixel: maxPixel)
                self?.store(loaded, for: urlString)
            }
            self?.loading.remove(urlString)
        }
    }

    /// Comfortably above the largest text size emoji are drawn at.
    private static let sourceMaxPixel = 96

    /// Seeds an image directly, bypassing the network. For previews and tests.
    func inject(_ image: UIImage, for urlString: String) {
        store(image, for: urlString)
        // Cheaper than tracking which scaled keys belong to this url.
        scaled.removeAllObjects()
    }

    private func resolvedURL(_ raw: String) -> URL? {
        if raw.hasPrefix("http") { return URL(string: raw) }
        if raw.hasPrefix("//") { return URL(string: "https:" + raw) }
        if raw.hasPrefix("/") { return URL(string: raw, relativeTo: DiscourseConfig.baseURL)?.absoluteURL }
        // A bare name (no scheme, no path) is never a fetchable image — turning
        // it into a relative URL produced -1002 requests for strings like "gem".
        guard let url = URL(string: raw), url.scheme != nil else { return nil }
        return url
    }
}

// MARK: - Inline rendering

/// Style knobs so quotes and replies can render at a smaller scale without
/// duplicating every view.
struct PostTextMetrics {
    var bodySize: CGFloat = 16
    var lineSpacing: CGFloat = 6
    var textOpacity: Double = 0.88

    static let body = PostTextMetrics()
    static let reply = PostTextMetrics(bodySize: 14, lineSpacing: 5, textOpacity: 0.88)
    /// Quotes render one step down from their container.
    func nested() -> PostTextMetrics {
        PostTextMetrics(bodySize: max(12, bodySize - 2), lineSpacing: max(3, lineSpacing - 1), textOpacity: 0.75)
    }
}

enum PostInlineRenderer {
    /// A run of inlines becomes alternating attributed text and emoji images.
    /// Splitting is necessary because emoji can't live inside AttributedString.
    private enum Segment {
        case text(AttributedString)
        case emoji(url: String, shortcode: String)
    }

    static func text(
        for inlines: [PostInline],
        metrics: PostTextMetrics,
        emoji: EmojiImageStore
    ) -> Text {
        let segments = segments(for: inlines, metrics: metrics)

        // Interpolating `Text` values, rather than the `+` operator that iOS 26
        // deprecates. Interpolation of a `Text` (unlike a bare `Image`) is
        // supported, so inline emoji still splice into the wrapping run.
        return segments.reduce(Text("")) { accumulated, segment in
            switch segment {
            case .text(let attributed):
                return Text("\(accumulated)\(Text(attributed))")

            case .emoji(let url, let shortcode):
                if let image = emoji.image(for: url, pointSize: metrics.bodySize) {
                    // Baseline nudge keeps the glyph optically centred on the line.
                    let glyph = Text(Image(uiImage: image)).baselineOffset(-1)
                    return Text("\(accumulated)\(glyph)")
                }
                // Not loaded yet: show the shortcode so the sentence still reads.
                emoji.loadIfNeeded(url)
                var fallback = AttributedString(shortcode)
                fallback.foregroundColor = Theme.muted(0.5)
                return Text("\(accumulated)\(Text(fallback))")
            }
        }
    }

    private static func segments(for inlines: [PostInline], metrics: PostTextMetrics) -> [Segment] {
        var segments: [Segment] = []
        var current = AttributedString()

        func flush() {
            if !current.characters.isEmpty { segments.append(.text(current)) }
            current = AttributedString()
        }

        for inline in inlines {
            switch inline {
            case .emoji(let url, let shortcode):
                flush()
                segments.append(.emoji(url: url, shortcode: shortcode))
            default:
                current.append(attributed(for: inline, metrics: metrics))
            }
        }
        flush()
        return segments
    }

    /// Non-emoji inlines map cleanly onto AttributedString runs.
    ///
    /// Text goes through `breakingLongTokens` first: a bare URL or hash has no
    /// break opportunity, and SwiftUI reports such a run as the view's minimum
    /// width, which pushes the entire screen sideways.
    private static func attributed(for inline: PostInline, metrics: PostTextMetrics) -> AttributedString {
        switch inline {
        case .text(let value):
            return AttributedString(value.breakingLongTokens())

        case .styled(let value, let style):
            var run = AttributedString(value.breakingLongTokens())
            if style.contains(.code) {
                run.font = .system(size: metrics.bodySize - 1, design: .monospaced)
                run.backgroundColor = Theme.hover
            } else {
                var font = Font.system(size: metrics.bodySize)
                if style.contains(.bold) { font = font.bold() }
                if style.contains(.italic) { font = font.italic() }
                run.font = font
            }
            if style.contains(.strikethrough) { run.strikethrougnStyleCompat() }
            return run

        case .link(let href, let children):
            var run = children.reduce(into: AttributedString()) { partial, child in
                partial.append(attributed(for: child, metrics: metrics))
            }
            if let url = resolvedLink(href) { run.link = url }
            run.foregroundColor = Theme.accent
            return run

        case .mention(let username):
            var run = AttributedString("@\(username)")
            run.foregroundColor = Theme.accent
            run.font = .system(size: metrics.bodySize, weight: .medium)
            if let url = resolvedLink("/u/\(username)") { run.link = url }
            return run

        case .lineBreak:
            return AttributedString("\n")

        case .emoji(_, let shortcode):
            // Handled by `segments`; reachable only via nested link children.
            return AttributedString(shortcode)
        }
    }

    static func resolvedLink(_ raw: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("http") { return URL(string: raw) }
        if raw.hasPrefix("//") { return URL(string: "https:" + raw) }
        if raw.hasPrefix("/") { return URL(string: raw, relativeTo: DiscourseConfig.baseURL)?.absoluteURL }
        return URL(string: raw)
    }
}

private extension AttributedString {
    /// `strikethroughStyle` needs the NSAttributedString bridge on the
    /// SwiftUI attribute scope.
    mutating func strikethrougnStyleCompat() {
        self.strikethroughStyle = .single
    }
}

// MARK: - Content view

/// Renders a whole post body. `pollProvider` supplies the poll matching a
/// `pollPlaceholder`, so polls stay at their authored position in the text.
struct PostContentView: View {
    let content: PostContent
    var metrics: PostTextMetrics = .body
    var onImageTap: ((PostImage) -> Void)?
    var pollProvider: ((String) -> AnyView?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(content.blocks) { block in
                PostBlockView(
                    block: block,
                    metrics: metrics,
                    onImageTap: onImageTap,
                    pollProvider: pollProvider
                )
            }
        }
        // Through the environment rather than a parameter: videos can be nested
        // inside quotes, lists or details, and threading the list through every
        // container would mean touching each one.
        .environment(\.postVideoSiblings, content.videos)
        // Final backstop: user content can always surprise us, and one wide
        // block shouldn't be able to shift the whole screen sideways.
        .clampedToWidth()
    }
}

/// All videos in the enclosing post, so a video nested in a quote or list can
/// still page through the whole set in full screen.
private struct PostVideoSiblingsKey: EnvironmentKey {
    static let defaultValue: [PostVideo] = []
}

/// Post identity for the full-screen video chrome. Travels through the
/// environment for the same reason the sibling list does — videos nest inside
/// quotes, lists and details, so a parameter would need threading everywhere.
private struct PostVideoPresentationKey: EnvironmentKey {
    static let defaultValue: PostVideoPresentation? = nil
}

private struct PostVideoActionsKey: EnvironmentKey {
    static let defaultValue = PostVideoActions()
}

/// Actions the full-screen chrome invokes that the player can't perform itself.
struct PostVideoActions {
    /// Sends the like to the server; the local toggle is handled centrally.
    var remoteLike: (() -> Void)?
    var comment: (() -> Void)?
}

extension EnvironmentValues {
    var postVideoSiblings: [PostVideo] {
        get { self[PostVideoSiblingsKey.self] }
        set { self[PostVideoSiblingsKey.self] = newValue }
    }

    var postVideoPresentation: PostVideoPresentation? {
        get { self[PostVideoPresentationKey.self] }
        set { self[PostVideoPresentationKey.self] = newValue }
    }

    var postVideoActions: PostVideoActions {
        get { self[PostVideoActionsKey.self] }
        set { self[PostVideoActionsKey.self] = newValue }
    }
}

struct PostBlockView: View {
    let block: PostBlock
    let metrics: PostTextMetrics
    var onImageTap: ((PostImage) -> Void)?
    var pollProvider: ((String) -> AnyView?)?

    @Environment(EmojiImageStore.self) private var emoji

    var body: some View {
        switch block {
        case .paragraph(let inlines):
            inlineText(inlines)

        case .heading(let level, let inlines):
            PostInlineRenderer.text(for: inlines, metrics: metrics, emoji: emoji)
                .font(Theme.heading(headingSize(level), weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

        case .image(let image):
            PostImageView(image: image) { onImageTap?(image) }

        case .video(let video):
            PostVideoView(video: video)

        case .codeBlock(let language, let code):
            PostCodeBlockView(language: language, code: code)

        case .quote(let quote):
            PostQuoteView(quote: quote, metrics: metrics, onImageTap: onImageTap)

        case .blockquote(let blocks):
            PostBlockquoteView(blocks: blocks, metrics: metrics, onImageTap: onImageTap)

        case .list(let ordered, let items):
            PostListView(ordered: ordered, items: items, metrics: metrics, onImageTap: onImageTap)

        case .table(let headers, let rows):
            PostTableView(headers: headers, rows: rows, metrics: metrics)

        case .details(let summary, let blocks):
            PostDetailsView(summary: summary, blocks: blocks, metrics: metrics, onImageTap: onImageTap)

        case .spoiler(let blocks):
            PostSpoilerView(blocks: blocks, metrics: metrics, onImageTap: onImageTap)

        case .onebox(let onebox):
            PostOneboxView(onebox: onebox)

        case .divider:
            Divider().overlay(Theme.divider)

        case .pollPlaceholder(let name):
            if let view = pollProvider?(name) {
                view
            }
        }
    }

    private func inlineText(_ inlines: [PostInline]) -> some View {
        PostInlineRenderer.text(for: inlines, metrics: metrics, emoji: emoji)
            .font(Theme.body(metrics.bodySize))
            .foregroundStyle(Theme.text.opacity(metrics.textOpacity))
            .lineSpacing(metrics.lineSpacing)
            // Order matters: the frame has to constrain the width *before*
            // `fixedSize` measures the height. Reversed, the text sizes to its
            // own ideal width first and overruns any inset container.
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .tint(Theme.accent)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: metrics.bodySize + 8
        case 2: metrics.bodySize + 5
        case 3: metrics.bodySize + 3
        default: metrics.bodySize + 1
        }
    }
}

// MARK: - Images

/// Reserves space from the HTML's width/height so the layout doesn't jump when
/// the image finishes loading.
struct PostImageView: View {
    let image: PostImage
    let onTap: () -> Void

    private var resolvedURL: URL? { PostInlineRenderer.resolvedLink(image.src) }
    private var isGIF: Bool { resolvedURL?.pathExtension.lowercased() == "gif" }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        Group {
            if isGIF, let url = resolvedURL {
                // GIFs must animate — CachedRemoteImage decodes a single frame.
                AnimatedGIFView(url: url)
            } else {
                CachedRemoteImage(url: resolvedURL) { loaded in
                    loaded
                        .resizable()
                        .scaledToFit()
                } placeholder: {
                    Theme.hover.overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.muted(0.4))
                    }
                }
            }
        }
        .aspectRatio(image.aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Theme.divider, lineWidth: 1) }
        .contentShape(shape)
        .onTapGesture(perform: onTap)
        .accessibilityLabel(image.alt ?? "图片")
    }
}

// MARK: - Animated GIF

/// Displays an animated GIF (a `UIImageView` auto-animates a multi-frame
/// `UIImage`). Frames are downsampled and cached off the main actor.
private struct AnimatedGIFView: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                GIFImageView(image: image)
            } else {
                Theme.hover.overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.4))
                }
            }
        }
        .task(id: url) { image = await AnimatedGIFStore.shared.load(url) }
    }
}

private struct GIFImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        view.image = image
        view.startAnimating()
    }
}

@MainActor
final class AnimatedGIFStore {
    static let shared = AnimatedGIFStore()
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() { cache.countLimit = 24 }

    func load(_ url: URL) async -> UIImage? {
        let key = url.absoluteString
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<UIImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return await Task.detached { Self.animatedImage(from: data, maxPixel: 900) }.value
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }

    /// Builds an animated `UIImage` from GIF data, downsampling each frame.
    nonisolated static func animatedImage(from data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return UIImage(data: data) }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]

        var frames: [UIImage] = []
        var duration: Double = 0
        for index in 0..<count {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { continue }
            frames.append(UIImage(cgImage: cg))
            duration += frameDelay(source, index)
        }
        guard !frames.isEmpty else { return UIImage(data: data) }
        return UIImage.animatedImage(with: frames, duration: duration)
    }

    private nonisolated static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let unclamped = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif?[kCGImagePropertyGIFDelayTime] as? Double
        let delay = unclamped ?? clamped ?? 0.1
        // Browsers clamp very short delays to ~0.1s.
        return delay < 0.02 ? 0.1 : delay
    }
}

// MARK: - Video

/// Whether post videos play muted. Shared so the choice persists as the user
/// scrolls between videos and in and out of full screen, matching Reddit.
@MainActor
@Observable
final class VideoMuteState {
    static let shared = VideoMuteState()
    var isMuted = true
}

/// First frames, generated on demand and cached by video URL.
///
/// Discourse's `video-placeholder-container` on nodeloc never carries
/// `data-thumbnail-src` — checked across every video topic on the site — so
/// there is no server-side poster to fetch. The frame is decoded locally
/// instead, which also guarantees it matches the video exactly.
@MainActor
@Observable
final class VideoPosterStore {
    static let shared = VideoPosterStore()

    /// A decoded 1080×1920 frame is ~8 MB, so this was the app's largest
    /// unbounded allocation: scrolling a feed of video cards grew it without
    /// limit. NSCache evicts under pressure; the aspect index below is kept
    /// separately because it is tiny and worth surviving eviction.
    private let frames = NSCache<NSString, UIImage>()
    /// Width ÷ height. Kept out of the image cache so a card that scrolls away
    /// and back is sized correctly on sight even if its frame was evicted —
    /// otherwise it would flash at the default ratio and resize.
    private var aspects: [String: CGFloat] = [:]
    private var inFlight: Set<String> = []
    /// `@Observable` tracks stored properties, and an `NSCache` mutates behind
    /// its own reference — so storing a frame would not re-render the view
    /// waiting for it. Reads touch this; writes bump it.
    private var generation = 0

    private init() {
        frames.countLimit = 24
        frames.totalCostLimit = 64 * 1024 * 1024
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.frames.removeAllObjects() }
        }
    }

    func frame(for src: String) -> UIImage? {
        _ = generation
        return frames.object(forKey: src as NSString)
    }

    func aspect(for src: String) -> CGFloat? { aspects[src] }

    func loadIfNeeded(_ src: String, url: URL) {
        guard frames.object(forKey: src as NSString) == nil, !inFlight.contains(src) else { return }
        inFlight.insert(src)
        Task {
            if let image = await Self.firstFrame(of: url) {
                // The generated frame already has the display orientation
                // applied, so its own size is the aspect ratio — no second
                // round trip to read the track.
                if image.size.height > 0 {
                    aspects[src] = image.size.width / image.size.height
                }
                let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
                frames.setObject(image, forKey: src as NSString, cost: max(cost, 1))
                generation &+= 1
            }
            inFlight.remove(src)
        }
    }

    /// Decodes a frame just after t=0. Exactly zero can land on a black or
    /// incomplete frame in some encodings, so sample slightly in.
    private static func firstFrame(of url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        // Without this the generator snaps to the nearest keyframe, which can
        // be seconds away from the requested time.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        generator.appliesPreferredTrackTransform = true
        // The poster is only ever drawn at card size, so ask the generator for
        // a scaled frame rather than decoding the video's full resolution — a
        // 4K clip would otherwise cost ~33 MB for a still nobody sees at 4K.
        generator.maximumSize = CGSize(width: posterMaxPixel, height: posterMaxPixel)
        let time = CMTime(seconds: 0.05, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Generous enough for a full-width card on a 3x phone.
    private static let posterMaxPixel: CGFloat = 1200
}

/// Inline video: autoplays muted while on screen, tap to go full screen.
///
/// Sized by the video's own aspect ratio, like Reddit — a portrait clip should
/// stand tall rather than sit letterboxed in a short landscape box. Only the
/// extremes are clamped, so nothing degenerates into a sliver or eats a whole
/// screen and a half.
struct PostVideoView: View {
    let video: PostVideo

    @State private var player: AVPlayer?
    @State private var isVisible = false
    @State private var isPresentingFullScreen = false
    @Environment(VideoMuteState.self) private var mute
    @Environment(VideoPosterStore.self) private var posters
    @Environment(\.postVideoSiblings) private var siblings
    @Environment(\.postVideoPresentation) private var presentation
    @Environment(\.postVideoActions) private var actions
    @Environment(\.scenePhase) private var scenePhase

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    /// Used only until the clip's real dimensions are known.
    static let defaultAspect: CGFloat = 16.0 / 9.0
    /// Taller than 4:5 gets cropped; Reddit clamps portrait media the same way
    /// so one clip can't push the entire post off screen.
    static let minAspect: CGFloat = 0.8
    /// Cinematic letterboxes stay watchable instead of becoming a strip.
    static let maxAspect: CGFloat = 2.4

    /// Comes from the shared store, so the card is the right shape the moment
    /// the frame is known — and stays that shape when it scrolls back in.
    private var aspect: CGFloat {
        guard let known = posters.aspect(for: video.src) else { return Self.defaultAspect }
        return min(max(known, Self.minAspect), Self.maxAspect)
    }

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            // Poster sits underneath so the card is never blank while the
            // player buffers its first frame.
            .background { poster }
            .overlay { surface }
            .clipShape(shape)
            .overlay { shape.strokeBorder(Theme.divider, lineWidth: 1) }
            .overlay(alignment: .topTrailing) { muteButton }
            .contentShape(shape)
            .onTapGesture { isPresentingFullScreen = true }
            .accessibilityLabel("视频，点击全屏播放")
            // Autoplay only while actually on screen; a low threshold starts
            // playback as the video scrolls into view rather than after.
            .onScrollVisibilityChange(threshold: 0.35) { visible in
                isVisible = visible
                updatePlayback()
            }
            .onChange(of: mute.isMuted) { _, muted in player?.isMuted = muted }
            .onChange(of: isPresentingFullScreen) { _, _ in updatePlayback() }
            .onChange(of: scenePhase) { _, _ in updatePlayback() }
            // Settles the card's shape as early as possible, before any player
            // exists — a video block that is off screen still gets sized, so
            // scrolling to it doesn't jump.
            .task { loadPoster() }
            .onAppear(perform: preparePlayer)
            .onDisappear {
                player?.pause()
                player = nil
            }
            // Same presenter the feed and node list use, so the player is
            // identical wherever it is opened from.
            .postVideoFullScreen(
                video: fullScreenVideo,
                presentation: presentation,
                siblings: siblings,
                onRemoteLike: actions.remoteLike,
                // Replying happens in the post behind this cover.
                onComment: { actions.comment?() }
            )
    }

    /// Bridges the bool the tap gesture sets to the item the presenter wants.
    private var fullScreenVideo: Binding<PostVideo?> {
        Binding(
            get: { isPresentingFullScreen ? video : nil },
            set: { isPresentingFullScreen = $0 != nil }
        )
    }

    @ViewBuilder
    private var surface: some View {
        if let player {
            // `VideoPlayer`'s own controls would fight the tap-to-fullscreen
            // gesture, so the inline surface is a bare player layer.
            InlineVideoSurface(player: player)
        }
    }

    private var muteButton: some View {
        Button {
            mute.isMuted.toggle()
        } label: {
            Image(systemName: mute.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.black.opacity(0.5), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(10)
        .accessibilityLabel(mute.isMuted ? "取消静音" : "静音")
    }

    /// Server thumbnail when there is one, otherwise the clip's own first frame.
    ///
    /// Core only sets `data-thumbnail-src` when an upload exists whose filename
    /// is the video's SHA1 (`pretty_text.rb#add_video_placeholder_image`), i.e.
    /// when the *poster was uploaded alongside the video*. Web-composed posts
    /// have no such upload, so in practice existing posts have none. This app's
    /// own composer does upload one (`uploadVideoPoster`), so its posts will.
    @ViewBuilder
    private var poster: some View {
        if let posterSrc = video.posterSrc,
           let url = PostInlineRenderer.resolvedLink(posterSrc) {
            CachedRemoteImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                generatedPoster
            }
        } else {
            generatedPoster
        }
    }

    @ViewBuilder
    private var generatedPoster: some View {
        if let frame = posters.frame(for: video.src) {
            // Fill, matching the player layer's `.resizeAspectFill`, so the
            // still and the first played frame line up pixel for pixel.
            Image(uiImage: frame)
                .resizable()
                .scaledToFill()
        } else {
            placeholderBackground
        }
    }

    private var placeholderBackground: some View {
        LinearGradient(
            colors: [Theme.neutral800.opacity(0.9), Theme.neutral900.opacity(0.95)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Decodes the first frame, which also settles the card's shape. Runs on
    /// `task`, before and independently of the player, so the layout is right
    /// as early as possible and survives the player teardown on scroll-away.
    private func loadPoster() {
        guard let url = PostInlineRenderer.resolvedLink(video.src) else { return }
        posters.loadIfNeeded(video.src, url: url)
    }

    private func preparePlayer() {
        guard player == nil, let url = PostInlineRenderer.resolvedLink(video.src) else { return }
        let asset = AVURLAsset(url: url)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.isMuted = mute.isMuted
        // Inline videos loop; short clips otherwise freeze on a black frame.
        player.actionAtItemEnd = .none
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            Task { @MainActor in player.seek(to: .zero); player.play() }
        }
        self.player = player
        updatePlayback()
    }

    private func updatePlayback() {
        guard let player else { return }
        // Full screen owns its own player, so the inline one steps aside to
        // avoid two audio tracks.
        let shouldPlay = isVisible && !isPresentingFullScreen && scenePhase == .active
        if shouldPlay {
            player.isMuted = mute.isMuted
            player.play()
        } else {
            player.pause()
        }
    }
}

// MARK: - Shared full-screen presentation

/// Everything the full-screen player needs, derived from a `Post` in one place.
///
/// Every entry point — post detail, home feed, node card — goes through this,
/// so the player is identical wherever it is opened from. Assembling the
/// context per call site is how the three copies drifted: the feed's lost the
/// node avatar and left the node button dead.
@MainActor
struct PostVideoPresentation {
    let post: Post
    /// Resolved node, for the header's logo and colour. Falls back to whatever
    /// `post.node` carries when the catalog hasn't answered yet.
    var node: SidebarNodeSummary?
    /// Author from the loaded topic, when there is one. The list only knows the
    /// last poster, so the post detail can supply a better value.
    var author: UserProfileTarget?
    /// Reply count from the loaded topic, which is more accurate than the
    /// list's `posts_count - 1`.
    var commentCount: Int?

    func context(app: AppState) -> PostVideoContext {
        PostVideoContext(
            nodeName: post.node,
            nodeLogoURL: node?.logoURL,
            nodeColorHex: node?.colorHex,
            title: post.title,
            authorUsername: author?.username ?? post.authorUsername,
            authorAvatarURL: author?.avatarURL ?? post.avatarURL,
            likeCount: app.voteCount(post),
            isLiked: app.isLiked(post),
            commentCount: commentCount ?? post.comments,
            shareURL: DiscourseConfig.baseURL.appending(path: "t/topic/\(post.id)")
        )
    }

    var profileTarget: UserProfileTarget? {
        author ?? post.authorProfileTarget
    }
}

/// Presents `PostVideoPager` with chrome derived from a `Post`.
///
/// A view modifier rather than a plain view so the three call sites share the
/// presentation *and* its wiring, not just the player.
struct PostVideoFullScreen: ViewModifier {
    @Binding var video: PostVideo?
    let presentation: PostVideoPresentation?
    /// Siblings, when the post's other videos are known. The feed only knows
    /// the one on the card.
    var siblings: [PostVideo] = []
    /// Sends the like to the server. Only the post detail can: liking needs the
    /// *first post's* id, which a list item doesn't carry. Elsewhere the local
    /// toggle still happens, and the like syncs when the post is opened.
    var onRemoteLike: (() -> Void)?
    /// Opens the post — the only action the player can't perform in place.
    var onComment: (() -> Void)?

    @Environment(AppState.self) private var app

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $video) { current in
            if let presentation {
                let list = siblings.isEmpty ? [current] : siblings
                PostVideoPager(
                    videos: list,
                    startingAt: list.firstIndex { $0.src == current.src } ?? 0,
                    context: presentation.context(app: app),
                    onLike: {
                        let wasLiked = app.isLiked(presentation.post)
                        app.toggleLike(presentation.post)
                        if !wasLiked { onRemoteLike?() }
                    },
                    onComment: {
                        video = nil
                        onComment?()
                    },
                    node: presentation.node,
                    author: presentation.profileTarget
                ) {
                    video = nil
                }
            }
        }
    }
}

/// Presents `PostImageViewer` with the same chrome the video player uses.
struct PostImageFullScreen: ViewModifier {
    @Binding var images: [PostImage]
    @Binding var selection: Int
    let presentation: PostVideoPresentation?
    var onRemoteLike: (() -> Void)?
    var onComment: (() -> Void)?

    @Environment(AppState.self) private var app

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: isPresented) {
            PostImageViewer(
                images: images,
                selection: $selection,
                context: presentation?.context(app: app),
                node: presentation?.node,
                author: presentation?.profileTarget,
                onLike: presentation.map { presentation in
                    {
                        let wasLiked = app.isLiked(presentation.post)
                        app.toggleLike(presentation.post)
                        if !wasLiked { onRemoteLike?() }
                    }
                },
                onComment: onComment.map { action in
                    {
                        images = []
                        action()
                    }
                }
            ) {
                images = []
            }
            // Clear, so the viewer's own dimming layer is all there is — the
            // drag-to-dismiss fade then reveals the reader behind the image.
            .presentationBackground(.clear)
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { !images.isEmpty },
            set: { if !$0 { images = [] } }
        )
    }
}

extension View {
    /// Full-screen images with the standard chrome. See `PostImageFullScreen`.
    func postImageFullScreen(
        images: Binding<[PostImage]>,
        selection: Binding<Int>,
        presentation: PostVideoPresentation?,
        onRemoteLike: (() -> Void)? = nil,
        onComment: (() -> Void)? = nil
    ) -> some View {
        modifier(PostImageFullScreen(
            images: images,
            selection: selection,
            presentation: presentation,
            onRemoteLike: onRemoteLike,
            onComment: onComment
        ))
    }

    /// Full-screen video with the standard chrome. See `PostVideoFullScreen`.
    func postVideoFullScreen(
        video: Binding<PostVideo?>,
        presentation: PostVideoPresentation?,
        siblings: [PostVideo] = [],
        onRemoteLike: (() -> Void)? = nil,
        onComment: (() -> Void)? = nil
    ) -> some View {
        modifier(PostVideoFullScreen(
            video: video,
            presentation: presentation,
            siblings: siblings,
            onRemoteLike: onRemoteLike,
            onComment: onComment
        ))
    }
}

/// A topic's video in a feed card: autoplays muted while it holds the screen,
/// pauses as soon as it doesn't. Tapping falls through to the card's own button,
/// which opens the post — the full-screen player lives there.
struct FeedVideoTile: View {
    let url: URL
    /// Discourse's topic thumbnail, shown until the first frame decodes.
    var posterURL: URL?
    /// When set, tapping plays full screen instead of falling through to the
    /// card. Unset means the card handles the tap and opens the post.
    var onTap: (() -> Void)?

    @State private var player: AVPlayer?
    @State private var isVisible = false
    /// Uploads get deleted while the cooked HTML keeps referencing them — a
    /// real case on nodeloc. A dead URL falls back to the poster instead of
    /// showing a black rectangle and a mute button that does nothing.
    @State private var isUnplayable = false
    @State private var statusObservation: NSKeyValueObservation?
    @Environment(VideoMuteState.self) private var mute
    @Environment(VideoPosterStore.self) private var posters
    @Environment(\.scenePhase) private var scenePhase

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    /// Width ÷ height, from the decoded first frame. Matches the feed's image
    /// clamps so a video card and a photo card of the same shape agree.
    private var aspect: CGFloat {
        guard let known = posters.aspect(for: url.absoluteString) else {
            return 1 / Theme.FeedMedia.defaultAspect
        }
        return min(max(known, 1 / Theme.FeedMedia.maxAspect), 1 / Theme.FeedMedia.minAspect)
    }

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background { poster }
            .overlay { surface }
            .clipShape(shape)
            .overlay(alignment: .bottomTrailing) {
                if !isUnplayable { muteButton }
            }
            // Only one card can be centred, so a stricter threshold than the
            // post detail's: this decides which of several cards has focus.
            .onScrollVisibilityChange(threshold: 0.6) { visible in
                isVisible = visible
                updatePlayback()
            }
            .contentShape(shape)
            .onTapGesture { if !isUnplayable { onTap?() } }
            .onChange(of: mute.isMuted) { _, muted in player?.isMuted = muted }
            .onChange(of: scenePhase) { _, _ in updatePlayback() }
            .task { posters.loadIfNeeded(url.absoluteString, url: url) }
            .onAppear(perform: preparePlayer)
            .onDisappear {
                statusObservation?.invalidate()
                statusObservation = nil
                player?.pause()
                player = nil
            }
    }

    @ViewBuilder
    private var surface: some View {
        if let player, !isUnplayable {
            InlineVideoSurface(player: player)
        }
    }

    @ViewBuilder
    private var poster: some View {
        if let frame = posters.frame(for: url.absoluteString) {
            Image(uiImage: frame).resizable().scaledToFill()
        } else if let posterURL {
            CachedRemoteImage(url: posterURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Theme.neutral300
            }
        } else {
            Theme.neutral300
        }
    }

    /// Sits inside the card's tap target, so it needs its own hit testing to
    /// toggle sound without also opening the post.
    private var muteButton: some View {
        Button {
            mute.isMuted.toggle()
        } label: {
            Image(systemName: mute.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.black.opacity(0.5), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(10)
    }

    private func preparePlayer() {
        guard player == nil else { return }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = mute.isMuted
        player.actionAtItemEnd = .none
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in player.seek(to: .zero); player.play() }
        }
        // A 404 surfaces here, not as a thrown error.
        statusObservation = item.observe(\.status) { item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                isUnplayable = true
                player.pause()
            }
        }
        self.player = player
        updatePlayback()
    }

    private func updatePlayback() {
        guard let player, !isUnplayable else { return }
        if isVisible && scenePhase == .active {
            player.isMuted = mute.isMuted
            player.play()
        } else {
            player.pause()
        }
    }
}

/// A plain `AVPlayerLayer`. `VideoPlayer` would add controls that swallow the
/// tap used to enter full screen.
struct InlineVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    /// `.resizeAspectFill` inline (the card is already the right shape) and
    /// `.resizeAspect` full screen, where the layer letterboxes and centres the
    /// frame for us. That centring matters: the representable has no intrinsic
    /// size, so a SwiftUI `.aspectRatio` on it has nothing to measure.
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        // A UIView takes touches by default and would win hit-testing against
        // the SwiftUI tap gesture behind it, so tapping the video did nothing.
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        if view.playerLayer.videoGravity != gravity { view.playerLayer.videoGravity = gravity }
    }

    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

// MARK: - Full screen

/// The post a full-screen video belongs to, used to draw the chrome around it.
/// Passed in rather than read from the environment so the pager stays usable
/// from anywhere a video can appear.
nonisolated struct PostVideoContext: Equatable {
    var nodeName: String
    var nodeLogoURL: URL?
    var nodeColorHex: String?
    var title: String
    var authorUsername: String?
    var authorAvatarURL: URL?
    var likeCount: Int
    var isLiked: Bool
    var commentCount: Int
    var shareURL: URL?

    var nodeLetter: String {
        let stripped = nodeName.hasPrefix("n/") ? String(nodeName.dropFirst(2)) : nodeName
        return String(stripped.prefix(1)).uppercased()
    }

    var authorLetter: String {
        String((authorUsername ?? nodeName).prefix(1)).uppercased()
    }
}

/// Playback state for the page currently on screen.
///
/// The transport row is drawn by the pager, below the caption, but the player
/// lives inside the page. This carries state between them so the two aren't
/// forced into the same view.
@MainActor
@Observable
final class VideoTransportState {
    var isPlaying = true
    var progress: Double = 0
    var duration: Double = 0
    var isScrubbing = false
    /// Set by the active page; the transport row drives the player through it.
    var seek: ((Double) -> Void)?
    var togglePlayback: (() -> Void)?

    func reset() {
        isPlaying = true
        progress = 0
        duration = 0
        isScrubbing = false
        seek = nil
        togglePlayback = nil
    }
}

/// Full-screen playback that pages vertically between the post's videos,
/// TikTok/Reels style, with the post's own chrome layered over it.
struct PostVideoPager: View {
    let videos: [PostVideo]
    let startingAt: Int
    var context: PostVideoContext?
    var onLike: (() -> Void)?
    var onComment: (() -> Void)?
    /// Destinations opened over the video. Presented here rather than in the
    /// post behind, so dismissing one returns to the video.
    var node: SidebarNodeSummary?
    var author: UserProfileTarget?
    let onClose: () -> Void

    @State private var selection: Int
    /// Tapping the video hides every control, so nothing covers the frame.
    @State private var isChromeVisible = true
    @State private var transport = VideoTransportState()
    /// Mirrors the chrome's covered state, so a hidden clip stops playing.
    @State private var isCovered = false
    @Environment(VideoMuteState.self) private var mute

    init(
        videos: [PostVideo],
        startingAt: Int,
        context: PostVideoContext? = nil,
        onLike: (() -> Void)? = nil,
        onComment: (() -> Void)? = nil,
        node: SidebarNodeSummary? = nil,
        author: UserProfileTarget? = nil,
        onClose: @escaping () -> Void
    ) {
        self.videos = videos
        self.startingAt = startingAt
        self.context = context
        self.onLike = onLike
        self.onComment = onComment
        self.node = node
        self.author = author
        self.onClose = onClose
        _selection = State(initialValue: startingAt)
    }

    var body: some View {
        MediaViewerChrome(
            context: context,
            pageIndicator: videos.count > 1 ? "\(selection + 1)/\(videos.count)" : nil,
            node: node,
            author: author,
            onLike: onLike,
            onComment: onComment,
            middleBar: AnyView(VideoTransportBar(transport: transport)),
            onClose: onClose,
            isVisible: $isChromeVisible,
            // A covered clip stops playing: the node and profile pages sit on
            // top of the video, and a hidden one should not keep talking.
            onCoveredChange: { isCovered = $0 }
        ) {
            pages
        }
        // Each video reports its own duration and position.
        .onChange(of: selection) { _, _ in transport.reset() }
    }

    /// `.page` on a rotated TabView is the standard way to get vertical paging:
    /// rotate the container -90°, counter-rotate each page. The frame is
    /// swapped to match, measured from the container rather than `UIScreen.main`
    /// — that's deprecated in iOS 26 and wrong under iPad multitasking anyway.
    private var pages: some View {
        GeometryReader { proxy in
            TabView(selection: $selection) {
                ForEach(Array(videos.enumerated()), id: \.offset) { index, video in
                    FullScreenVideoPage(
                        video: video,
                        isActive: selection == index && !isCovered,
                        isChromeVisible: $isChromeVisible,
                        transport: transport
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .rotationEffect(.degrees(90))
                    .tag(index)
                }
            }
            .frame(width: proxy.size.height, height: proxy.size.width)
            .rotationEffect(.degrees(-90))
            .tabViewStyle(.page(indexDisplayMode: .never))
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .ignoresSafeArea()
    }
}

/// The chrome shared by the full-screen video and image viewers: close / node /
/// overflow on top, author + title + actions on the bottom, tap to hide, and
/// the node and profile pages layered above.
///
/// Only the media itself differs between the two, so it comes in as content.
struct MediaViewerChrome<Content: View>: View {
    let context: PostVideoContext?
    /// "2/5" style position, when the viewer is paging.
    var pageIndicator: String?
    var node: SidebarNodeSummary?
    var author: UserProfileTarget?
    var onLike: (() -> Void)?
    var onComment: (() -> Void)?
    /// Sits between the caption and the action bar. The video puts its
    /// transport row here; the image viewer has nothing to put.
    var middleBar: AnyView?
    /// The image viewer dims this during its drag-to-dismiss; the media stays
    /// opaque while the room darkens/lightens around it.
    var backgroundOpacity: Double = 1
    let onClose: () -> Void
    @Binding var isVisible: Bool
    /// Reports when a node or profile page covers the media, so a video can
    /// pause behind it.
    var onCoveredChange: ((Bool) -> Void)?
    @ViewBuilder let content: Content

    @State private var isShowingNode = false
    @State private var isShowingAuthor = false
    @Environment(AppState.self) private var app

    /// True while a node or profile page is layered over the media.
    private var isCovered: Bool { isShowingNode || isShowingAuthor }

    var body: some View {
        ZStack {
            Color.black.opacity(backgroundOpacity).ignoresSafeArea()

            content

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomStack
            }
            .opacity(isVisible ? 1 : 0)
            // Hidden chrome must not keep intercepting taps meant for the media.
            .allowsHitTesting(isVisible)
        }
        .statusBarHidden()
        // Layered over the media, so closing either comes back here.
        .overlay {
            if isShowingNode, let node {
                NodeDetailOverlay(node: node) {
                    withAnimation(.overlayPush) {
                        isShowingNode = false
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay {
            if isShowingAuthor, let author {
                PublicProfileOverlay(target: author) {
                    withAnimation(.overlayPush) {
                        isShowingAuthor = false
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // Opening a post from either page swaps `app.selectedPost`, which
        // renders in the layer *below* this cover — so the cover has to get out
        // of the way or the new post opens invisibly behind the media.
        .onChange(of: app.selectedPost.id) { _, _ in
            guard isCovered else { return }
            isShowingNode = false
            isShowingAuthor = false
            onClose()
        }
        .onChange(of: isCovered) { _, covered in onCoveredChange?(covered) }
    }

    /// Caption, then the media's own controls, then actions.
    private var bottomStack: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let context { caption(for: context) }

            if let middleBar { middleBar }

            if let context {
                PostVideoActionBar(context: context, onLike: onLike, onComment: onComment)
            }
        }
        .padding(.horizontal, FloatingHeader.horizontalInset)
        .padding(.bottom, 30)
        .background {
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
    }

    /// Avatar + username on one line, title beneath.
    private func caption(for context: PostVideoContext) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.overlayPush) {
                    isShowingAuthor = true
                }
            } label: {
                HStack(spacing: 8) {
                    RemoteAvatar(
                        url: context.authorAvatarURL,
                        letter: context.authorLetter,
                        size: 26
                    )
                    if let username = context.authorUsername {
                        Text("u/\(username)")
                            .font(Theme.body(13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                // Only the avatar and name are tappable, not the trailing gap —
                // the title below is not a profile link.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(author == nil)
            .accessibilityLabel("打开 \(context.authorUsername ?? "") 的主页")

            Text(context.title)
                .font(Theme.body(15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Close, node identity, and the overflow menu. Sizing and glass treatment
    /// match the post reader's floating header so the two read as one system.
    private var topBar: some View {
        HStack(spacing: 12) {
            FloatingHeaderButton(action: onClose) {
                FloatingHeaderIcon(systemName: "xmark")
            }
            .accessibilityLabel("关闭")

            Spacer(minLength: 8)

            if let context {
                Button {
                    withAnimation(.overlayPush) {
                        isShowingNode = true
                    }
                } label: {
                    HStack(spacing: 7) {
                        RemoteAvatar(
                            url: context.nodeLogoURL,
                            letter: context.nodeLetter,
                            size: 22,
                            cornerRadius: 11
                        )
                        Text(context.nodeName)
                            .font(Theme.body(14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(node == nil)
                .accessibilityLabel("打开节点 \(context.nodeName)")
            }

            Spacer(minLength: 8)

            if let pageIndicator {
                Text(pageIndicator)
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .monospacedDigit()
            }

            Menu {
                if let url = context?.shareURL {
                    ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
                }
            } label: {
                FloatingHeaderIcon(systemName: "ellipsis")
            }
            .buttonStyle(.glass(.regular.tint(FloatingHeader.glassTint)))
            .buttonBorderShape(.circle)
            .shadow(color: FloatingHeader.shadow, radius: 9, y: 6)
            .accessibilityLabel("更多")
        }
        .padding(.horizontal, FloatingHeader.horizontalInset)
        .padding(.top, 8)
        .padding(.bottom, 14)
        // Keeps white text legible over bright media.
        .background {
            LinearGradient(
                colors: [.black.opacity(0.55), .black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
    }
}

/// Like / comment / share row pinned to the bottom of the full-screen player.
private struct PostVideoActionBar: View {
    let context: PostVideoContext
    var onLike: (() -> Void)?
    var onComment: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                onLike?()
            } label: {
                pill {
                    Image(systemName: context.isLiked ? "arrow.up.circle.fill" : "arrow.up")
                        .foregroundStyle(context.isLiked ? Theme.love : .white)
                    Text(Self.compact(context.likeCount))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(context.isLiked ? "取消点赞" : "点赞")

            Button {
                onComment?()
            } label: {
                pill {
                    Image(systemName: "bubble.left")
                    Text(Self.compact(context.commentCount))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("评论")

            if let url = context.shareURL {
                ShareLink(item: url) {
                    pill {
                        Image(systemName: "arrow.2.squarepath")
                        Text("转发")
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        // Insets and the scrim come from the enclosing bottom stack, so the
        // caption, transport row and this row share one gradient.
        .font(Theme.body(13, weight: .semibold))
        .foregroundStyle(.white)
    }

    private func pill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            content()
        }
        .font(Theme.body(13, weight: .semibold))
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(.white.opacity(0.16), in: Capsule())
    }

    /// 18300 → "1.8万", matching the feed's counts.
    static func compact(_ value: Int) -> String {
        if value >= 10_000 {
            return String(format: "%.1f万", Double(value) / 10_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

/// One page of the full-screen pager. Only the active page plays, so scrolling
/// away stops the audio.
private struct FullScreenVideoPage: View {
    let video: PostVideo
    let isActive: Bool
    /// Owned by the pager so every control hides and shows together.
    @Binding var isChromeVisible: Bool
    /// Published to, not read from: the transport row is drawn by the pager so
    /// it can sit between the caption and the action buttons.
    let transport: VideoTransportState

    @State private var player: AVPlayer?
    @State private var timeObserver: Any?
    @Environment(VideoMuteState.self) private var mute

    var body: some View {
        ZStack {
            Color.black

            if let player {
                // Fills the page and lets `.resizeAspect` on the player layer
                // do the letterboxing. A SwiftUI `.aspectRatio(contentMode:
                // .fit)` here would collapse the view — a `UIViewRepresentable`
                // has no intrinsic size, so there is no ratio to fit — and the
                // bottom alignment then dropped the video into the lower half.
                InlineVideoSurface(player: player, gravity: .resizeAspect)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.quick) { isChromeVisible.toggle() }
        }
        .onAppear(perform: prepare)
        .onDisappear(perform: teardown)
        .onChange(of: isActive) { _, active in
            if active {
                player?.play()
                publishControls()
            } else {
                player?.pause()
            }
            if active { transport.isPlaying = true }
        }
        .onChange(of: mute.isMuted) { _, muted in player?.isMuted = muted }
    }

    private func prepare() {
        guard player == nil, let url = PostInlineRenderer.resolvedLink(video.src) else { return }
        let player = AVPlayer(url: url)
        player.isMuted = mute.isMuted
        player.actionAtItemEnd = .none
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            Task { @MainActor in player.seek(to: .zero); player.play() }
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { time in
            Task { @MainActor in
                // Only the visible page drives the shared transport row.
                guard isActive, !transport.isScrubbing else { return }
                let total = player.currentItem?.duration.seconds ?? 0
                if total.isFinite, total > 0 {
                    transport.duration = total
                    transport.progress = min(max(time.seconds / total, 0), 1)
                }
            }
        }

        self.player = player
        if isActive {
            player.play()
            publishControls()
        }
    }

    /// Hands the pager's transport row a way to drive this page's player.
    private func publishControls() {
        transport.togglePlayback = {
            guard let player else { return }
            if player.timeControlStatus == .playing {
                player.pause()
                transport.isPlaying = false
            } else {
                player.play()
                transport.isPlaying = true
            }
        }
        transport.seek = { fraction in
            guard let player, transport.duration > 0 else { return }
            player.seek(to: CMTime(seconds: transport.duration * fraction, preferredTimescale: 600))
        }
    }

    private func teardown() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
    }
}

/// Play/pause, scrub track, elapsed time and mute. Driven by whichever page is
/// on screen through `VideoTransportState`.
private struct VideoTransportBar: View {
    let transport: VideoTransportState
    @Environment(VideoMuteState.self) private var mute

    var body: some View {
        HStack(spacing: 12) {
            Button { transport.togglePlayback?() } label: {
                Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(transport.isPlaying ? "暂停" : "播放")

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule()
                        .fill(.white)
                        .frame(width: proxy.size.width * transport.progress)
                    Circle()
                        .fill(.white)
                        .frame(width: 11, height: 11)
                        .offset(x: proxy.size.width * transport.progress - 5.5)
                }
                .contentShape(Rectangle().inset(by: -12))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            transport.isScrubbing = true
                            transport.progress = min(max(value.location.x / proxy.size.width, 0), 1)
                        }
                        .onEnded { _ in
                            transport.seek?(transport.progress)
                            transport.isScrubbing = false
                        }
                )
            }
            .frame(height: 11)

            Text(Self.timestamp(transport.progress * transport.duration))
                .font(Theme.body(11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .monospacedDigit()

            Button {
                mute.isMuted.toggle()
            } label: {
                Image(systemName: mute.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(mute.isMuted ? "取消静音" : "静音")
        }
    }

    private static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Paged full-screen viewer with pinch-zoom.
///
/// `selection` is a binding rather than `@State`: `@State` only reads its
/// initial value once, so opening the viewer on a different image while it is
/// already presented would keep showing the first one.
struct PostImageViewer: View {
    let images: [PostImage]
    @Binding var selection: Int
    /// Same post identity the video viewer shows. Optional so the post detail's
    /// inline images can still open without it.
    var context: PostVideoContext?
    var node: SidebarNodeSummary?
    var author: UserProfileTarget?
    var onLike: (() -> Void)?
    var onComment: (() -> Void)?
    let onClose: () -> Void

    @State private var isChromeVisible = true
    /// Drag-to-dismiss: how far the image has been pulled down.
    @State private var dragOffset: CGFloat = 0
    /// nil until this gesture's direction is decided; false = it's a page
    /// swipe or upward drag, leave it to the TabView.
    @State private var isDismissDrag: Bool?
    /// Zoomed images pan with the drag instead of dismissing.
    @State private var isZoomed = false

    var body: some View {
        MediaViewerChrome(
            context: context,
            pageIndicator: images.count > 1 ? "\(selection + 1)/\(images.count)" : nil,
            node: node,
            author: author,
            onLike: onLike,
            onComment: onComment,
            backgroundOpacity: 1 - Double(min(max(dragOffset, 0) / 500, 0.8)),
            onClose: onClose,
            isVisible: $isChromeVisible
        ) {
            TabView(selection: $selection) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    ZoomableImage(
                        urlString: image.fullSizeURLString,
                        onToggleChrome: {
                            withAnimation(.quick) { isChromeVisible.toggle() }
                        },
                        onZoomChanged: { isZoomed = $0 }
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Telegram-style: the image follows the finger down and shrinks a
            // little while the room dims out behind it.
            .offset(y: dragOffset)
            .scaleEffect(max(1 - dragOffset / 1400, 0.85))
            .simultaneousGesture(dismissDragGesture, isEnabled: !isZoomed)
        }
    }

    /// Vertical pull dismisses; horizontal swipes stay with the pager. The
    /// direction is decided once per gesture from its first movement.
    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if isDismissDrag == nil {
                    let translation = value.translation
                    isDismissDrag = translation.height > 0
                        && abs(translation.height) > abs(translation.width) * 1.2
                    if isDismissDrag == true {
                        withAnimation(.quick) { isChromeVisible = false }
                    }
                }
                guard isDismissDrag == true else { return }
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                let wasDismissDrag = isDismissDrag == true
                isDismissDrag = nil
                guard wasDismissDrag else { return }
                if dragOffset > 130 || value.velocity.height > 900 {
                    onClose()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        dragOffset = 0
                    }
                    withAnimation(.quick) { isChromeVisible = true }
                }
            }
    }
}

/// Pinch to zoom, drag to pan while zoomed, double-tap to toggle.
private struct ZoomableImage: View {
    let urlString: String
    var onToggleChrome: (() -> Void)?
    /// Reports zoomed-in state so the viewer disables drag-to-dismiss while
    /// the drag should pan the magnified image instead.
    var onZoomChanged: ((Bool) -> Void)?

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    /// Measured so panning can be bounded to the image's actual edges.
    @State private var containerSize: CGSize = .zero
    @State private var imageSize: CGSize = .zero

    private let maxScale: CGFloat = 6

    var body: some View {
        // Full resolution: this view zooms to 6x, so a screen-sized decode
        // would go soft the moment it is magnified.
        CachedRemoteImage(
            url: PostInlineRenderer.resolvedLink(urlString),
            maxPointSize: CachedRemoteImage<EmptyView, EmptyView>.fullResolution
        ) { image in
            image
                .resizable()
                .scaledToFit()
                // The displayed (pre-zoom) size, needed to compute pan limits.
                .onGeometryChange(for: CGSize.self) { $0.size } action: { imageSize = $0 }
        } placeholder: {
            ProgressView().tint(.white)
        }
        .scaleEffect(scale)
        .offset(offset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { containerSize = $0 }
        .gesture(panGesture, isEnabled: scale > 1)
        .gesture(zoomGesture)
        .onTapGesture(count: 2, perform: toggleZoom)
        // Single tap hides the chrome, matching the video viewer. Ordered after
        // the double tap so it doesn't swallow it.
        .onTapGesture { onToggleChrome?() }
    }

    /// Only active while zoomed in, so it never competes with the pager's
    /// horizontal swipe at 1×.
    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = clamped(CGSize(
                    width: committedOffset.width + value.translation.width,
                    height: committedOffset.height + value.translation.height
                ))
            }
            .onEnded { _ in committedOffset = offset }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged {
                scale = min(max(committedScale * $0.magnification, 1), maxScale)
                onZoomChanged?(scale > 1.01)
            }
            .onEnded { _ in
                committedScale = scale
                onZoomChanged?(scale > 1.01)
                // Zooming out can leave the image off-centre; pull it back.
                withAnimation(.easeOut(duration: 0.2)) {
                    offset = clamped(offset)
                    committedOffset = offset
                }
            }
    }

    private func toggleZoom() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if scale > 1 {
                scale = 1
                offset = .zero
            } else {
                scale = 2.5
            }
            committedScale = scale
            committedOffset = offset
        }
        onZoomChanged?(scale > 1.01)
    }

    /// Keeps the image's edges from being dragged inside the screen. When an
    /// axis is smaller than the container even zoomed, it stays centred.
    private func clamped(_ proposed: CGSize) -> CGSize {
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        let limitX = max((scaledWidth - containerSize.width) / 2, 0)
        let limitY = max((scaledHeight - containerSize.height) / 2, 0)
        return CGSize(
            width: min(max(proposed.width, -limitX), limitX),
            height: min(max(proposed.height, -limitY), limitY)
        )
    }
}

// MARK: - Code

struct PostCodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(Theme.body(10, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.5))
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            // Horizontal scroll rather than wrapping: wrapped code is unreadable.
            // The ScrollView must be clamped, or its content's intrinsic width
            // leaks out and widens the post instead of scrolling.
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.text.opacity(0.9))
                    .textSelection(.enabled)
                    .padding(12)
            }
            .scrollIndicators(.hidden)
            .clampedToWidth()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
    }
}

// MARK: - Quotes

struct PostQuoteView: View {
    let quote: PostQuote
    let metrics: PostTextMetrics
    var onImageTap: ((PostImage) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if quote.username != nil || quote.topicTitle != nil {
                HStack(spacing: 7) {
                    if let avatar = quote.avatarURL {
                        CachedRemoteImage(url: PostInlineRenderer.resolvedLink(avatar)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Circle().fill(Theme.hover)
                        }
                        .frame(width: 18, height: 18)
                        .clipShape(Circle())
                    }
                    if let username = quote.username {
                        Text(username)
                            .font(Theme.body(12, weight: .semibold))
                            .foregroundStyle(Theme.text.opacity(0.75))
                    }
                    if let title = quote.topicTitle {
                        Text(title)
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.muted(0.5))
                            .lineLimit(1)
                    }
                }
            }

            ForEach(quote.blocks) { block in
                PostBlockView(block: block, metrics: metrics.nested(), onImageTap: onImageTap)
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 2)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.accent.opacity(0.45))
                .frame(width: 3)
                .clipShape(Capsule())
        }
    }
}

struct PostBlockquoteView: View {
    let blocks: [PostBlock]
    let metrics: PostTextMetrics
    var onImageTap: ((PostImage) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                PostBlockView(block: block, metrics: metrics.nested(), onImageTap: onImageTap)
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.divider)
                .frame(width: 3)
                .clipShape(Capsule())
        }
    }
}

// MARK: - Lists

struct PostListView: View {
    let ordered: Bool
    let items: [[PostBlock]]
    let metrics: PostTextMetrics
    var onImageTap: ((PostImage) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, blocks in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ordered ? "\(index + 1)." : "•")
                        .font(Theme.body(metrics.bodySize, weight: ordered ? .medium : .bold))
                        .foregroundStyle(Theme.muted(0.5))
                        .frame(minWidth: ordered ? 18 : 10, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(blocks) { block in
                            PostBlockView(block: block, metrics: metrics, onImageTap: onImageTap)
                        }
                    }
                    // Item content wraps to the width left after the bullet.
                    .clampedToWidth()
                }
            }
        }
        .clampedToWidth()
    }
}

// MARK: - Table

struct PostTableView: View {
    let headers: [[PostInline]]
    let rows: [[[PostInline]]]
    let metrics: PostTextMetrics

    @Environment(EmojiImageStore.self) private var emoji

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                if !headers.isEmpty {
                    row(headers, isHeader: true)
                    Divider().overlay(Theme.divider)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                    row(cells, isHeader: false)
                    if index < rows.count - 1 {
                        Divider().overlay(Theme.divider.opacity(0.6))
                    }
                }
            }
            .padding(10)
        }
        .scrollIndicators(.hidden)
        // Without this the table scrolls *and* widens the post.
        .clampedToWidth()
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
    }

    private func row(_ cells: [[PostInline]], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                PostInlineRenderer.text(for: cell, metrics: metrics, emoji: emoji)
                    .font(Theme.body(metrics.bodySize - 2, weight: isHeader ? .semibold : .regular))
                    .foregroundStyle(Theme.text.opacity(isHeader ? 0.95 : 0.82))
                    // Cells can hold long URLs; cap them so one cell can't make
                    // the table absurdly wide even though it scrolls.
                    .frame(minWidth: 64, maxWidth: 260, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Details / spoiler

struct PostDetailsView: View {
    let summary: [PostInline]
    let blocks: [PostBlock]
    let metrics: PostTextMetrics
    var onImageTap: ((PostImage) -> Void)?

    @State private var isExpanded = false
    @Environment(EmojiImageStore.self) private var emoji

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.quicker) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    PostInlineRenderer.text(for: summary, metrics: metrics, emoji: emoji)
                        .font(Theme.body(metrics.bodySize - 1, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.text.opacity(0.8))
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(blocks) { block in
                    PostBlockView(block: block, metrics: metrics, onImageTap: onImageTap)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
    }
}

struct PostSpoilerView: View {
    let blocks: [PostBlock]
    let metrics: PostTextMetrics
    var onImageTap: ((PostImage) -> Void)?

    @State private var isRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                PostBlockView(block: block, metrics: metrics, onImageTap: onImageTap)
            }
        }
        .padding(8)
        // Fill the row so the scrim covers the content rather than sitting
        // beside it.
        .frame(maxWidth: .infinity, alignment: .leading)
        // Blur stays constant and the *overlay* fades. Animating blur radius
        // itself flickers on iOS (the reveal snaps back mid-animation).
        .blur(radius: isRevealed ? 0 : 11)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.hover)
                .opacity(isRevealed ? 0 : 0.92)
                .overlay {
                    if !isRevealed {
                        Label("点击查看", systemImage: "eye.slash")
                            .font(Theme.body(12, weight: .semibold))
                            .foregroundStyle(Theme.muted(0.65))
                    }
                }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.22)) { isRevealed.toggle() }
        }
        .accessibilityLabel(isRevealed ? "剧透内容已显示" : "剧透内容，点击查看")
    }
}

// MARK: - Onebox

struct PostOneboxView: View {
    let onebox: PostOnebox
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let imageURL = onebox.imageURL {
                CachedRemoteImage(url: PostInlineRenderer.resolvedLink(imageURL)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Theme.hover
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 4) {
                if let title = onebox.title {
                    // `lineLimit` alone doesn't help: an unbreakable title still
                    // reports a wide minimum width.
                    Text(title.breakingLongTokens())
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                }
                if let description = onebox.descriptionText {
                    Text(description.breakingLongTokens())
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.6))
                        .lineLimit(2)
                }
                if let host = onebox.url.flatMap({ PostInlineRenderer.resolvedLink($0)?.host }) {
                    HStack(spacing: 4) {
                        if let favicon = onebox.faviconURL {
                            CachedRemoteImage(url: PostInlineRenderer.resolvedLink(favicon)) { image in
                                image.resizable().scaledToFit()
                            } placeholder: {
                                EmptyView()
                            }
                            .frame(width: 12, height: 12)
                        }
                        Text(host)
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.muted(0.45))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            if let url = onebox.url.flatMap({ PostInlineRenderer.resolvedLink($0) }) {
                openURL(url)
            }
        }
    }
}

// MARK: - Previews

#Preview("Full screen video chrome") {
    PostVideoPager(
        videos: [
            PostVideo(src: "https://www.nodeloc.com/uploads/default/original/3X/0/d/" +
                           "0123456789abcdef0123456789abcdef01234567.mp4")
        ],
        startingAt: 0,
        context: PostVideoContext(
            nodeName: "n/MemeVideos",
            nodeLogoURL: nil,
            nodeColorHex: "E45735",
            title: "哥们找到了作弊码",
            authorUsername: "Spiritual-Pudding-70",
            authorAvatarURL: nil,
            likeCount: 18300,
            isLiked: false,
            commentCount: 569,
            shareURL: URL(string: "https://www.nodeloc.com/t/topic/86774")
        ),
        onLike: {},
        onComment: {},
        node: SidebarNodeSummary(
            id: 1, name: "MemeVideos", slug: "memevideos", description: "",
            memberCount: "1k", colorHex: "E45735", logoURL: nil,
            isCreator: false, isJoined: false, url: "/n/memevideos"
        ),
        author: UserProfileTarget(username: "Spiritual-Pudding-70"),
        onClose: {}
    )
    .environment(VideoMuteState.shared)
    .environment(AppState())
}

