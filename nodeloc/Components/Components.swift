//
//  Components.swift
//  nodeloc
//
//  Reusable UI primitives built from the Nocturne tokens.
//

import CryptoKit
import SwiftUI
import UIKit

// MARK: - Brand

struct NodelocLogo: View {
    var markSize: CGFloat = 30
    var wordSize: CGFloat = 19

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: markSize * 0.3, style: .continuous)
                .fill(Theme.accent)
                .frame(width: markSize, height: markSize)
            Text("NODELOC")
                .font(Theme.heading(wordSize, weight: .semibold))
                .tracking(-0.4)
        }
    }
}

// MARK: - Avatar

struct Avatar: View {
    let letter: String
    var variant: Int = 0
    var size: CGFloat = 34
    var cornerRadius: CGFloat? = nil   // nil == circle
    /// Explicit override colors (used for the current-user avatar).
    var bg: Color? = nil
    var fg: Color? = nil

    var body: some View {
        let palette = Theme.avatarColors(variant)
        let fill = bg ?? palette.bg
        let text = fg ?? palette.fg
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? size / 2, style: .continuous)
        Text(letter)
            .font(Theme.heading(size * 0.36, weight: .semibold))
            .foregroundStyle(text)
            .frame(width: size, height: size)
            .background(fill, in: shape)
    }
}

struct RemoteAvatar: View {
    let url: URL?
    let letter: String
    var variant: Int = 0
    var size: CGFloat = 34
    var cornerRadius: CGFloat? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? size / 2, style: .continuous)

        Group {
            if let url {
                CachedRemoteImage(url: url) { image in
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
        .background(Theme.neutral300, in: shape)
        .clipShape(shape)
    }

    private var fallback: some View {
        Avatar(letter: letter, variant: variant, size: size, cornerRadius: cornerRadius)
    }
}

final class RemoteImageMemoryCache {
    static let shared = RemoteImageMemoryCache()

    private let cache = NSCache<NSString, UIImage>()
    /// Decode sizes seen per URL, so a request can reuse a copy that was
    /// decoded at least as large. Without this, an avatar decoded at 132px
    /// would satisfy nothing else and every size would miss.
    private var sizesByURL: [String: Set<Int>] = [:]
    private let lock = NSLock()

    private init() {
        cache.countLimit = 240
        cache.totalCostLimit = 48 * 1024 * 1024
        // NSCache evicts under pressure on its own, but the size index would
        // then point at entries that are gone.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.removeAll()
        }
    }

    /// Returns a cached copy decoded at `atLeast` pixels or larger. Drawing a
    /// bigger image smaller is free; the reverse would look soft.
    func image(for url: URL, atLeast maxPixel: Int) -> UIImage? {
        if let exact = cache.object(forKey: Self.key(url, maxPixel) as NSString) {
            return exact
        }
        lock.lock()
        let sizes = sizesByURL[url.absoluteString] ?? []
        lock.unlock()
        // 0 means full resolution, which satisfies any request.
        let candidates = sizes.filter { $0 == 0 || (maxPixel > 0 && $0 >= maxPixel) }
        // Smallest sufficient copy, to keep memory down.
        let ordered = candidates.sorted { lhs, rhs in
            if lhs == 0 { return false }
            if rhs == 0 { return true }
            return lhs < rhs
        }
        for size in ordered {
            if let hit = cache.object(forKey: Self.key(url, size) as NSString) {
                return hit
            }
            // NSCache evicts individual objects without telling us, so the
            // index can outlive its entry. Drop the stale record rather than
            // letting it keep pointing at nothing.
            lock.lock()
            sizesByURL[url.absoluteString]?.remove(size)
            if sizesByURL[url.absoluteString]?.isEmpty == true {
                sizesByURL[url.absoluteString] = nil
            }
            lock.unlock()
        }
        return nil
    }

    func insert(_ image: UIImage, for url: URL, maxPixel: Int) {
        let scale = image.scale
        let cost = Int(image.size.width * scale * image.size.height * scale * 4)
        cache.setObject(image, forKey: Self.key(url, maxPixel) as NSString, cost: max(cost, 1))
        lock.lock()
        sizesByURL[url.absoluteString, default: []].insert(maxPixel)
        lock.unlock()
    }

    func removeAll() {
        cache.removeAllObjects()
        lock.lock()
        sizesByURL.removeAll()
        lock.unlock()
    }

    private static func key(_ url: URL, _ maxPixel: Int) -> String {
        "\(url.absoluteString)@\(maxPixel)"
    }
}

