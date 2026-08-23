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

// MARK: - Brand loader

/// Loading indicator built from the nodeloc wordmark. A dim copy sits underneath
/// and a full-color copy is revealed over it — either proportionally while the
/// user drags (`progress`), or by a repeating sweep once indeterminate.
/// The NODELOC mark, loading — from the "Nodeloc Loader" design (La/Lb/Lc).
/// The 11c geometry: hexagon cage, six dashed spokes, six vertex nodes, hub.
/// Per the VI motion rule nothing rotates, nothing bounces and the dash never
/// marches — the loading feeling is a sequence around the hexagon. Reduced
/// motion holds the mark static at full opacity, as specced.
struct NodelocLoader: View {
    enum Variant {
        /// La — spoke and node light in turn, clockwise. The safest default.
        case relay
        /// Lb — spokes land outward from the hub, nodes arrive behind them.
        /// Most expressive; splash use.
        case reachOut
        /// Lc — ghost structure, six equal dots travel the cage. Reads small;
        /// degrades to cage+dots ≤30pt and to dots-only ≤18pt.
        case minimal
    }

    var variant: Variant = .relay
    var height: CGFloat = 56

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    // Design space: viewBox 23.4 20 84.2 94.5.
    private static let designSize = CGSize(width: 84.2, height: 94.5)
    private static let designOrigin = CGPoint(x: 23.4, y: 20)
    private static let vertices: [CGPoint] = [
        CGPoint(x: 65, y: 25), CGPoint(x: 99.6, y: 45), CGPoint(x: 99.6, y: 85),
        CGPoint(x: 65, y: 105), CGPoint(x: 30.4, y: 85), CGPoint(x: 30.4, y: 45),
    ]
    private static let spokes: [(CGPoint, CGPoint)] = [
        (CGPoint(x: 65, y: 49), CGPoint(x: 65, y: 33)),
        (CGPoint(x: 79.8, y: 57.5), CGPoint(x: 92.7, y: 50.1)),
        (CGPoint(x: 79.8, y: 72.5), CGPoint(x: 92.2, y: 79.7)),
        (CGPoint(x: 65, y: 81), CGPoint(x: 65, y: 97)),
        (CGPoint(x: 50.2, y: 72.5), CGPoint(x: 37.8, y: 79.7)),
        (CGPoint(x: 50.2, y: 57.5), CGPoint(x: 37.3, y: 50.1)),
    ]
    private static let hub = CGPoint(x: 65, y: 65)
    private static let nodeRadii: [CGFloat] = [5, 6.5, 8, 9.5, 7, 5.5]

