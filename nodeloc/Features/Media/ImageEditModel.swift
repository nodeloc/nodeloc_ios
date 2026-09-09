//
//  ImageEditModel.swift
//  nodeloc
//
//  Value types describing a composer image attachment and the non-destructive
//  edit stack applied to it. Every edit is stored as normalized coordinates in
//  the *base* image space (the full, uncropped, orientation-corrected image) so
//  that re-cropping never invalidates strokes, text, or mosaics.
//
//  Everything here is explicitly `nonisolated`: the project builds with
//  SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so an unannotated type would be
//  main-actor isolated and could not be handed to the background renderer.
//

import CoreGraphics
import Foundation

// MARK: - Edit primitives

/// A freehand stroke. Points are normalized to the base image; width is a
/// fraction of image *width* so the same stroke renders identically at preview
/// and export resolution. One fixed reference axis avoids the portrait/landscape
/// flip you get from `min(w, h)`.
nonisolated struct ImageStroke: Identifiable, Sendable, Codable, Equatable {
    var id = UUID()
    var points: [CGPoint] = []
    var colorHex: UInt32 = 0xFF3B30
    var widthFraction: Double = 0.012
    var isEraser = false
}

/// A single-line text overlay. Multi-line is deliberately unsupported: Canvas
/// (CoreText) and NSAttributedString.draw line-break differently, which would
/// break preview/export parity.
nonisolated struct ImageTextItem: Identifiable, Sendable, Codable, Equatable {
    var id = UUID()
    var string: String = ""
    /// Normalized center in base image space.
    var center: CGPoint = CGPoint(x: 0.5, y: 0.5)
    /// Cap height as a fraction of image *height*.
    var fontFraction: Double = 0.06
    var colorHex: UInt32 = 0xFFFFFF
    /// Radians.
    var rotation: Double = 0
    var hasBackdrop = true
}

/// A redaction region. `style` distinguishes a reversible-looking pixelate from
/// a genuinely opaque fill — pixelation is not cryptographically irreversible,
/// so account numbers want `.solid`.
nonisolated struct ImageMosaicRect: Identifiable, Sendable, Codable, Equatable {
    enum Style: String, Sendable, Codable, CaseIterable {
        case pixelate
        case solid

        var label: String {
            switch self {
            case .pixelate: AppString("马赛克")
            case .solid: AppString("纯色")
            }
        }
    }

    var id = UUID()
    /// Normalized rect in base image space.
    var rect: CGRect = .zero
    var style: Style = .pixelate
    var strength: Double = 1
}

// MARK: - Filters

nonisolated enum ImageFilterKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case none
    case vivid
    case mono
    case instant
    case fade
    case cool
    case warm
    case process

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: AppString("原图")
        case .vivid: AppString("鲜明")
        case .mono: AppString("黑白")
        case .instant: AppString("胶片")
        case .fade: AppString("褪色")
        case .cool: AppString("冷色")
        case .warm: AppString("暖色")
        case .process: AppString("高对比")
        }
    }
}

// MARK: - Crop

nonisolated enum ImageCropAspect: String, Sendable, Codable, CaseIterable, Identifiable {
    case free
    case original
    case square
    case r4x3
    case r3x4
    case r16x9
    case r9x16

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free: AppString("自由")
        case .original: AppString("原始")
        case .square: "1:1"
        case .r4x3: "4:3"
        case .r3x4: "3:4"
        case .r16x9: "16:9"
        case .r9x16: "9:16"
        }
    }

    /// Target width/height ratio in *pixel* space, or nil when unconstrained.
    /// `original` needs the source size, hence the parameter.
    func pixelRatio(baseSize: CGSize) -> Double? {
        switch self {
        case .free: nil
        case .original: baseSize.height > 0 ? Double(baseSize.width / baseSize.height) : nil
        case .square: 1
        case .r4x3: 4.0 / 3.0
        case .r3x4: 3.0 / 4.0
        case .r16x9: 16.0 / 9.0
        case .r9x16: 9.0 / 16.0
        }
    }
}

// MARK: - Edit stack