/// Disk-backed image loader. Persists downloads under Caches/ so avatars and
/// banners survive relaunches instead of being refetched every time, and
/// coalesces concurrent requests for the same URL.
///
/// Not private: inline post emoji load through this directly rather than via
/// `CachedRemoteImage`, because they render inside a `Text` run rather than as
/// their own view.
actor RemoteImageDiskCache {
    static let shared = RemoteImageDiskCache()

    private let directory: URL
    private var inFlight: [Key: Task<UIImage?, Never>] = [:]

    /// One entry per (url, decode size): the same photo shown as a 44pt avatar
    /// and as a full-screen image are different decodes and must not collide.
    private struct Key: Hashable {
        let url: URL
        let maxPixel: Int
    }

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appending(path: "RemoteImages", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// `maxPixel` caps the longest edge of the decoded image. Pass 0 for a
    /// full-resolution decode (the full-screen viewer, which can zoom).
    func image(for url: URL, maxPixel: Int = 0) async -> UIImage? {
        let key = Key(url: url, maxPixel: maxPixel)
        if let existing = inFlight[key] { return await existing.value }

        let file = Self.fileURL(for: url, in: directory)
        // Detached so the download/decode never runs on this actor (or the main actor).
        let task = Task.detached(priority: .utility) { () -> UIImage? in
            if let data = try? Data(contentsOf: file) {
                // Touch so the pruner treats a re-read file as recently used.
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date()], ofItemAtPath: file.path
                )
                if let image = Self.decode(data, maxPixel: maxPixel) { return image }
            }
            guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
            guard let image = Self.decode(data, maxPixel: maxPixel) else { return nil }
            // Only cache what actually decoded. Writing an HTML error page or
            // an SVG here would make every later view re-read and re-fail on
            // it, which is how one bad URL fills the console.
            try? data.write(to: file, options: .atomic)
            return image
        }

        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    /// Decodes straight to the size we'll draw at.
    ///
    /// `UIImage(data:)` inflates the full pixel buffer no matter how small the
    /// view is — a 1080×1350 feed photo costs ~5.8 MB even when drawn 365pt
    /// wide. ImageIO's thumbnail path decodes once, at the target size.
    nonisolated static func decode(_ data: Data, maxPixel: Int) -> UIImage? {
        guard maxPixel > 0 else { return UIImage(data: data) }
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            return UIImage(data: data)
        }
        // ImageIO logs a noisy `CGImageSourceCreateThumbnailAtIndex … [-50]` to
        // the console for anything it can't rasterise — an HTML error page, an
        // SVG, a truncated download. Checking the source is complete and has a
        // decodable image first keeps that out of the log entirely, rather than
        // relying on the call to fail quietly.
        guard CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0 else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    /// Trims the cache directory. Called at launch.
    ///
    /// Nothing pruned this before, so it grew for the life of the install. iOS
    /// may purge `Caches/` wholesale under storage pressure, which is worse
    /// than a bounded trim: it takes the whole cache instead of the cold tail.
    func prune(maxAge: TimeInterval = 14 * 24 * 3600, maxBytes: Int = 256 * 1024 * 1024) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: .skipsHiddenFiles
        ) else { return }

        struct Entry {
            let url: URL
            let modified: Date
            let size: Int
        }

        let cutoff = Date().addingTimeInterval(-maxAge)
        var kept: [Entry] = []
        for file in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            let size = values.fileSize ?? 0
            if modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            } else {
                kept.append(Entry(url: file, modified: modified, size: size))
            }
        }

        var total = kept.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        // Coldest first, so recently viewed images survive.
        for entry in kept.sorted(by: { $0.modified < $1.modified }) {
            guard total > maxBytes else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private static func fileURL(for url: URL, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return directory.appending(path: digest.map { String(format: "%02x", $0) }.joined())
    }
}

struct CachedRemoteImage<Content: View, Placeholder: View>: View {
    let url: URL?
    /// Longest edge to decode to, in points. Nil measures the view and uses
    /// that; pass `.fullResolution` for the zoomable full-screen viewer.
    var maxPointSize: CGFloat?
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var measured: CGFloat = 0

    /// Sentinel for "decode at native size" — the image viewer zooms to 6x, so
    /// downsampling it to the screen would show a soft picture when magnified.
    static var fullResolution: CGFloat { 0 }

    init(
        url: URL?,
        maxPointSize: CGFloat? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.maxPointSize = maxPointSize
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                content(Image(uiImage: image))
            } else {
                placeholder()
            }
        }
        // Measured so the decode matches the drawn size.
        .onGeometryChange(for: CGFloat.self) { proxy in
            max(proxy.size.width, proxy.size.height)
        } action: { side in
            guard maxPointSize == nil, side > 0 else { return }
            // Only grow, and only meaningfully: a card that settles from 300 to
            // 320pt must not trigger a second decode, and shrinking should
            // never discard a copy that is already good enough.
            if side > measured * 1.5 { measured = side }
        }
        .task(id: TaskKey(url: url, maxPixel: decodeMaxPixel)) {
            await loadImage()
        }
    }

    private struct TaskKey: Equatable {
        let url: URL?
        let maxPixel: Int?
    }

    /// Pixels, not points: decoding to points on a 3x screen would be blurry.
    ///
    /// Returns nil while an auto-sized view hasn't been measured. Loading then
    /// would decode at full resolution — the exact cost this type exists to
    /// avoid — and the later measured decode would replace it, so the work is
    /// wasted twice over.
    private var decodeMaxPixel: Int? {
        if let maxPointSize {
            // An explicit 0 means "native size", for the zoomable viewer.
            guard maxPointSize > 0 else { return 0 }
            return Int(maxPointSize * UITraitCollection.current.displayScale)
        }
        guard measured > 0 else { return nil }
        return Int(measured * UITraitCollection.current.displayScale)
    }

    @MainActor
    private func loadImage() async {
        guard let url else {
            image = nil
            return
        }
        // Wait for the measurement; `onGeometryChange` re-runs this task.
        guard let maxPixel = decodeMaxPixel else { return }

        // Memory hit: show synchronously, no flicker. A cached copy decoded at
        // least as large as we need is fine — scaling down for display is free.
        if let cached = RemoteImageMemoryCache.shared.image(for: url, atLeast: maxPixel) {
            image = cached
            return
        }

        // Disk hit (or network, then persisted to disk).
        guard let loaded = await RemoteImageDiskCache.shared.image(for: url, maxPixel: maxPixel) else { return }
        RemoteImageMemoryCache.shared.insert(loaded, for: url, maxPixel: maxPixel)
        image = loaded
    }
}

// MARK: - Group flair (资质)

/// A user's group flair. Discourse stores this either as a Font Awesome icon
/// name (e.g. "certificate", "chess-queen") or as an uploaded image path.
struct UserFlair: Equatable {
    let name: String?
    let iconName: String?
    let imageURL: URL?
    let foreground: Color
    let background: Color

    init?(
        flairURL: String?,
        name: String?,
        bgColor: String?,
        color: String?,
        resolveImage: (String) -> URL?
    ) {
        guard let flairURL, !flairURL.isEmpty else { return nil }
        self.name = name

        if flairURL.hasPrefix("/") || flairURL.hasPrefix("http") {
            imageURL = resolveImage(flairURL)
            iconName = nil
        } else {
            imageURL = nil
            iconName = Self.symbol(for: flairURL)
        }

        // Discourse sends bare hex without the leading '#'.
        background = Color(cssColor: bgColor.map { "#\($0)" }) ?? Theme.accent
        foreground = Color(cssColor: color.map { "#\($0)" }) ?? .white
    }

