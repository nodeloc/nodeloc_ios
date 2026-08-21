//
//  ImageEditRenderer.swift
//  nodeloc
//
//  Off-main image compositing for the composer's photo editor. Replays an
//  `ImageEditStack` onto a decoded base image, in a fixed order:
//
//      filter → mosaic → flatten → strokes → text → crop
//
//  Crop runs last on purpose: every other operation stores coordinates in the
//  uncropped base space, so re-cropping never has to re-map anything and the
//  user can always widen a crop back out.
//
//  Every entry point is `@concurrent nonisolated`. The project builds with
//  SWIFT_APPROACHABLE_CONCURRENCY = YES, which means a plain `nonisolated async
//  func` called from a @MainActor view would still run on the main thread —
//  `@concurrent` is what actually forces this work onto the cooperative pool.
//
//  Only Data, CGImage, and the Sendable model structs cross the actor boundary.
//  CIImage / CIFilter / UIImage stay inside a single function body.
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

nonisolated enum ImageEditRenderer {

    // MARK: - Shared context

    /// One shared CIContext for the whole app. Creating a context per render is
    /// the classic CoreImage performance bug — each one allocates a Metal
    /// command queue and shader cache.
    ///
    /// Working and output color spaces are pinned to sRGB. Photos from a modern
    /// iPhone carry an HDR gain map; letting CoreImage work in extended range
    /// and then rendering to RGBA8 produces visibly washed-out or clipped
    /// output. Pinning tone-maps to SDR deterministically, which is what
    /// Discourse will serve anyway.
    static let ciContext: CIContext = {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let options: [CIContextOption: Any] = [
            .workingColorSpace: srgb,
            .outputColorSpace: srgb,
            .cacheIntermediates: false,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    /// Long-edge cap for the editing base. Beyond this buys nothing — Discourse
    /// resizes server-side anyway — and costs ~50MB per extra step.
    static let editingMaxPixel: CGFloat = 4096
    /// Long-edge cap for the live filter/mosaic preview.
    static let previewMaxPixel: CGFloat = 1600
    /// Strip thumbnail size.
    static let thumbnailMaxPixel: CGFloat = 720
    /// Filter swatch size.
    static let filterThumbMaxPixel: CGFloat = 240

    // MARK: - Decoding

    /// Decodes and downsamples in one ImageIO pass, applying the EXIF
    /// orientation transform so the result is always `.up`.
    ///
    /// Skipping the transform is what makes gestures land 90° off on photos shot
    /// in landscape — the pixel buffer is transposed relative to what's displayed.
    @concurrent
    static func decode(data: Data, maxPixel: CGFloat) async -> CGImage? {
        decodeSync(data: data, maxPixel: maxPixel)
    }

    /// Synchronous core, so callers already off-main don't re-hop.
    static func decodeSync(data: Data, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Orientation-corrected pixel dimensions without decoding the bitmap.
    @concurrent
    static func pixelSize(of data: Data) async -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }

        // Orientations 5-8 swap the axes.
        let orientation = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let swapped = (5...8).contains(orientation)
        return swapped
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    // MARK: - Strip thumbnail

    /// Thumbnail for the composer strip, with the edit stack applied.
    @concurrent
    static func thumbnail(data: Data, stack: ImageEditStack) async -> CGImage? {
        guard let base = decodeSync(data: data, maxPixel: thumbnailMaxPixel) else { return nil }
        if stack.isIdentity { return base }
        return compositeSync(base: base, stack: stack)
    }

    // MARK: - Live preview

    /// The expensive raster layer: filter + mosaic only, at preview resolution.
    /// Strokes and text are drawn live in a SwiftUI Canvas instead, which is
    /// what keeps drawing at full frame rate.
    @concurrent
    static func rasterPreview(
        base: CGImage,
        filter: ImageFilterKind,
        intensity: Double,
        mosaics: [ImageMosaicRect]
    ) async -> CGImage? {
        guard filter != .none || !mosaics.isEmpty else { return base }

        var ci = CIImage(cgImage: base)
        ci = applyFilter(filter, intensity: intensity, to: ci)
        ci = applyMosaics(mosaics, to: ci, pixelSize: CGSize(width: base.width, height: base.height))
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    /// Renders the eight filter swatches from one small center-cropped source.
    @concurrent
    static func filterThumbnails(base: CGImage) async -> [ImageFilterKind: CGImage] {
        guard let square = centerSquare(base, maxPixel: filterThumbMaxPixel) else { return [:] }
        let source = CIImage(cgImage: square)

        var result: [ImageFilterKind: CGImage] = [:]
        for kind in ImageFilterKind.allCases {
            let filtered = applyFilter(kind, intensity: 1, to: source)
            if let cg = ciContext.createCGImage(filtered, from: source.extent) {
                result[kind] = cg
            }
        }
        return result
    }

    // MARK: - Composite

    /// Full-resolution composite for export.
    @concurrent
    static func composite(base: CGImage, stack: ImageEditStack) async -> CGImage? {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        return compositeSync(base: base, stack: stack)
    }

    static func compositeSync(base: CGImage, stack: ImageEditStack) -> CGImage? {
        let pixelSize = CGSize(width: base.width, height: base.height)

        // 1-2. Filter and mosaic in CoreImage.
        var flattened = base
        if stack.filter != .none || !stack.mosaics.isEmpty {
            var ci = CIImage(cgImage: base)
            ci = applyFilter(stack.filter, intensity: stack.filterIntensity, to: ci)
            ci = applyMosaics(stack.mosaics, to: ci, pixelSize: pixelSize)
            // 3. Flatten back to CGImage.
            guard let cg = ciContext.createCGImage(ci, from: CGRect(origin: .zero, size: pixelSize)) else {
                return nil
            }
            flattened = cg
        }

        // 4-5. Vector layers in CoreGraphics.
        if !stack.strokes.isEmpty || !stack.texts.isEmpty {
            flattened = drawVectorLayers(on: flattened, stack: stack, pixelSize: pixelSize)
        }

        // 6. Crop last.
        guard stack.isCropped else { return flattened }
        let bounds = CGRect(origin: .zero, size: pixelSize)
        // `.integral` rounds outward and can exceed the image by a pixel;
        // `cropping(to:)` returns nil out of bounds, silently dropping the edit.
        let cropRect = CGRect(
            x: stack.crop.minX * pixelSize.width,
            y: stack.crop.minY * pixelSize.height,
            width: stack.crop.width * pixelSize.width,
            height: stack.crop.height * pixelSize.height
        ).integral.intersection(bounds)

        guard !cropRect.isNull, cropRect.width >= 1, cropRect.height >= 1 else { return flattened }
        return flattened.cropping(to: cropRect) ?? flattened
    }

    // MARK: - Filters

    static func applyFilter(_ kind: ImageFilterKind, intensity: Double, to image: CIImage) -> CIImage {
        guard kind != .none else { return image }

        let filtered: CIImage
        switch kind {
        case .none:
            return image
        case .vivid:
            let vibrance = CIFilter.vibrance()
            vibrance.inputImage = image
            vibrance.amount = 0.6
            let controls = CIFilter.colorControls()
            controls.inputImage = vibrance.outputImage ?? image
            controls.saturation = 1.15
            filtered = controls.outputImage ?? image
        case .mono:
            let f = CIFilter.photoEffectMono()
            f.inputImage = image
            filtered = f.outputImage ?? image
        case .instant:
            let f = CIFilter.photoEffectInstant()
            f.inputImage = image
            filtered = f.outputImage ?? image
        case .fade:
            let f = CIFilter.photoEffectFade()
            f.inputImage = image
            filtered = f.outputImage ?? image
        case .cool:
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 5000, y: 0)
            filtered = f.outputImage ?? image
        case .warm:
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 8000, y: 0)
            filtered = f.outputImage ?? image
        case .process:
            let f = CIFilter.photoEffectProcess()
            f.inputImage = image
            filtered = f.outputImage ?? image
        }

        // The photoEffect* family has no intensity input, so intensity is a
        // uniform cross-fade back to the original for every filter.
        let clamped = min(max(intensity, 0), 1)
        guard clamped < 1 else { return filtered.cropped(to: image.extent) }

        let dissolve = CIFilter.dissolveTransition()
        dissolve.inputImage = image
        dissolve.targetImage = filtered
        dissolve.time = Float(clamped)
        return (dissolve.outputImage ?? filtered).cropped(to: image.extent)
    }

    // MARK: - Mosaic

    /// All redaction rects in one pass, masked over the source.
    static func applyMosaics(
        _ mosaics: [ImageMosaicRect],
        to image: CIImage,
        pixelSize: CGSize
    ) -> CIImage {
        guard !mosaics.isEmpty else { return image }

        var result = image
        // Pixelate and solid need different sources, so group by style.
        for style in ImageMosaicRect.Style.allCases {
            let group = mosaics.filter { $0.style == style }
            guard !group.isEmpty,
                  let maskCG = maskImage(for: group, pixelSize: pixelSize)
            else { continue }

            let mask = CIImage(cgImage: maskCG)
            let overlay: CIImage

            switch style {
            case .pixelate:
                let strength = group.map(\.strength).max() ?? 1
                let pixellate = CIFilter.pixellate()
                pixellate.inputImage = result
                // Pin the grid phase to the origin. Left at the default
                // (150,150) the grid drifts relative to the rect edges and
                // reads as misaligned.
                pixellate.center = CGPoint(x: 0, y: 0)
                pixellate.scale = Float(max(8, min(pixelSize.width, pixelSize.height) * 0.02 * strength))
                // CIPixellate has infinite extent — crop or the composite
                // acquires a transparent halo past the image bounds.
                overlay = (pixellate.outputImage ?? result).cropped(to: result.extent)
            case .solid:
                // Infinite extent, so crop like the pixelate branch.
                overlay = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
                    .cropped(to: result.extent)
            }

            let blend = CIFilter.blendWithMask()
            blend.inputImage = overlay
            blend.backgroundImage = result
            blend.maskImage = mask
            result = (blend.outputImage ?? result).cropped(to: image.extent)
        }

        return result
    }

    /// Black background, white rounded rects where the redaction applies.
    ///
    /// Built with CoreGraphics from the same y-down normalized rects used on
    /// screen, so it lines up with the CIImage without any y-flip — both are
    /// the same bitmap convention. (The flip only bites if you construct the
    /// mask analytically in CI coordinates.)
    static func maskImage(for mosaics: [ImageMosaicRect], pixelSize: CGSize) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard

        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        let image = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: pixelSize))

            UIColor.white.setFill()
            for mosaic in mosaics {
                let rect = CGRect(
                    x: mosaic.rect.minX * pixelSize.width,
                    y: mosaic.rect.minY * pixelSize.height,
                    width: mosaic.rect.width * pixelSize.width,
                    height: mosaic.rect.height * pixelSize.height
                )
                guard rect.width > 1, rect.height > 1 else { continue }
                let radius = min(rect.width, rect.height) * 0.02
                UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()
            }
        }
        return image.cgImage
    }

    // MARK: - Strokes and text

    static func drawVectorLayers(
        on base: CGImage,
        stack: ImageEditStack,
        pixelSize: CGSize
    ) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        // Defaults to the screen scale (3.0) — rendering at pixelSize with that
        // gives a 3x blow-up and 9x the memory.
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard

        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        let output = renderer.image { context in
            let cg = context.cgContext
            // `cgContext.draw(cgImage:in:)` draws vertically flipped here (the
            // CTM is already flipped for UIKit). Draw through UIImage instead.
            UIImage(cgImage: base).draw(in: CGRect(origin: .zero, size: pixelSize))

            // Strokes and text go in their own transparency layer so an eraser
            // stroke clears annotations without punching through to the photo.
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            for stroke in stack.strokes {
                draw(stroke, in: cg, pixelSize: pixelSize)
            }
            cg.endTransparencyLayer()

            for text in stack.texts {
                draw(text, in: cg, pixelSize: pixelSize)
            }
        }
        return output.cgImage ?? base
    }

    static func draw(_ stroke: ImageStroke, in context: CGContext, pixelSize: CGSize) {
        let points = stroke.points.map {
            CGPoint(x: $0.x * pixelSize.width, y: $0.y * pixelSize.height)
        }
        guard !points.isEmpty else { return }

        let width = max(1, CGFloat(stroke.widthFraction) * pixelSize.width)
        context.saveGState()
        context.setBlendMode(stroke.isEraser ? .destinationOut : .normal)
        context.setStrokeColor(UIColor(hex: stroke.colorHex).cgColor)
        context.setFillColor(UIColor(hex: stroke.colorHex).cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if points.count == 1 {
            // A single tap must still leave a dot.
            let r = width / 2
            context.fillEllipse(in: CGRect(
                x: points[0].x - r, y: points[0].y - r, width: width, height: width
            ))
        } else {
            context.addPath(smoothPath(through: points))
            context.strokePath()
        }
        context.restoreGState()
    }

    /// Quadratic midpoint smoothing — visually indistinguishable from PencilKit
    /// for finger drawing, and shared by the live Canvas preview so the export
    /// matches what the user saw.
    static func smoothPath(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        guard points.count > 2 else {
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            return path
        }

        path.move(to: first)
        for index in 1..<(points.count - 1) {
            let current = points[index]
            let next = points[index + 1]
            let mid = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
            path.addQuadCurve(to: mid, control: current)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    static func draw(_ item: ImageTextItem, in context: CGContext, pixelSize: CGSize) {
        let trimmed = item.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let fontSize = max(8, CGFloat(item.fontFraction) * pixelSize.height)
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(hex: item.colorHex),
        ]
        let string = NSAttributedString(string: trimmed, attributes: attributes)
        let size = string.size()
        let center = CGPoint(x: item.center.x * pixelSize.width, y: item.center.y * pixelSize.height)

        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: CGFloat(item.rotation))
        context.translateBy(x: -size.width / 2, y: -size.height / 2)

        if item.hasBackdrop {
            let padX = fontSize * 0.28
            let padY = fontSize * 0.14
            let plate = CGRect(
                x: -padX, y: -padY,
                width: size.width + padX * 2,
                height: size.height + padY * 2
            )
            UIColor.black.withAlphaComponent(0.42).setFill()
            UIBezierPath(roundedRect: plate, cornerRadius: fontSize * 0.22).fill()
        }

        string.draw(at: .zero)
        context.restoreGState()
    }

    // MARK: - Encoding

    @concurrent
    static func jpegData(from image: CGImage, quality: CGFloat = 0.85) async -> Data? {
        UIImage(cgImage: image).jpegData(compressionQuality: quality)
    }

    /// Composite + encode in one hop, for commit and for save-to-Photos.
    @concurrent
    static func exportJPEG(
        originalData: Data,
        stack: ImageEditStack,
        quality: CGFloat = 0.85
    ) async -> Data? {
        guard let base = decodeSync(data: originalData, maxPixel: editingMaxPixel),
              let composed = compositeSync(base: base, stack: stack)
        else { return nil }
        return UIImage(cgImage: composed).jpegData(compressionQuality: quality)
    }

    // MARK: - Helpers

    static func centerSquare(_ image: CGImage, maxPixel: CGFloat) -> CGImage? {
        let side = CGFloat(min(image.width, image.height))
        let rect = CGRect(
            x: (CGFloat(image.width) - side) / 2,
            y: (CGFloat(image.height) - side) / 2,
            width: side,
            height: side
        ).integral
        guard let cropped = image.cropping(to: rect) else { return nil }
        guard side > maxPixel else { return cropped }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let target = CGSize(width: maxPixel, height: maxPixel)
        let scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: target))
        }
        return scaled.cgImage
    }
}

// MARK: - Color

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