/// The complete, replayable description of every edit applied to one image.
/// Render order is fixed: filter → mosaic → strokes → text → crop. Crop is last
/// so that all other coordinates stay in uncropped base space and the user can
/// always widen a crop back out.
nonisolated struct ImageEditStack: Sendable, Codable, Equatable {
    /// Normalized crop window in base image space. Full image by default.
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    var cropAspect: ImageCropAspect = .free
    var filter: ImageFilterKind = .none
    var filterIntensity: Double = 1
    var mosaics: [ImageMosaicRect] = []
    var strokes: [ImageStroke] = []
    var texts: [ImageTextItem] = []

    static let full = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// True when replaying this stack would reproduce the source bytes exactly.
    /// Used to skip the composite + re-upload entirely when a user opens the
    /// editor and commits without changing anything.
    var isIdentity: Bool {
        crop == Self.full
            && filter == .none
            && mosaics.isEmpty
            && strokes.isEmpty
            && texts.isEmpty
    }

    var isCropped: Bool { crop != Self.full }
}

// MARK: - Attachment

/// Where an attachment stands with the server. The composer only emits markdown
/// for `.ready`, so a failed upload never produces a broken `![]()`.
nonisolated enum ComposeUploadState: Sendable, Equatable {
    case pending
    case uploading
    case ready(String)
    case failed(String)

    var composerURLString: String? {
        if case .ready(let url) = self { return url }
        return nil
    }

    var isTerminal: Bool {
        switch self {
        case .ready, .failed: true
        case .pending, .uploading: false
        }
    }
}

/// One picked image. Holds the original bytes (tier 1) forever so edits stay
/// non-destructive; the decoded thumbnail (tier 2) lives in a separate cache and
/// the full-resolution decode (tier 3) exists only while the editor is open.
nonisolated struct ComposeImageAttachment: Identifiable, Sendable {
    let id: UUID
    var originalData: Data
    /// Orientation-corrected pixel dimensions of the base image.
    var pixelSize: CGSize
    var fileName: String
    var mimeType: String
    var edits = ImageEditStack()
    /// Bumped on every committed edit; part of the thumbnail cache key.
    var editsRevision = 0
    var upload: ComposeUploadState = .pending
    /// Bytes actually uploaded — the composite when edited, `originalData` when not.
    var uploadedData: Data?

    init(
        id: UUID = UUID(),
        originalData: Data,
        pixelSize: CGSize,
        fileName: String,
        mimeType: String
    ) {
        self.id = id
        self.originalData = originalData
        self.pixelSize = pixelSize
        self.fileName = fileName
        self.mimeType = mimeType
    }

    /// Cache key for the strip thumbnail. Changes whenever a committed edit
    /// would alter what the thumbnail should show.
    var thumbnailKey: String { "\(id.uuidString)-\(editsRevision)" }

    var markdown: String? {
        guard let url = upload.composerURLString else { return nil }
        return "![\(escapedLabel)](\(url))"
    }

    private var escapedLabel: String {
        let base = fileName.isEmpty ? AppString("图片") : fileName
        return base
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }
}

// MARK: - Video attachment

/// Trim window plus the GIF flag — everything the trimmer can change.
nonisolated struct VideoEditPlan: Sendable, Equatable {
    /// Seconds from the start of the source.
    var startSeconds: Double = 0
    /// Seconds from the start of the source; equals `duration` when untrimmed.
    var endSeconds: Double = 0
    var duration: Double = 0
    var asGIF = false

    var trimmedDuration: Double { max(0, endSeconds - startSeconds) }

    /// True when exporting would just re-encode the source unchanged, letting
    /// the composer upload the original file untouched.
    var isIdentity: Bool {
        !asGIF
            && startSeconds <= 0.001
            && endSeconds >= duration - 0.001
    }
}