    /// Maps the Font Awesome names used for flair onto SF Symbols.
    private static func symbol(for faName: String) -> String {
        let key = faName
            .replacingOccurrences(of: "fab-", with: "")
            .replacingOccurrences(of: "far-", with: "")
            .replacingOccurrences(of: "fas-", with: "")
        switch key {
        case "certificate": return "checkmark.seal.fill"
        case "medal": return "medal.fill"
        case "chess-queen", "crown": return "crown.fill"
        case "alipay", "cc-visa", "credit-card": return "creditcard.fill"
        case "shield", "shield-alt", "shield-halved": return "shield.fill"
        case "star": return "star.fill"
        case "heart": return "heart.fill"
        case "bolt": return "bolt.fill"
        case "gem", "diamond": return "diamond.fill"
        case "user-tie", "user-shield": return "person.fill.badge.plus"
        case "wrench", "screwdriver-wrench": return "wrench.fill"
        case "code": return "chevron.left.forwardslash.chevron.right"
        case "graduation-cap": return "graduationcap.fill"
        case "trophy": return "trophy.fill"
        case "fire", "fire-flame-curved": return "flame.fill"
        case "rocket": return "paperplane.fill"
        case "thumbs-up": return "hand.thumbsup.fill"
        default: return "rosette"
        }
    }
}

/// Small circular flair chip rendered after @username.
struct FlairBadge: View {
    let flair: UserFlair
    var size: CGFloat = 18

    var body: some View {
        Circle()
            .fill(flair.background)
            .frame(width: size, height: size)
            .overlay {
                if let imageURL = flair.imageURL {
                    CachedRemoteImage(url: imageURL) { image in
                        image.resizable().scaledToFit().padding(size * 0.18)
                    } placeholder: {
                        icon
                    }
                } else {
                    icon
                }
            }
            .clipShape(Circle())
            .accessibilityLabel(flair.name ?? "flair")
    }

    private var icon: some View {
        Image(systemName: flair.iconName ?? "rosette")
            .font(.system(size: size * 0.56, weight: .bold))
            .foregroundStyle(flair.foreground)
    }
}

// MARK: - Custom badge / title styling (discourse-custom-badge plugin)

/// Resolved style for a user title, mirroring the plugin's
/// `{ text_color, text_effect, glitch_*_color }` schema.
struct TitleStyle: Equatable {
    var textColor: Color
    var effect: Effect
    var glitchLeft: Color = Color(red: 0.145, green: 0.957, blue: 0.933)   // #25f4ee
    var glitchRight: Color = Color(red: 0.996, green: 0.173, blue: 0.333)  // #fe2c55

    enum Effect: String, Equatable {
        case none
        case shimmer
        case goldFlow = "gold-flow"
        case silverFlow = "silver-flow"
        case rainbowFlow = "rainbow-flow"
        case auroraFlow = "aurora-flow"
        case fireFlow = "fire-flow"
        case oceanFlow = "ocean-flow"
        case galaxyFlow = "galaxy-flow"
        case lavaFlow = "lava-flow"
        case laserSweep = "laser-sweep"
        case holographicFlow = "holographic-flow"
        case dualFlow = "dual-flow"
        case glitchShadow = "glitch-shadow"

        /// Legacy alias kept by the plugin's StyleValidator.
        nonisolated init(pluginValue: String?) {
            let raw = pluginValue == "color-flow" ? "rainbow-flow" : (pluginValue ?? "none")
            self = Effect(rawValue: raw) ?? .none
        }

        /// Extra gradient stops layered over the base text color, approximating
        /// the plugin's CSS gradients (which reference Discourse theme vars).
        var gradientAccents: [Color] {
            switch self {
            case .goldFlow: return [Color(hex: 0xFFD466), Color(hex: 0xF7E58D)]
            case .silverFlow: return [Color(hex: 0xE8EAED), Color(hex: 0xB0B6BE)]
            case .rainbowFlow: return [Color(hex: 0x4C8DFF), Color(hex: 0xE0245E), Color(hex: 0xFFB020), Color(hex: 0x22C55E)]
            case .auroraFlow: return [Color(hex: 0x22C55E), Color(hex: 0x38BDF8), Color(hex: 0xA855F7)]
            case .fireFlow: return [Color(hex: 0xF97316), Color(hex: 0xEF4444)]
            case .oceanFlow: return [Color(hex: 0x38BDF8), Color(hex: 0x0EA5E9), Color(hex: 0x6366F1)]
            case .galaxyFlow: return [Color(hex: 0x8B5CF6), Color(hex: 0xE0245E), Color(hex: 0x38BDF8)]
            case .lavaFlow: return [Color(hex: 0xEF4444), Color(hex: 0xFFB020)]
            case .laserSweep, .shimmer: return [.white]
            case .holographicFlow: return [Color(hex: 0x38BDF8), Color(hex: 0x22C55E), Color(hex: 0xA855F7), Color(hex: 0xE0245E)]
            case .dualFlow: return [Color(hex: 0x38BDF8)]
            case .none, .glitchShadow: return []
            }
        }

        var animationDuration: Double {
            switch self {
            case .shimmer: return 2.8
            case .goldFlow: return 4.4
            case .silverFlow, .rainbowFlow: return 5
            case .auroraFlow: return 7
            case .fireFlow: return 3.5
            case .oceanFlow: return 6
            case .galaxyFlow: return 8
            case .lavaFlow: return 4
            case .laserSweep: return 2.2
            case .holographicFlow: return 4.8
            case .dualFlow: return 3.8
            case .glitchShadow: return 1.8
            case .none: return 0
            }
        }