    var body: some View {
        Group {
            if reduceMotion {
                canvas(at: nil)
            } else {
                TimelineView(.animation) { context in
                    canvas(at: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(width: height * Self.designSize.width / Self.designSize.height, height: height)
        .accessibilityLabel("加载中")
    }

    /// One frame. `time` nil = static mark at full opacity (reduced motion).
    private func canvas(at time: TimeInterval?) -> some View {
        Canvas { ctx, size in
            let scale = size.height / Self.designSize.height
            func point(_ p: CGPoint) -> CGPoint {
                CGPoint(x: (p.x - Self.designOrigin.x) * scale, y: (p.y - Self.designOrigin.y) * scale)
            }

            let palette = palette
            let dotsOnly = variant == .minimal && height <= 18
            let compact = variant == .minimal && height <= 30

            // Cage.
            if !dotsOnly {
                var cage = Path()
                cage.addLines(Self.vertices.map(point))
                cage.closeSubpath()
                let cageOpacity: Double = switch variant {
                case .relay: 1
                case .reachOut: time.map { breathe(phase(at: $0, duration: 1.6, delay: 0)) } ?? 1
                case .minimal: compact ? 0.38 : 0.4
                }
                ctx.stroke(
                    cage,
                    with: .color(palette.cage.opacity(cageOpacity)),
                    style: StrokeStyle(lineWidth: (compact ? 4 : 2.6) * scale, lineJoin: .round)
                )
            }

            // Spokes — dashed, and the dash pattern never marches.
            if !dotsOnly && !compact {
                for (index, spoke) in Self.spokes.enumerated() {
                    let opacity: Double = switch variant {
                    case .relay:
                        time.map { relay(phase(at: $0, duration: 1.8, delay: 0.3 * Double(index))) } ?? 1
                    case .reachOut:
                        time.map { reach(phase(at: $0, duration: 1.6, delay: 0.07 * Double(index))) } ?? 1
                    case .minimal:
                        0.22
                    }
                    var path = Path()
                    path.move(to: point(spoke.0))
                    path.addLine(to: point(spoke.1))
                    ctx.stroke(
                        path,
                        with: .color(palette.spoke.opacity(opacity)),
                        style: StrokeStyle(lineWidth: 2.4 * scale, dash: [4.4 * scale, 3.2 * scale])
                    )
                }
            }

            // Vertex nodes.
            for (index, vertex) in Self.vertices.enumerated() {
                let radius: CGFloat = switch variant {
                case .relay, .reachOut: Self.nodeRadii[index]
                case .minimal: dotsOnly ? 11 : (compact ? 7.5 : 5)
                }
                let opacity: Double = switch variant {
                case .relay:
                    time.map { relay(phase(at: $0, duration: 1.8, delay: 0.3 * Double(index))) } ?? 1
                case .reachOut:
                    time.map { reach(phase(at: $0, duration: 1.6, delay: 0.12 + 0.07 * Double(index))) } ?? 1
                case .minimal:
                    time.map { relay(phase(at: $0, duration: 1.5, delay: 0.25 * Double(index))) } ?? 1
                }
                let color = variant == .minimal ? palette.minimalDot : palette.nodes[index]
                let center = point(vertex)
                let r = radius * scale
                ctx.fill(
                    Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                    with: .color(color.opacity(opacity))
                )
            }

            // Hub — never moves.
            if !dotsOnly && !compact {
                let center = point(Self.hub)
                let r = 12 * scale
                ctx.fill(
                    Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                    with: .color(palette.hub.opacity(variant == .minimal ? 0.32 : 1))
                )
            }
        }
    }

    // MARK: Motion (the design's keyframes, piecewise)

    private func phase(at time: TimeInterval, duration: Double, delay: Double) -> Double {
        let local = (time - delay).truncatingRemainder(dividingBy: duration)
        return (local < 0 ? local + duration : local) / duration
    }

    /// nl-relay: 0.18 → 1 by 12%, back to 0.18 by 38%, rest dim. Linear.
    private func relay(_ phase: Double) -> Double {
        switch phase {
        case ..<0.12: 0.18 + 0.82 * (phase / 0.12)
        case ..<0.38: 1 - 0.82 * ((phase - 0.12) / 0.26)
        default: 0.18
        }
    }

    /// nl-out: in by 22%, hold to 62%, gone by 88%.
    private func reach(_ phase: Double) -> Double {
        switch phase {
        case ..<0.22: phase / 0.22
        case ..<0.62: 1
        case ..<0.88: 1 - (phase - 0.62) / 0.26
        default: 0
        }
    }

    /// nl-breathe: 0.55 ↔ 1, ease-in-out.
    private func breathe(_ phase: Double) -> Double {
        0.55 + 0.45 * (0.5 - 0.5 * cos(phase * 2 * .pi))
    }

    // MARK: Colourways (dark, and the light ground ramp inverted)

    private struct Palette {
        let cage: Color
        let spoke: Color
        let hub: Color
        let nodes: [Color]
        let minimalDot: Color
    }

    private var palette: Palette {
        colorScheme == .dark
            ? Palette(
                cage: Color(hex: 0x00A870),
                spoke: Color(hex: 0xFF9933),
                hub: Color(hex: 0x6FE9C5),
                nodes: [0x00875A, 0x00A870, 0x3AD4A8, 0x3AD4A8, 0x009966, 0x00A870].map { Color(hex: $0) },
                minimalDot: Color(hex: 0x6FE9C5)
            )
            : Palette(
                cage: Color(hex: 0x009966),
                spoke: Color(hex: 0xE0771A),
                hub: Color(hex: 0x00593B),
                nodes: [0x7CEBC4, 0x3AD4A8, 0x00714C, 0x00402C, 0x009966, 0x3AD4A8].map { Color(hex: $0) },
                minimalDot: Color(hex: 0x00593B)
            )
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
                .buttonStyle(.plain)
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
    let systemName: String
    var accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.headerText)
                .frame(width: FloatingHeader.controlHeight, height: FloatingHeader.controlHeight)
        }
        .buttonStyle(.glass(.regular.tint(FloatingHeader.glassTint)))
        .buttonBorderShape(.circle)
        .shadow(color: FloatingHeader.shadow, radius: 9, y: 6)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Opens the sidebar. Shared so every root screen's top-left button is the
/// same control rather than copies that drift apart.
struct SidebarMenuButton: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HeaderIconButton(systemName: "line.3.horizontal", accessibilityLabel: "菜单") {
            // Matches the drag-to-open animation in MainView.
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                app.overlay = .sidebar
            }
        }
    }
}

/// A circular or capsule glass button for a floating header.
struct FloatingHeaderButton<Label: View>: View {
    var borderShape: ButtonBorderShape = .circle
    let action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button(action: action) {
            label
                .frame(height: FloatingHeader.controlHeight)
        }
        .buttonStyle(.glass(.regular.tint(FloatingHeader.glassTint)))
        .buttonBorderShape(borderShape)
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
        show((error as? LocalizedError)?.errorDescription ?? "操作失败，请稍后重试")
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
                .glassEffect(.regular.tint(Theme.bg.opacity(0.5)), in: .capsule)
                .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
                .padding(.horizontal, 32)
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

#Preview("Nodeloc Loader") {
    VStack(spacing: 28) {
        HStack(spacing: 28) {
            VStack(spacing: 8) {
                NodelocLoader(variant: .relay, height: 96)
                Text("La · Relay").font(.caption2)
            }
            VStack(spacing: 8) {
                NodelocLoader(variant: .reachOut, height: 96)
                Text("Lb · Reach out").font(.caption2)
            }
            VStack(spacing: 8) {
                NodelocLoader(variant: .minimal, height: 96)
                Text("Lc · Minimal").font(.caption2)
            }
        }
        HStack(alignment: .bottom, spacing: 24) {
            NodelocLoader(variant: .minimal, height: 44)
            NodelocLoader(variant: .minimal, height: 24)
            NodelocLoader(variant: .minimal, height: 16)
        }
    }
    .padding(40)
    .background(Theme.bg)
}

// MARK: - Pull to refresh (Lc)

/// Drives a custom pull-to-refresh: feed it the scroll's top offset from
/// onScrollGeometryChange and it reports pull progress, fires `onRefresh`
/// once past the threshold, and re-arms after the scroll settles. Exists
/// because `.refreshable` can't restyle its ProgressView, and the design
/// names Lc as the pull-to-refresh spinner.
@MainActor
@Observable
final class PullToRefresh {
    private(set) var progress: Double = 0
    private(set) var isRefreshing = false