/// One picked video. The source stays on disk (videos are far too large to hold
/// in memory), and the poster is a locally extracted first frame shown in the
/// composer before any upload happens.
nonisolated struct ComposeVideoAttachment: Identifiable, Sendable {
    let id: UUID
    /// Local temp file. Owned by the composer; removed when the attachment is.
    var sourceURL: URL
    var pixelSize: CGSize
    var fileName: String
    var mimeType: String
    var posterData: Data?
    var plan = VideoEditPlan()
    var editsRevision = 0
    var upload: ComposeUploadState = .pending
    /// The poster rides a second upload, named after the video's SHA1.
    var posterUpload: ComposeUploadState = .pending
    /// Extracted from the video upload's `url`, not its base62 `short_url`.
    var videoSHA1: String?
    /// Set when a trim/GIF export produced a different file to upload.
    var exportedURL: URL?

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        pixelSize: CGSize,
        duration: Double,
        fileName: String,
        mimeType: String
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.pixelSize = pixelSize
        self.fileName = fileName
        self.mimeType = mimeType
        self.plan = VideoEditPlan(startSeconds: 0, endSeconds: duration, duration: duration)
    }

    /// The file actually uploaded: the trimmed/GIF export when present.
    var uploadURL: URL { exportedURL ?? sourceURL }

    /// Discourse renders `![name|video](upload://…)` as a video placeholder —
    /// the `|video` suffix in the alt text is what triggers it. Mirrors
    /// `playableMediaMarkdown` in the web composer's uploads.js.
    var markdown: String? {
        guard let url = upload.composerURLString else { return nil }
        return "![\(escapedLabel)|video](\(url))"
    }

    private var escapedLabel: String {
        let base = (fileName as NSString).deletingPathExtension
        let cleaned = base.isEmpty ? AppString("视频") : base
        return cleaned
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: " ")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }
}

/// Which kind of media the composer currently holds. Always derived from the
/// attachment arrays rather than stored, so the toolbar can never disagree with
/// what's actually attached.
nonisolated enum ComposeMediaMode: Sendable, Equatable {
    case empty
    case images
    case video

    var allowsImages: Bool { self != .video }
    var allowsVideo: Bool { self == .empty }
}

// MARK: - Coordinate conversion