        var isAnimated: Bool { self != .none }
    }

    nonisolated init?(_ style: CustomBadgeStyle?) {
        guard let style, let color = Color(cssColor: style.textColor) else { return nil }
        textColor = color
        effect = Effect(pluginValue: style.textEffect)
        if let left = Color(cssColor: style.glitchLeftColor) { glitchLeft = left }
        if let right = Color(cssColor: style.glitchRightColor) { glitchRight = right }
    }
}

/// Renders a user title with its admin-configured color and text effect.
struct StyledTitleText: View {
    let text: String
    let style: TitleStyle
    var font: Font = Theme.body(13, weight: .semibold)

    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        base
            .overlay { if shouldAnimate { sweep.mask(base) } }
            .animation(nil, value: text)
    }

    private var base: some View {
        Text(text)
            .font(font)
            .foregroundStyle(style.textColor)
            .shadow(color: glitchShadowLeft, radius: 0, x: -0.8, y: 0)
            .shadow(color: glitchShadowRight, radius: 0, x: 0.8, y: 0)
    }

    /// Moving gradient band, standing in for the plugin's animated
    /// background-clip gradients.
    private var sweep: some View {
        LinearGradient(
            colors: [.clear] + style.effect.gradientAccents + [.clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .scaleEffect(x: 0.6, anchor: .leading)
        .offset(x: phase * 140)
        .onAppear {
            withAnimation(.linear(duration: style.effect.animationDuration).repeatForever(autoreverses: false)) {
                phase = 1.6
            }
        }
    }

    private var shouldAnimate: Bool {
        !reduceMotion && style.effect.isAnimated && !style.effect.gradientAccents.isEmpty
    }

    private var glitchShadowLeft: Color {
        style.effect == .glitchShadow ? style.glitchLeft.opacity(0.78) : .clear
    }

    private var glitchShadowRight: Color {
        style.effect == .glitchShadow ? style.glitchRight.opacity(0.78) : .clear
    }
}

extension Color {
    /// Parses the CSS color forms the plugin's validator accepts (#rgb, #rgba,
    /// #rrggbb, #rrggbbaa, and a few named colors).
    nonisolated init?(cssColor: String?) {
        guard var value = cssColor?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else {
            return nil
        }

        if value.hasPrefix("#") {
            value.removeFirst()
            // Expand shorthand (#abc / #abcd) to full form.
            if value.count == 3 || value.count == 4 {
                value = value.map { "\($0)\($0)" }.joined()
            }
            guard value.count == 6 || value.count == 8, let bits = UInt64(value, radix: 16) else { return nil }
            let hasAlpha = value.count == 8
            let r = Double((bits >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
            let g = Double((bits >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
            let b = Double((bits >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
            let a = hasAlpha ? Double(bits & 0xFF) / 255 : 1
            self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
            return
        }

        let named: [String: UInt32] = [
            "red": 0xFF0000, "green": 0x008000, "blue": 0x0000FF, "white": 0xFFFFFF,
            "black": 0x000000, "gold": 0xFFD700, "orange": 0xFFA500, "purple": 0x800080,
            "pink": 0xFFC0CB, "cyan": 0x00FFFF, "magenta": 0xFF00FF, "yellow": 0xFFFF00,
            "silver": 0xC0C0C0, "gray": 0x808080, "grey": 0x808080, "teal": 0x008080
        ]
        guard let hex = named[value] else { return nil }
        self = Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Tags

enum TagStyle { case accent, accent2, neutral, outline }

struct TagChip: View {
    let text: String
    var style: TagStyle = .neutral
    var padding: EdgeInsets = EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10)

    var body: some View {
        Text(text)
            .font(Theme.body(11))
            .tracking(0.2)
            .foregroundStyle(foreground)
            .padding(padding)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.radiusMd * 0.75, style: .continuous))
            .overlay {
                if style == .outline {
                    RoundedRectangle(cornerRadius: Theme.radiusMd * 0.75, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 1)
                }
            }
    }

    private var foreground: Color {
        switch style {
        case .accent: return Theme.accent100
        case .accent2: return Theme.accent2_100
        case .neutral: return Theme.neutral100
        case .outline: return Theme.accent
        }
    }
    private var background: Color {
        switch style {
        case .accent: return Theme.accent800
        case .accent2: return Color(hex: 0x804609)
        case .neutral: return Theme.neutral800
        case .outline: return .clear
        }
    }
}

// MARK: - Card container

struct Card<Content: View>: View {
    var background: Color = Theme.surface
    var elevation: Elevation? = .sm
    var padding: CGFloat = Theme.space3
    var axis: Axis = .vertical
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if axis == .vertical {
                VStack(alignment: .leading, spacing: Theme.space2) { content }
            } else {
                HStack(spacing: Theme.space3) { content }
            }
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: axis == .vertical ? .topLeading : .leading)
        .background(background, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
        .modifier(OptionalElevation(level: elevation))
    }
}

private struct OptionalElevation: ViewModifier {
    let level: Elevation?
    func body(content: Content) -> some View {
        if let level { content.elevation(level) } else { content }
    }
}

// MARK: - Segmented control

struct SegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let isSelected = selection == option.value
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(Theme.body(13))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 12)
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                                    .strokeBorder(Theme.accent, lineWidth: 1)
                            }
                        }
                }
                .buttonStyle(.pressable)
                if index < options.count - 1 {
                    Rectangle().fill(Theme.divider).frame(width: 1)
                }
            }
        }
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
    }
}

// MARK: - Text field

struct NodeField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var secure: Bool = false
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(Theme.body(12))
                .foregroundStyle(Theme.muted(0.7))
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(Theme.body(14))
            .textFieldStyle(.plain)
            .tint(Theme.accent)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            }
        }
    }
}

// MARK: - Floating header controls

