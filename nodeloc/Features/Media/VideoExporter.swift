//
//  VideoExporter.swift
//  nodeloc
//
//  Off-main video work for the composer: poster extraction, timeline filmstrip
//  frames, trimming, and GIF conversion.
//
//  Same concurrency rules as ImageEditRenderer — every entry point is
//  `@concurrent nonisolated`, because the project builds with
//  SWIFT_APPROACHABLE_CONCURRENCY = YES and a plain `nonisolated async func`
//  called from a @MainActor view would still run on the main thread.
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

nonisolated enum VideoExporter {

    /// GIF limits. Animated GIFs balloon fast — a 10s 1080p clip is tens of MB,
    /// well past Discourse's default 10MB attachment cap.
    static let gifMaxSeconds: Double = 6
    static let gifFPS: Double = 10
    static let gifMaxWidth: CGFloat = 480

    /// Filmstrip thumbnails along the trimmer's timeline.
    static let filmstripFrameCount = 10

    enum VideoExportError: LocalizedError {
        case noVideoTrack
        case exportUnsupported
        case exportFailed(String)
        case gifEncodingFailed

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: "这个文件里没有可用的视频轨道。"
            case .exportUnsupported: "无法用当前格式导出这个视频。"
            case .exportFailed(let message): message
            case .gifEncodingFailed: "GIF 生成失败。"
            }
        }
    }

    // MARK: - Metadata

    /// Duration and display-corrected pixel size. `naturalSize` ignores the
    /// preferred transform, so a portrait video read raw looks landscape.
    @concurrent
    static func metadata(for url: URL) async -> (duration: Double, pixelSize: CGSize)? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration),
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return nil }

        let displaySize = naturalSize.applying(transform)
        return (
            duration: CMTimeGetSeconds(duration),
            pixelSize: CGSize(width: abs(displaySize.width), height: abs(displaySize.height))
        )
    }

    // MARK: - Poster

    /// First frame, as PNG, for the in-composer preview and the Discourse poster.
    @concurrent
    static func posterPNG(for url: URL, at seconds: Double = 0) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: 1280, height: 1280)

        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        guard let (image, _) = try? await generator.image(at: time) else { return nil }
        return UIImage(cgImage: image).pngData()
    }

    // MARK: - Filmstrip

    /// Evenly spaced frames across the whole clip for the trimmer timeline.
    /// Zero tolerance so each thumbnail actually matches its timeline position.
    @concurrent
    static func filmstrip(
        for url: URL,
        duration: Double,
        count: Int = filmstripFrameCount,
        height: CGFloat = 96
    ) async -> [CGImage] {
        guard duration > 0, count > 0 else { return [] }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 0, height: height * 2)

        let times = (0..<count).map { index -> CMTime in
            // Sample frame centers, so the first thumbnail isn't a black
            // leader frame and the last isn't past the end.
            let fraction = (Double(index) + 0.5) / Double(count)
            return CMTime(seconds: duration * fraction, preferredTimescale: 600)
        }

        var frames: [CGImage] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image {
                frames.append(image)
            }
        }
        return frames
    }

    // MARK: - Trim

    /// Exports `plan`'s time range to a new file. Returns nil when the plan is
    /// an identity (untrimmed, non-GIF) — the caller uploads the original bytes
    /// instead of pointlessly re-encoding.
    @concurrent
    static func exportTrimmed(
        source: URL,
        plan: VideoEditPlan
    ) async throws -> URL? {
        guard !plan.isIdentity else { return nil }

        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw VideoExportError.exportUnsupported
        }

        let start = CMTime(seconds: plan.startSeconds, preferredTimescale: 600)
        let end = CMTime(seconds: plan.endSeconds, preferredTimescale: 600)
        session.timeRange = CMTimeRange(start: start, end: end)
        session.shouldOptimizeForNetworkUse = true

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodeloc-trim-\(UUID().uuidString)")
            .appendingPathExtension("mp4")

        do {
            // The async export(to:as:) replaces the deprecated
            // exportAsynchronously(completionHandler:).
            try await session.export(to: output, as: .mp4)
        } catch {
            throw VideoExportError.exportFailed(error.localizedDescription)
        }
        return output
    }

    // MARK: - GIF

    /// Renders the trimmed range as an animated GIF, clamped to limits that keep
    /// the file under Discourse's attachment cap.
    @concurrent
    static func exportGIF(source: URL, plan: VideoEditPlan) async throws -> URL {
        let span = min(plan.trimmedDuration, gifMaxSeconds)
        guard span > 0 else { throw VideoExportError.gifEncodingFailed }

        let frameCount = max(2, Int(span * gifFPS))
        let delay = span / Double(frameCount)

        let asset = AVURLAsset(url: source)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: gifMaxWidth, height: 0)

        let times = (0..<frameCount).map { index -> CMTime in
            CMTime(
                seconds: plan.startSeconds + span * (Double(index) / Double(frameCount)),
                preferredTimescale: 600
            )
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodeloc-gif-\(UUID().uuidString)")
            .appendingPathExtension("gif")

        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw VideoExportError.gifEncodingFailed
        }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)

        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay],
        ] as CFDictionary

        var wrote = 0
        for await result in generator.images(for: times) {
            guard let image = try? result.image else { continue }
            CGImageDestinationAddImage(destination, image, frameProperties)
            wrote += 1
        }

        guard wrote > 0, CGImageDestinationFinalize(destination) else {
            throw VideoExportError.gifEncodingFailed
        }
        return output
    }

    // MARK: - Upload helpers

    /// Pulls the SHA1 out of an upload URL like
    /// `/uploads/default/original/1X/<sha1>.mp4`.
    ///
    /// Discourse attaches a video poster by matching an upload whose
    /// `original_filename` is `<video sha1>.<ext>` (see `pretty_text.rb`
    /// `add_video_placeholder_image`), so this — not the base62 `short_url` —
    /// is what the poster must be named after.
    static func sha1(fromUploadURL urlString: String?) -> String? {
        guard let urlString, !urlString.isEmpty else { return nil }
        // Strip any query/fragment, then take the last path component.
        let path = urlString
            .components(separatedBy: "?").first?
            .components(separatedBy: "#").first ?? urlString
        let file = (path as NSString).lastPathComponent
        let base = (file as NSString).deletingPathExtension
        // Discourse SHA1s are 40 hex chars; anything else means the URL shape
        // changed and guessing would silently produce an unusable poster name.
        let isSHA1 = base.count == 40 && base.allSatisfy(\.isHexDigit)
        return isSHA1 ? base.lowercased() : nil
    }

    /// Removes a temp file, ignoring failures.
    static func discard(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