/// The single source of truth for view-space ↔ image-space conversion.
///
/// Every gesture in the editor routes through this type; no tool does ad-hoc
/// conversion math. Both spaces are y-down with a top-left origin (CoreImage's
/// y-up convention is confined to the inside of the renderer's CI stage).
///
/// x and y normalize against width and height independently. That is exact
/// rather than distorting, because aspect-fit yields a single uniform scale —
/// a circle drawn on screen round-trips as a circle.
nonisolated struct ImageDisplayTransform: Sendable, Equatable {
    /// Base image pixel size, orientation-corrected.
    let pixelSize: CGSize
    /// The normalized sub-rect of the base image currently on screen. This is
    /// the crop while editing normally, and the full image while the crop tool
    /// is active (so the user can drag the window back outward).
    let visibleRect: CGRect
    /// The SwiftUI frame the image is fitted into.
    let containerSize: CGSize

    init(pixelSize: CGSize, visibleRect: CGRect = ImageEditStack.full, containerSize: CGSize) {
        self.pixelSize = pixelSize
        self.visibleRect = visibleRect
        self.containerSize = containerSize
    }

    /// Pixel dimensions of the visible portion.
    var visiblePixelSize: CGSize {
        CGSize(
            width: max(1, pixelSize.width * visibleRect.width),
            height: max(1, pixelSize.height * visibleRect.height)
        )
    }

    /// Aspect-fit rect of the visible portion inside the container, in view coordinates.
    var fittedRect: CGRect {
        let visible = visiblePixelSize
        guard visible.width > 0, visible.height > 0,
              containerSize.width > 0, containerSize.height > 0 else { return .zero }

        let scale = min(containerSize.width / visible.width, containerSize.height / visible.height)
        let size = CGSize(width: visible.width * scale, height: visible.height * scale)
        return CGRect(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// View points per image pixel. Uniform in x and y.
    var scale: CGFloat {
        let visible = visiblePixelSize
        guard visible.width > 0 else { return 1 }
        return fittedRect.width / visible.width
    }

    /// View coordinate → normalized base image coordinate.
    func normalized(_ viewPoint: CGPoint) -> CGPoint {
        let rect = fittedRect
        guard rect.width > 0, rect.height > 0 else { return .zero }
        let withinVisible = CGPoint(
            x: (viewPoint.x - rect.minX) / rect.width,
            y: (viewPoint.y - rect.minY) / rect.height
        )
        return CGPoint(
            x: visibleRect.minX + withinVisible.x * visibleRect.width,
            y: visibleRect.minY + withinVisible.y * visibleRect.height
        )
    }

    /// Normalized base image coordinate → view coordinate.
    func viewPoint(_ normalized: CGPoint) -> CGPoint {
        let rect = fittedRect
        guard visibleRect.width > 0, visibleRect.height > 0 else { return .zero }
        let withinVisible = CGPoint(
            x: (normalized.x - visibleRect.minX) / visibleRect.width,
            y: (normalized.y - visibleRect.minY) / visibleRect.height
        )
        return CGPoint(
            x: rect.minX + withinVisible.x * rect.width,
            y: rect.minY + withinVisible.y * rect.height
        )
    }

    /// Normalized base rect → view rect.
    func viewRect(_ normalizedRect: CGRect) -> CGRect {
        let origin = viewPoint(CGPoint(x: normalizedRect.minX, y: normalizedRect.minY))
        let corner = viewPoint(CGPoint(x: normalizedRect.maxX, y: normalizedRect.maxY))
        return CGRect(
            x: min(origin.x, corner.x),
            y: min(origin.y, corner.y),
            width: abs(corner.x - origin.x),
            height: abs(corner.y - origin.y)
        )
    }

    /// Normalized base rect → base image pixel rect.
    func pixelRect(_ normalizedRect: CGRect) -> CGRect {
        CGRect(
            x: normalizedRect.minX * pixelSize.width,
            y: normalizedRect.minY * pixelSize.height,
            width: normalizedRect.width * pixelSize.width,
            height: normalizedRect.height * pixelSize.height
        )
    }

    /// A view-space length (e.g. a drag distance) → base image pixels.
    func pixelLength(fromViewLength length: CGFloat) -> CGFloat {
        guard scale > 0 else { return length }
        return length / scale
    }

    /// A view-space length → fraction of base image width (stroke widths).
    func widthFraction(fromViewLength length: CGFloat) -> Double {
        guard pixelSize.width > 0 else { return 0 }
        return Double(pixelLength(fromViewLength: length) / pixelSize.width)
    }

    /// A view-space length → fraction of base image height (font sizes).
    func heightFraction(fromViewLength length: CGFloat) -> Double {
        guard pixelSize.height > 0 else { return 0 }
        return Double(pixelLength(fromViewLength: length) / pixelSize.height)
    }

    /// Fraction of base image width → view-space length.
    func viewLength(fromWidthFraction fraction: Double) -> CGFloat {
        CGFloat(fraction) * pixelSize.width * scale
    }

    /// Fraction of base image height → view-space length.
    func viewLength(fromHeightFraction fraction: Double) -> CGFloat {
        CGFloat(fraction) * pixelSize.height * scale
    }
}

// MARK: - Geometry helpers

nonisolated extension CGRect {
    /// Clamps to the unit square, preserving size where possible.
    func clampedToUnitSquare() -> CGRect {
        let w = Swift.min(width, 1)
        let h = Swift.min(height, 1)
        let x = Swift.min(Swift.max(minX, 0), 1 - w)
        let y = Swift.min(Swift.max(minY, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

nonisolated extension CGPoint {
    func clampedToUnitSquare() -> CGPoint {
        CGPoint(
            x: Swift.min(Swift.max(x, 0), 1),
            y: Swift.min(Swift.max(y, 0), 1)
        )
    }

    func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }

    /// Rotates around `center` by `radians`. Used to hit-test rotated text by
    /// applying the inverse rotation to the touch point.
    func rotated(around center: CGPoint, by radians: Double) -> CGPoint {
        let dx = x - center.x
        let dy = y - center.y
        let c = cos(radians)
        let s = sin(radians)
        return CGPoint(
            x: center.x + dx * c - dy * s,
            y: center.y + dx * s + dy * c
        )
    }
}