/// Sizing and glass treatment for the floating headers that sit above scrolling
/// content — the post reader and the full-screen video viewer. Shared so the two
/// can't drift apart.
enum FloatingHeader {
    static let controlHeight: CGFloat = 34
    static let horizontalInset: CGFloat = 16
    static let nodePillWidth: CGFloat = 104
    static let glassTint = Theme.bg.opacity(0.34)
    static let shadow = Color.black.opacity(0.08)
}

/// A circular glass icon button for a screen's top bar. One definition so the
/// sidebar toggle, settings gear and friends are visually identical.
struct HeaderIconButton: View {
    /// A symbol or a bundled image, so the brand mark can sit in one of these
    /// without a second copy of the glass, shadow and sizing below.
    private enum Icon {
        case symbol(String)
        case asset(String)
    }

    private let icon: Icon
    var accessibilityLabel: String
    let action: () -> Void

    init(systemName: String, accessibilityLabel: String, action: @escaping () -> Void) {
        self.icon = .symbol(systemName)
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    init(asset: String, accessibilityLabel: String, action: @escaping () -> Void) {
        self.icon = .asset(asset)
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                switch icon {
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.headerText)
                case .asset(let name):
                    // `.original`, or the asset is template-tinted to
                    // `Theme.headerText` and the mark loses its colours — the
                    // whole point of using it.
                    Image(name)
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        // Larger than the 14pt symbol above: a symbol is drawn
                        // to read at its nominal size, while artwork fills its
                        // box, and at 14 the mark's inner dot was all that
                        // registered. 22 matches the hamburger's visual weight
                        // — measured by rendering them side by side, not
                        // guessed.
                        .frame(width: 22, height: 22)
                }
            }
            .frame(width: FloatingHeader.controlHeight, height: FloatingHeader.controlHeight)
        }
        .glassButton(tint: FloatingHeader.glassTint, shape: .circle)
        .shadow(color: FloatingHeader.shadow, radius: 9, y: 6)
        .accessibilityLabel(accessibilityLabel)
    }
}

extension View {
    /// Moves a root screen's header controls into the iPad tab bar's row.
    ///
    /// On iPad the tab bar is drawn in the navigation bar region at the top of
    /// the content, which is why a floating header of our own lands *below* it
    /// — the tab bar is inside the safe area the header respects. Toolbar items
    /// are what actually sit on the same line, flanking the centred tab
    /// capsule, so each root screen hands its leading and trailing controls
    /// over here and hides its own bar.
    ///
    /// Off iPad this is a no-op, so the phone layout is untouched.
    ///
    /// - Parameter needsNavigationStack: False for screens that already have a
    ///   `NavigationStack` of their own (the inbox drives one with a path);
    ///   nesting a second would break their navigation.
    @ViewBuilder
    func tabBarHeader<Leading: View, Trailing: View>(
        isPinned: Bool,
        needsNavigationStack: Bool = true,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) -> some View {
        if isPinned {
            if needsNavigationStack {
                NavigationStack {
                    tabBarToolbarItems(leading: leading, trailing: trailing)
                }
            } else {
                tabBarToolbarItems(leading: leading, trailing: trailing)
            }
        } else {
            self
        }
    }

    private func tabBarToolbarItems<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) { leading() }
            ToolbarItem(placement: .topBarTrailing) { trailing() }
        }
        // The tab bar already fills this row; a navigation bar background and
        // title would double up on it.
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Opens the sidebar. Shared so every root screen's top-left button is the
/// same control rather than copies that drift apart.
struct SidebarMenuButton: View {
    @Environment(AppState.self) private var app
    @Environment(\.sidebarIsPinned) private var sidebarIsPinned

    var body: some View {
        // Nothing to open when the sidebar is already a permanent column.
        if !sidebarIsPinned {
            // The brand mark rather than a hamburger. It keeps the
            // accessibility label "菜单", because the mark does not say
            // "menu" to anyone who hasn't already learned it — VoiceOver
            // users and the tap target should not have to.
            HeaderIconButton(asset: "NodelocMark", accessibilityLabel: AppString("菜单")) {
                // Matches the drag-to-open animation in MainView.
                withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                    app.overlay = .sidebar
                }
            }
        }
    }
}

/// A circular or capsule glass button for a floating header.
struct FloatingHeaderButton<Label: View>: View {
    var borderShape: GlassShape = .circle
    let action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button(action: action) {
            label
                .frame(height: FloatingHeader.controlHeight)
        }
        .glassButton(tint: FloatingHeader.glassTint, shape: borderShape)
        .shadow(color: FloatingHeader.shadow, radius: 9, y: 6)
    }
}

/// The glyph inside a floating header button, at the shared size and weight.
struct FloatingHeaderIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.text)
            .frame(width: FloatingHeader.controlHeight, height: FloatingHeader.controlHeight)
    }
}

/// A plain search-style text field (no floating label).
struct PlainField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .font(Theme.body(14))
            .textFieldStyle(.plain)
            .tint(Theme.accent)
            .autocorrectionDisabled()
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            }
    }
}

// MARK: - Buttons

/// Outlined accent button (Nocturne `.btn-primary`).
struct PrimaryButtonStyle: ButtonStyle {
    var block = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.heading(14))
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: block ? .infinity : nil)
            .padding(.vertical, Theme.space2)
            .padding(.horizontal, Theme.space3 * 1.2)
            .background(
                Theme.accent.opacity(configuration.isPressed ? 0.22 : 0),
                in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 1)
            }
            .contentShape(Rectangle())
    }
}

/// Neutral outlined button (`.btn-secondary`).
struct SecondaryButtonStyle: ButtonStyle {
    var block = false
    var leadingAligned = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.heading(14))
            .foregroundStyle(Theme.text)
            .frame(maxWidth: block ? .infinity : nil, alignment: leadingAligned ? .leading : .center)
            .padding(.vertical, Theme.space2)
            .padding(.horizontal, leadingAligned ? 16 : Theme.space3 * 1.2)
            .background(
                Theme.text.opacity(configuration.isPressed ? 0.14 : 0),
                in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            }
            .contentShape(Rectangle())
    }
}