    private let threshold: CGFloat = 72
    private var triggered = false

    /// `top` is contentOffset.y — negative while rubber-banding past the top.
    func scrolled(to top: CGFloat, onRefresh: @escaping () async -> Void) {
        let pull = max(0, -top)
        if !isRefreshing {
            progress = min(1, Double(pull / threshold))
        }
        if pull <= 2 { triggered = false }
        guard pull >= threshold, !triggered, !isRefreshing else { return }

        triggered = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.quick) { isRefreshing = true }
        Task {
            let start = Date()
            await onRefresh()
            // Hold through at least one loop step so the loader doesn't blink.
            let elapsed = Date().timeIntervalSince(start)
            if elapsed < 0.6 {
                try? await Task.sleep(for: .seconds(0.6 - elapsed))
            }
            withAnimation(.quick) {
                self.isRefreshing = false
                self.progress = 0
            }
        }
    }
}

/// The Lc dot loop fading and growing in with the pull, steady while
/// refreshing. Place near the top of the screen, over the rubber-band gap.
struct NodelocRefreshIndicator: View {
    let pull: PullToRefresh

    var body: some View {
        if pull.progress > 0.02 || pull.isRefreshing {
            NodelocLoader(variant: .minimal, height: 26)
                .opacity(pull.isRefreshing ? 1 : 0.25 + 0.75 * pull.progress)
                .scaleEffect(pull.isRefreshing ? 1 : 0.7 + 0.3 * pull.progress)
                .transition(.opacity)
        }
    }
}