/// Text-only accent button (`.btn-ghost`).
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.heading(12))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, Theme.space1)
            .padding(.vertical, 2)
            .background(
                Theme.accent.opacity(configuration.isPressed ? 0.18 : 0),
                in: RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
            )
            .contentShape(Rectangle())
    }
}

// MARK: - Fading rule

struct FadingRule: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: Theme.divider, location: 0.12),
                .init(color: Theme.divider, location: 0.88),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(height: 1)
        .padding(.vertical, Theme.space4)
    }
}

// MARK: - Section header (uppercase kicker)

struct SectionKicker: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.body(11))
            .tracking(0.9)
            .foregroundStyle(Theme.muted(0.5))
    }
}

// MARK: - Skeletons

/// Gentle opacity pulse for skeleton placeholders. Owns its animation state so
/// a skeleton only has to attach the modifier — no per-screen @State needed.
private struct SkeletonPulse: ViewModifier {
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.55 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

extension View {
    func skeletonPulsing() -> some View { modifier(SkeletonPulse()) }
}

/// One grey placeholder line for skeleton screens.
struct SkeletonLine: View {
    var widthFraction: CGFloat = 1
    var height: CGFloat = 13

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Theme.neutral300)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(x: widthFraction, anchor: .leading)
    }
}

// MARK: - Toast

/// App-wide transient notice, for user actions that would otherwise fail
/// silently (bookmark, like, reply). One at a time; new messages replace the
/// current one and restart the clock.
@MainActor
@Observable
final class ToastCenter {
    static let shared = ToastCenter()

    private(set) var message: String?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String) {
        hideTask?.cancel()
        withAnimation(.spring(duration: 0.3)) { message = text }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.message = nil }
        }
    }

    /// The friendly line for a failed action — never the raw error.
    func showError(_ error: Error) {
        show((error as? LocalizedError)?.errorDescription ?? AppString("操作失败，请稍后重试"))
    }
}

/// Mounted once at the root (ContentView); floats over everything.
struct ToastHost: View {
    private var center = ToastCenter.shared

    var body: some View {
        if let message = center.message {
            Text(message)
                .font(Theme.body(13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .glassSurface(tint: Theme.bg.opacity(0.5))
                .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
                .padding(.horizontal, 32)
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Badges

/// One of a user's badges, resolved to something drawable.
///
/// Discourse hands out a FontAwesome name in `icon` and, rarely, uploaded
/// artwork in `image_url`. Neither was being read: the profile drew a rosette on
/// a colour picked from the badge's *position* in the list, so every badge
/// looked the same and none of them looked right.
struct ProfileBadge: Identifiable, Hashable {
    let id: Int
    let name: String
    let description: String
    /// Uploaded artwork, when this badge has some.
    let imageURL: URL?
    /// The bundled FontAwesome glyph, or nil when this badge's icon isn't one
    /// the app carries.
    let assetName: String?
    /// The badge's own colour: `custom_style.text_color` when set, otherwise
    /// its metal.
    let tint: Color

    init(_ badge: SummaryBadge, resolveImage: (String) -> URL?) {
        id = badge.id
        name = badge.name ?? ""
        description = badge.description.map { DiscourseFormat.plainText($0) } ?? ""
        imageURL = badge.imageUrl.flatMap(resolveImage)
        assetName = Self.asset(for: badge.icon)
        tint = Self.tint(customHex: badge.customStyle?.textColor, badgeTypeID: badge.badgeTypeId)
    }

    /// Discourse's own FontAwesome glyphs, not lookalikes.
    ///
    /// The first attempt substituted SF Symbols by hand, which is how a badge
    /// ends up wearing the wrong picture: `share-nodes` is not any SF symbol,
    /// and a near-match reads as a bug. These are the real icons, extracted
    /// from the site's own SVG sprite (`/svg-sprite/…`) into imagesets — every
    /// name in use on nodeloc, all 34 of them, taken from `/badges.json` rather
    /// than imagined.
    ///
    /// Font Awesome Free, CC BY 4.0 — https://fontawesome.com/license/free
    ///
    /// A name that isn't here falls back to an SF rosette; that is visibly a
    /// generic badge rather than the wrong specific one.
    private static let assetsByIcon: [String: String] = [
        "at": "FaAt",
        "book-open-reader": "FaBookOpenReader",
        "cake-candles": "FaCakeCandles",
        "certificate": "FaCertificate",
        "cube": "FaCube",
        "discourse-sparkles": "FaDiscourseSparkles",
        "envelope": "FaEnvelope",
        "eye": "FaEye",
        "face-smile": "FaFaceSmile",
        "far-eye": "FaFarEye",
        "far-heart": "FaFarHeart",
        "far-pen-to-square": "FaFarPenToSquare",
        "far-star": "FaFarStar",
        "file-lines": "FaFileLines",
        "file-signature": "FaFileSignature",
        "flag": "FaFlag",
        "gem": "FaGem",
        "gift": "FaGift",
        "heart": "FaHeart",
        "icicles": "FaIcicles",
        "link": "FaLink",
        "medal": "FaMedal",
        "pen": "FaPen",
        "pencil": "FaPencil",
        "quote-right": "FaQuoteRight",
        "reply": "FaReply",
        "share-nodes": "FaShareNodes",
        "square-check": "FaSquareCheck",
        "stamp": "FaStamp",
        "user": "FaUser",
        "user-pen": "FaUserPen",
        "user-plus": "FaUserPlus",
        "vote-up-filled": "FaVoteUpFilled",
        "water": "FaWater",
    ]

    private static func asset(for icon: String?) -> String? {
        guard let icon, !icon.isEmpty else { return nil }
        if let mapped = assetsByIcon[icon] { return mapped }
        // An unknown name: drop FontAwesome's variant prefix and try again
        // before giving up, so `far-gift` finds `gift`.
        let stripped = icon.replacingOccurrences(of: #"^(far|fas|fab|fal)-"#, with: "", options: .regularExpression)
        return assetsByIcon[stripped]
    }

    /// Discourse's own medal colours, lifted slightly in dark mode so bronze
    /// doesn't disappear into the background.
    private static func tint(customHex: String?, badgeTypeID: Int?) -> Color {
        if let customHex, let parsed = Color(cssHex: customHex) { return parsed }
        switch badgeTypeID {
        case 1: return Color(light: 0xC9A227, dark: 0xE4CB72)
        case 2: return Color(light: 0x8E8E93, dark: 0xC7C7CC)
        case 3: return Color(light: 0xA9662A, dark: 0xCD7F32)
        default: return Theme.accent
        }
    }
}

/// A badge's artwork: the uploaded image when it has one, otherwise its symbol
/// on a tinted disc. One implementation, so the 22pt row of overlapping badges
/// and the 44pt tile in the sheet can't drift.
struct ProfileBadgeIcon: View {
    let badge: ProfileBadge
    var size: CGFloat = 22
    var cornerRadius: CGFloat?

    var body: some View {
        Group {
            if let imageURL = badge.imageURL {
                CachedRemoteImage(url: imageURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    symbolTile
                }
            } else {
                symbolTile
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }

    private var symbolTile: some View {
        badge.tint.opacity(0.16)
            .overlay {
                glyph
                    .foregroundStyle(badge.tint)
            }
    }

    @ViewBuilder
    private var glyph: some View {
        if let assetName = badge.assetName {
            // Template-rendered so it takes the badge's colour, and sized to
            // ~54% of the disc so the artwork sits inside it rather than
            // filling it edge to edge.
            Image(assetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.54, height: size * 0.54)
        } else {
            Image(systemName: "rosette")
                .font(.system(size: size * 0.5, weight: .semibold))
        }
    }

    private var shape: AnyShape {
        if let cornerRadius {
            return AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        return AnyShape(Circle())
    }
}

// MARK: - @ / # completion

/// The completion list for a composer's `@` or `#` token.
///
/// A horizontal row rather than a dropdown: the keyboard owns the bottom half of
/// the screen while typing, and a vertical list either fights it for space or
/// covers the draft the suggestion is meant to go into.
struct MentionSuggestionBar: View {
    let suggestions: [MentionSuggestion]
    let onPick: (MentionSuggestion) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(suggestions) { suggestion in
                    Button { onPick(suggestion) } label: {
                        row(suggestion)
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    private func row(_ suggestion: MentionSuggestion) -> some View {
        HStack(spacing: 7) {
            icon(suggestion)

            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title)
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let subtitle = suggestion.subtitle {
                    Text(subtitle)
                        .font(Theme.body(10))
                        .foregroundStyle(Theme.muted(0.5))
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
    }

    @ViewBuilder
    private func icon(_ suggestion: MentionSuggestion) -> some View {
        switch suggestion.kind {
        case .user:
            RemoteAvatar(
                url: suggestion.avatarURL,
                letter: String(suggestion.title.prefix(1)).uppercased(),
                variant: abs(suggestion.title.hashValue),
                size: 22
            )
        case .node:
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(cssHex: suggestion.colorHex ?? "") ?? Theme.accent)
                .frame(width: 22, height: 22)
                .overlay {
                    Text(String(suggestion.title.prefix(1)))
                        .font(Theme.heading(10, weight: .bold))
                        .foregroundStyle(.white)
                }
        case .tag:
            Image(systemName: "tag.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22)
        }
    }
}

// MARK: - Voting

/// Overrides the neutral colours in `VoteControl` for dark surfaces.
///
/// The greys it uses read fine on a card and vanish over video, so the
/// full-screen player sets this to white. Voted arrows keep their own tint
/// either way — that colour *is* the state.
private struct VoteControlTintKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    var voteControlTint: Color? {
        get { self[VoteControlTintKey.self] }
        set { self[VoteControlTintKey.self] = newValue }
    }
}

/// Up / score / down, the control discourse-vote puts in place of the like
/// button.
///
/// The score is `like_count - vote_down_count`, so it can be negative — which is
/// the whole point of having it. Tapping the way you already voted retracts,
/// matching the plugin's `nextDirection`.
struct VoteControl: View {
    let score: Int
    let direction: VoteDirection
    /// False when the site doesn't let this member downvote; the arrow then
    /// reads as unavailable rather than silently failing.
    var canVoteDown: Bool = true
    var isEnabled: Bool = true
    var compact = false
    /// The rule between the two directions. On in a filled capsule, where it
    /// marks where the upvote's hit region ends; off in a bare row, where there
    /// is no container for it to divide.
    var showsDivider = true
    /// `reaction` nil casts the direction's default face.
    let onVote: (VoteDirection, String?) -> Void

    @State private var faces = VoteFaces.shared
    /// Set by dark surfaces; nil keeps the light-surface greys.
    @Environment(\.voteControlTint) private var neutralTint
    /// Which arrow's picker is open, if any.
    @State private var picking: VoteDirection?
    /// Which side is under a finger. These are gestures rather than buttons, so
    /// the pressed state has to be tracked by hand to give the touch an answer.
    @State private var pressing: VoteDirection?

    var body: some View {
        HStack(spacing: compact ? 2 : 4) {
            // Arrow *and* score in one hit region: the number belongs to the
            // upvote beside it, so tapping or holding it should do what the
            // arrow does rather than nothing.
            votable(.up) {
                HStack(spacing: compact ? 2 : 4) {
                    glyph(.up)

                    Text("\(score)")
                        .font(Theme.body(compact ? 12 : 13, weight: .semibold))
                        .foregroundStyle(scoreColor)
                        .monospacedDigit()
                        // A score never wraps: three digits in a tight capsule
                        // split across two lines without this, which grew the
                        // whole row.
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        // Minimum, so the row doesn't jump between "9" and
                        // "-10", but it still grows for "128".
                        .frame(minWidth: compact ? 16 : 20)
                }
            }

            if showsDivider {
                // Separates the two directions, and marks where the upvote's
                // hit region ends.
                Rectangle()
                    .fill(neutralTint?.opacity(0.35) ?? Theme.divider)
                    .frame(width: 1, height: compact ? 12 : 14)
                    .padding(.horizontal, compact ? 1 : 2)
            }

            votable(.down) { glyph(.down) }
                .opacity(canVoteDown ? 1 : 0.35)
                .disabled(!canVoteDown)
        }
        .task { await faces.loadIfNeeded() }
        // One sheet on the row, not one per arrow: several `.sheet` on the same
        // view collapse to whichever was applied last.
        .sheet(item: $picking) { target in
            VoteFacePicker(direction: target) { face in
                picking = nil
                onVote(target, face)
            }
        }
    }

    /// Wraps whatever region votes in that direction.
    ///
    /// Not a `Button`. A button consumes the whole touch sequence, so
    /// `.onLongPressGesture` on one never fires — and adding the long press as a
    /// simultaneous gesture instead makes the button's action *also* run on
    /// release, casting a vote while the picker opens. A plain view with both
    /// gestures is the combination SwiftUI resolves correctly: quick release
    /// taps, holding past the duration long-presses and the tap is suppressed.
    private func votable<Content: View>(
        _ target: VoteDirection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            // Hit area wider than the drawing, without the control taking the
            // space: pad, take the shape at that size, then give the layout its
            // room back.
            .padding(6)
            .contentShape(Rectangle())
            .padding(-6)
            .scaleEffect(pressing == target ? 0.88 : 1)
            .opacity(pressing == target ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: pressing)
            .accessibilityAddTraits(.isButton)
            .onTapGesture {
                guard isEnabled else { return }
                onVote(direction.next(target), nil)
            }
            // Hold for the faces — the gesture the web control binds on touch,
            // where a pointer gets hover instead. `onPressingChanged` is also
            // what drives the pressed state above; without it these have no
            // feedback at all, unlike the buttons around them.
            .onLongPressGesture(
                minimumDuration: 0.32,
                perform: {
                    guard isEnabled, !faces.faces(for: target).isEmpty else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    picking = target
                },
                onPressingChanged: { isPressing in
                    guard isEnabled else { return }
                    pressing = isPressing ? target : nil
                }
            )
    }

    private func glyph(_ target: VoteDirection) -> some View {
        let isCast = direction == target
        return Image(VoteControl.assetName(for: target, filled: isCast))
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: compact ? 15 : 17, height: compact ? 15 : 17)
            .foregroundStyle(isCast ? tint(for: target) : (neutralTint ?? Theme.muted(0.45)))
            .frame(width: compact ? 22 : 26, height: compact ? 22 : 26)
    }

    /// Shared with the feed card, which draws its own pill.
    static func assetName(for direction: VoteDirection, filled: Bool) -> String {
        let base = direction == .down ? "LucideArrowBigDown" : "LucideArrowBigUp"
        return filled ? base + "Filled" : base
    }

    /// The score takes the colour of the way *you* voted, which is how a reader
    /// finds their own vote without hunting for a filled arrow.
    private var scoreColor: Color {
        switch direction {
        case .up: return tint(for: .up)
        case .down: return tint(for: .down)
        case .none: return neutralTint ?? Theme.muted(0.6)
        }
    }

    private func tint(for direction: VoteDirection) -> Color {
        direction == .down ? Theme.accent2 : Theme.accent
    }
}

/// The faces one vote direction offers, as a bottom sheet.
///
/// Picking one always *casts* that direction — only the bare arrow toggles,
/// which is the web control's rule too.
struct VoteFacePicker: View {
    let direction: VoteDirection
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var faces = VoteFaces.shared

    private let side: CGFloat = 56

    var body: some View {
        let names = faces.faces(for: direction)
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: side), spacing: 6)], spacing: 6) {
                    ForEach(names, id: \.self) { name in
                        Button { onPick(name) } label: {
                            CachedRemoteImage(url: VoteFaces.imageURL(for: name)) { image in
                                image.resizable().scaledToFit()
                            } placeholder: {
                                Color.clear
                            }
                            .frame(width: 32, height: 32)
                            .frame(width: side, height: side)
                            .background(
                                Theme.surface,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel(name)
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .navigationTitle(direction == .down ? AppString("选择反对表情") : AppString("选择赞同表情"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
        // Fitted to the rows it has: sixteen faces upward and thirty downward,
        // so one fixed detent is either half empty or a scroll for no reason.
        .presentationDetents([.height(sheetHeight(for: names.count)), .large])
        .presentationDragIndicator(.visible)
        .task { await faces.loadIfNeeded() }
    }

    /// Five to a row is what the adaptive grid lands on at phone width; the
    /// sheet caps the result either way.
    private func sheetHeight(for count: Int) -> CGFloat {
        let rows = max(1, (count + 4) / 5)
        return min(CGFloat(rows) * (side + 6) + 110, 460)
    }
}

// MARK: - Press feedback

/// A button style that answers the touch: `.plain` leaves custom labels with no
/// pressed state at all, so an icon or a chip looked inert even though it worked.
///
/// Scale rather than a fill, because these sit on chips and capsules that
/// already have their own background.
struct PressableButtonStyle: ButtonStyle {
    /// Gentle by default, because this is applied app-wide and most buttons are
    /// rows or chips where a big scale would look like a bounce.
    var scale: CGFloat = 0.97
    var opacity: Double = 0.55

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? opacity : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// `.buttonStyle(.pressable)` — for rows, chips and anything wide.
    static var pressable: PressableButtonStyle { PressableButtonStyle() }

    /// A firmer press for small icons, where 3% is invisible.
    static var pressableIcon: PressableButtonStyle {
        PressableButtonStyle(scale: 0.88, opacity: 0.5)
    }
}
