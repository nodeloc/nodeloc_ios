//
//  ImageEditorView.swift
//  nodeloc
//
//  The composer's photo strip and its full-screen editor: text, draw, filters,
//  crop, mosaic, and save-to-Photos.
//
//  Edits are never applied destructively. The editor mutates an `ImageEditStack`
//  and only composites at commit time, so re-opening an image shows the previous
//  edits still live and adjustable.
//

import Photos
import SwiftUI
import UIKit

// MARK: - Thumbnail cache

/// Decoded strip thumbnails, keyed by attachment id + edit revision. Kept out of
/// `ComposeImageAttachment` so the model stays a cheap Sendable value type.
@MainActor
final class ComposeThumbnailCache {
    static let shared = ComposeThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: Set<String> = []

    init() {
        cache.countLimit = 64
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }

    /// Drops every revision of one attachment (called on delete and after an edit).
    func removeAll(forAttachment id: UUID) {
        // NSCache can't enumerate; revisions are monotonic so clearing a
        // generous window covers every key this attachment could hold.
        for revision in 0...64 {
            cache.removeObject(forKey: "\(id.uuidString)-\(revision)" as NSString)
        }
        inFlight = inFlight.filter { !$0.hasPrefix(id.uuidString) }
    }

    func beginLoad(key: String) -> Bool {
        inFlight.insert(key).inserted
    }

    func endLoad(key: String) {
        inFlight.remove(key)
    }
}

/// `fullScreenCover(item:)` payload.
struct ComposeEditorTarget: Identifiable {
    let attachment: ComposeImageAttachment
    var id: UUID { attachment.id }
}

// MARK: - Attachment strip

/// Horizontal row of picked images above the composer body.
struct ComposeAttachmentStrip: View {
    let attachments: [ComposeImageAttachment]
    let onTap: (ComposeImageAttachment) -> Void
    let onDelete: (ComposeImageAttachment) -> Void
    let onRetry: (ComposeImageAttachment) -> Void

    private let tile: CGFloat = 96

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(attachments) { attachment in
                    tileView(attachment)
                }
            }
            .padding(.horizontal, 20)
            // Headroom for the delete badge, which overhangs the tile corner.
            // Clipping here is what usually makes this not match the design.
            .padding(.top, 10)
            .padding(.trailing, 10)
            .padding(.bottom, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func tileView(_ attachment: ComposeImageAttachment) -> some View {
        ComposeAttachmentThumbnail(attachment: attachment, size: tile)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            }
            .overlay { uploadOverlay(attachment) }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onTapGesture {
                if case .failed = attachment.upload {
                    onRetry(attachment)
                } else {
                    onTap(attachment)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    onDelete(attachment)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.black.opacity(0.72), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .offset(x: 8, y: -8)
            }
    }

    @ViewBuilder
    private func uploadOverlay(_ attachment: ComposeImageAttachment) -> some View {
        switch attachment.upload {
        case .pending, .uploading:
            ZStack {
                Color.black.opacity(0.32)
                ProgressView().tint(.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .failed:
            ZStack {
                Color.black.opacity(0.46)
                VStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .bold))
                    Text("重试")
                        .font(Theme.body(11, weight: .semibold))
                }
                .foregroundStyle(.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .ready:
            if !attachment.edits.isIdentity {
                // Marks an image the user has actually edited.
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Color.black.opacity(0.55), in: Circle())
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }
}

/// Loads (and caches) one strip thumbnail with the edit stack applied.
private struct ComposeAttachmentThumbnail: View {
    let attachment: ComposeImageAttachment
    let size: CGFloat

    @State private var image: UIImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Theme.hover
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .task(id: attachment.thumbnailKey) { await load() }
    }

    private func load() async {
        let key = attachment.thumbnailKey
        if let cached = ComposeThumbnailCache.shared.image(forKey: key) {
            image = cached
            return
        }
        guard ComposeThumbnailCache.shared.beginLoad(key: key) else { return }
        defer { ComposeThumbnailCache.shared.endLoad(key: key) }

        guard let cg = await ImageEditRenderer.thumbnail(
            data: attachment.originalData,
            stack: attachment.edits
        ) else { return }

        let rendered = UIImage(cgImage: cg)
        ComposeThumbnailCache.shared.store(rendered, forKey: key)
        guard key == attachment.thumbnailKey else { return }
        image = rendered
    }
}

// MARK: - Editor tools

enum ImageEditorTool: String, CaseIterable, Identifiable {
    case text
    case draw
    case filter
    case crop
    case mosaic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: "文本"
        case .draw: "绘图"
        case .filter: "效果"
        case .crop: "裁剪"
        case .mosaic: "打码"
        }
    }

    var icon: String {
        switch self {
        case .text: "textformat"
        case .draw: "scribble"
        case .filter: "camera.filters"
        case .crop: "crop"
        case .mosaic: "mosaic"
        }
    }
}

/// Which crop handle a drag grabbed.
private enum CropDragTarget: Equatable {
    case none
    case interior
    case corner(x: Int, y: Int)   // -1 = min edge, 1 = max edge
    case edgeX(Int)
    case edgeY(Int)
}

// MARK: - Editor state

@MainActor
@Observable
final class ImageEditorState {
    var stack: ImageEditStack
    private(set) var base: CGImage?
    private(set) var rasterPreview: CGImage?
    private(set) var filterThumbs: [ImageFilterKind: CGImage] = [:]
    private(set) var isLoading = true
    private(set) var isExporting = false

    var activeTool: ImageEditorTool?
    var strokeColor: UInt32 = 0xFF3B30
    var strokeWidth: CGFloat = 6
    var isErasing = false
    var mosaicStyle: ImageMosaicRect.Style = .pixelate
    var textColor: UInt32 = 0xFFFFFF
    var selectedTextID: UUID?
    var editingTextID: UUID?
    var textDraft = ""
    var saveMessage: String?

    private let originalData: Data
    private var undoStack: [ImageEditStack] = []
    private var previewTask: Task<Void, Never>?
    private var thumbTask: Task<Void, Never>?

    init(attachment: ComposeImageAttachment) {
        self.originalData = attachment.originalData
        self.stack = attachment.edits
    }

    var canUndo: Bool { !undoStack.isEmpty }

    /// The image shown under the vector layer: filtered/mosaicked when those
    /// tools are in play, otherwise the untouched base.
    var displayImage: CGImage? { rasterPreview ?? base }

    /// Crop shows the whole image so the window can be dragged back outward.
    var visibleRect: CGRect {
        activeTool == .crop ? ImageEditStack.full : stack.crop
    }

    func load() async {
        guard base == nil else { return }
        base = await ImageEditRenderer.decode(
            data: originalData,
            maxPixel: ImageEditRenderer.editingMaxPixel
        )
        isLoading = false
        refreshPreview()
        refreshFilterThumbs()
    }

    func release() {
        previewTask?.cancel()
        thumbTask?.cancel()
        base = nil
        rasterPreview = nil
        filterThumbs = [:]
    }

    // MARK: Undo

    /// Call *before* mutating `stack`.
    func checkpoint() {
        undoStack.append(stack)
        if undoStack.count > 40 { undoStack.removeFirst() }
    }

    /// Drops the most recent checkpoint when the edit it guarded was abandoned,
    /// so cancelling doesn't leave a no-op entry on the undo stack.
    func discardCheckpointIfUnchanged() {
        guard let last = undoStack.last, last == stack else { return }
        undoStack.removeLast()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        let neededRaster = previous.filter != stack.filter
            || previous.filterIntensity != stack.filterIntensity
            || previous.mosaics != stack.mosaics
        stack = previous
        selectedTextID = nil
        if neededRaster { refreshPreview() }
    }

    // MARK: Preview

    /// Debounced so dragging the intensity slider doesn't queue a render per frame.
    func refreshPreview() {
        previewTask?.cancel()
        guard let base else { return }
        guard stack.filter != .none || !stack.mosaics.isEmpty else {
            rasterPreview = nil
            return
        }

        let filter = stack.filter
        let intensity = stack.filterIntensity
        let mosaics = stack.mosaics
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let image = await ImageEditRenderer.rasterPreview(
                base: base,
                filter: filter,
                intensity: intensity,
                mosaics: mosaics
            )
            guard !Task.isCancelled else { return }
            self?.rasterPreview = image
        }
    }

    private func refreshFilterThumbs() {
        guard let base, filterThumbs.isEmpty else { return }
        thumbTask = Task { [weak self] in
            let thumbs = await ImageEditRenderer.filterThumbnails(base: base)
            guard !Task.isCancelled else { return }
            self?.filterThumbs = thumbs
        }
    }

    // MARK: Export

    /// Composites at full resolution. Returns nil when nothing was edited, which
    /// tells the composer to skip the re-upload entirely.
    func exportIfNeeded() async -> Data? {
        guard !stack.isIdentity else { return nil }
        isExporting = true
        defer { isExporting = false }
        return await ImageEditRenderer.exportJPEG(originalData: originalData, stack: stack)
    }

    func saveToPhotos() async {
        isExporting = true
        defer { isExporting = false }

        let data: Data?
        if stack.isIdentity {
            data = originalData
        } else {
            data = await ImageEditRenderer.exportJPEG(originalData: originalData, stack: stack)
        }
        guard let data else {
            saveMessage = "导出失败。"
            return
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            saveMessage = "没有相册权限，请在设置中允许。"
            return
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }
            saveMessage = "已保存到相册。"
        } catch {
            saveMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - Editor view

struct ImageEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: ComposeImageAttachment
    /// Passes back the edit stack and, when anything changed, the composited JPEG.
    let onCommit: (ImageEditStack, Data?) -> Void

    @State private var state: ImageEditorState
    @State private var liveStroke: ImageStroke?
    @State private var liveMosaic: CGRect?
    @State private var cropDrag: CropDragTarget = .none
    @State private var cropOrigin: CGRect = .zero
    @State private var textDragOrigin: CGPoint?
    @State private var textScaleOrigin: Double?
    @State private var textRotationOrigin: Double?

    init(
        attachment: ComposeImageAttachment,
        onCommit: @escaping (ImageEditStack, Data?) -> Void
    ) {
        self.attachment = attachment
        self.onCommit = onCommit
        _state = State(initialValue: ImageEditorState(attachment: attachment))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                canvasArea
                bottomPanel
            }
        }
        .task { await state.load() }
        .onDisappear { state.release() }
        .statusBarHidden()
        .alert(
            state.saveMessage ?? "",
            isPresented: Binding(
                get: { state.saveMessage != nil },
                set: { if !$0 { state.saveMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { state.saveMessage = nil }
        }
        .sheet(isPresented: isTextSheetPresented) { textSheet }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: 0) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            ForEach(ImageEditorTool.allCases) { tool in
                toolButton(tool)
            }

            toolBarButton(icon: "square.and.arrow.down", label: "保存") {
                Task { await state.saveToPhotos() }
            }

            Spacer(minLength: 0)

            Button {
                state.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(state.canUndo ? .white : .white.opacity(0.3))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(!state.canUndo)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private func toolButton(_ tool: ImageEditorTool) -> some View {
        let isActive = state.activeTool == tool
        return toolBarButton(icon: tool.icon, label: tool.label, isActive: isActive) {
            withAnimation(.quicker) {
                state.activeTool = isActive ? nil : tool
                state.selectedTextID = nil
            }
        }
    }

    private func toolBarButton(
        icon: String,
        label: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                Text(label)
                    .font(Theme.body(11, weight: .medium))
            }
            .foregroundStyle(isActive ? Color(hex: 0x4C8DFF) : .white)
            .frame(width: 52, height: 50)
        }
        .buttonStyle(.plain)
    }

    // MARK: Canvas

    private var canvasArea: some View {
        GeometryReader { proxy in
            let transform = ImageDisplayTransform(
                pixelSize: attachment.pixelSize,
                visibleRect: state.visibleRect,
                containerSize: proxy.size
            )

            ZStack {
                if let image = state.displayImage {
                    Image(uiImage: UIImage(cgImage: image))
                        .resizable()
                        .scaledToFit()
                        .frame(width: transform.fittedRect.width, height: transform.fittedRect.height)
                        .position(x: transform.fittedRect.midX, y: transform.fittedRect.midY)
                        .clipped()
                } else if state.isLoading {
                    ProgressView().tint(.white)
                }

                vectorLayer(transform)

                if state.activeTool == .crop {
                    cropOverlay(transform)
                }
            }
            .contentShape(Rectangle())
            .gesture(canvasGesture(transform))
        }
    }

    /// Strokes, mosaics-in-progress, and text — redrawn every frame, never
    /// round-tripped through the rasterizer.
    private func vectorLayer(_ transform: ImageDisplayTransform) -> some View {
        ZStack {
            Canvas { context, _ in
                for stroke in state.stack.strokes {
                    draw(stroke, in: &context, transform: transform)
                }
                if let liveStroke {
                    draw(liveStroke, in: &context, transform: transform)
                }
                if let liveMosaic {
                    let rect = transform.viewRect(liveMosaic)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 4),
                        with: .color(.white.opacity(0.35))
                    )
                    context.stroke(
                        Path(roundedRect: rect, cornerRadius: 4),
                        with: .color(.white.opacity(0.9)),
                        lineWidth: 1.5
                    )
                }
            }
            .allowsHitTesting(false)

            ForEach(state.stack.texts) { item in
                textOverlay(item, transform: transform)
            }
        }
    }

    private func draw(
        _ stroke: ImageStroke,
        in context: inout GraphicsContext,
        transform: ImageDisplayTransform
    ) {
        let points = stroke.points.map { transform.viewPoint($0) }
        guard !points.isEmpty else { return }
        let width = max(1, transform.viewLength(fromWidthFraction: stroke.widthFraction))
        let color = Color(hex: stroke.colorHex)

        if points.count == 1 {
            let r = width / 2
            context.fill(
                Path(ellipseIn: CGRect(
                    x: points[0].x - r, y: points[0].y - r, width: width, height: width
                )),
                with: .color(color)
            )
            return
        }

        // Same path construction the exporter uses, so preview matches output.
        let path = Path(ImageEditRenderer.smoothPath(through: points))
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        )
    }

    private func textOverlay(_ item: ImageTextItem, transform: ImageDisplayTransform) -> some View {
        let fontSize = max(9, transform.viewLength(fromHeightFraction: item.fontFraction))
        let isSelected = state.selectedTextID == item.id

        return Text(item.string)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(Color(hex: item.colorHex))
            .padding(.horizontal, item.hasBackdrop ? fontSize * 0.28 : 0)
            .padding(.vertical, item.hasBackdrop ? fontSize * 0.14 : 0)
            .background {
                if item.hasBackdrop {
                    RoundedRectangle(cornerRadius: fontSize * 0.22, style: .continuous)
                        .fill(.black.opacity(0.42))
                }
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: fontSize * 0.22, style: .continuous)
                        .strokeBorder(Color(hex: 0x4C8DFF), lineWidth: 1.5)
                }
            }
            .rotationEffect(.radians(item.rotation))
            .position(transform.viewPoint(item.center))
            .gesture(textGesture(item, transform: transform))
            .onTapGesture(count: 2) { beginEditingText(item) }
            .onTapGesture { state.selectedTextID = item.id }
    }

    // MARK: Crop overlay

    private func cropOverlay(_ transform: ImageDisplayTransform) -> some View {
        let rect = transform.viewRect(state.stack.crop)
        let full = transform.fittedRect

        return ZStack {
            // Even-odd cutout dims everything outside the crop window.
            Path { path in
                path.addRect(full)
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

            Rectangle()
                .strokeBorder(.white, lineWidth: 1)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            // Rule-of-thirds guides.
            Path { path in
                for i in 1...2 {
                    let x = rect.minX + rect.width * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: rect.minY))
                    path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    let y = rect.minY + rect.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: rect.minX, y: y))
                    path.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            .stroke(.white.opacity(0.25), lineWidth: 0.8)

            // L-shaped corner handles.
            ForEach(cornerOffsets, id: \.self) { point in
                let x = rect.minX + rect.width * point.x
                let y = rect.minY + rect.height * point.y
                let hx = point.x == 0 ? x + 9 : x - 9
                let vy = point.y == 0 ? y + 9 : y - 9
                Rectangle()
                    .fill(.white)
                    .frame(width: 20, height: 3)
                    .position(x: hx, y: y)
                Rectangle()
                    .fill(.white)
                    .frame(width: 3, height: 20)
                    .position(x: x, y: vy)
            }
        }
        .allowsHitTesting(false)
    }

    private var cornerOffsets: [CGPoint] {
        [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 1),
            CGPoint(x: 1, y: 1),
        ]
    }

    // MARK: Bottom panel

    @ViewBuilder
    private var bottomPanel: some View {
        VStack(spacing: 12) {
            switch state.activeTool {
            case .draw: drawPanel
            case .filter: filterPanel
            case .crop: cropPanel
            case .mosaic: mosaicPanel
            case .text: textPanel
            case nil: EmptyView()
            }

            HStack {
                Spacer()
                Button {
                    commit()
                } label: {
                    Group {
                        if state.isExporting {
                            ProgressView().tint(.white)
                        } else {
                            Text("更新")
                                .font(Theme.body(15, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 88, height: 40)
                    .background(Color(hex: 0x1B6BFF), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(state.isExporting)
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 10)
    }

    private var drawPanel: some View {
        VStack(spacing: 10) {
            colorRow(selection: state.strokeColor) { hex in
                state.strokeColor = hex
                state.isErasing = false
            }

            HStack(spacing: 14) {
                Image(systemName: "scribble.variable")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Slider(value: $state.strokeWidth, in: 2...36)
                    .tint(Color(hex: 0x4C8DFF))
                Button {
                    state.isErasing.toggle()
                } label: {
                    Image(systemName: "eraser")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(state.isErasing ? Color(hex: 0x4C8DFF) : .white)
                        .frame(width: 38, height: 32)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
        }
    }

    private var filterPanel: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(ImageFilterKind.allCases) { kind in
                        filterSwatch(kind)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)

            if state.stack.filter != .none {
                HStack(spacing: 14) {
                    Text("强度")
                        .font(Theme.body(12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                    Slider(
                        value: Binding(
                            get: { state.stack.filterIntensity },
                            set: { state.stack.filterIntensity = $0; state.refreshPreview() }
                        ),
                        in: 0...1
                    )
                    .tint(Color(hex: 0x4C8DFF))
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func filterSwatch(_ kind: ImageFilterKind) -> some View {
        let isActive = state.stack.filter == kind
        return Button {
            state.checkpoint()
            state.stack.filter = kind
            state.stack.filterIntensity = 1
            state.refreshPreview()
        } label: {
            VStack(spacing: 5) {
                Group {
                    if let thumb = state.filterThumbs[kind] {
                        Image(uiImage: UIImage(cgImage: thumb))
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.white.opacity(0.12)
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isActive ? Color(hex: 0x4C8DFF) : .white.opacity(0.18),
                            lineWidth: isActive ? 2 : 1
                        )
                }

                Text(kind.label)
                    .font(Theme.body(11, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Color(hex: 0x4C8DFF) : .white.opacity(0.75))
            }
        }
        .buttonStyle(.plain)
    }

    private var cropPanel: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(ImageCropAspect.allCases) { aspect in
                    Button {
                        state.checkpoint()
                        state.stack.cropAspect = aspect
                        state.stack.crop = applyAspect(
                            to: state.stack.crop,
                            aspect: aspect,
                            anchor: .interior
                        )
                    } label: {
                        Text(aspect.label)
                            .font(Theme.body(13, weight: .medium))
                            .foregroundStyle(state.stack.cropAspect == aspect ? .black : .white)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(
                                state.stack.cropAspect == aspect ? Color.white : Color.white.opacity(0.14),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    state.checkpoint()
                    state.stack.crop = ImageEditStack.full
                    state.stack.cropAspect = .free
                } label: {
                    Text("重置")
                        .font(Theme.body(13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }

    private var mosaicPanel: some View {
        HStack(spacing: 10) {
            ForEach(ImageMosaicRect.Style.allCases, id: \.self) { style in
                Button {
                    state.mosaicStyle = style
                } label: {
                    Text(style.label)
                        .font(Theme.body(13, weight: .medium))
                        .foregroundStyle(state.mosaicStyle == style ? .black : .white)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background(
                            state.mosaicStyle == style ? Color.white : Color.white.opacity(0.14),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Text("拖动涂抹要遮挡的区域")
                .font(Theme.body(11))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 20)
    }

    private var textPanel: some View {
        VStack(spacing: 10) {
            colorRow(selection: state.textColor) { hex in
                state.textColor = hex
                if let id = state.selectedTextID,
                   let index = state.stack.texts.firstIndex(where: { $0.id == id }) {
                    state.checkpoint()
                    state.stack.texts[index].colorHex = hex
                }
            }

            HStack(spacing: 10) {
                Button {
                    beginAddingText()
                } label: {
                    Label("添加文本", systemImage: "plus")
                        .font(Theme.body(13, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)

                if let id = state.selectedTextID,
                   let index = state.stack.texts.firstIndex(where: { $0.id == id }) {
                    Button {
                        state.checkpoint()
                        state.stack.texts[index].hasBackdrop.toggle()
                    } label: {
                        Image(systemName: "rectangle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(state.stack.texts[index].hasBackdrop ? Color(hex: 0x4C8DFF) : .white)
                            .frame(width: 38, height: 32)
                    }
                    .buttonStyle(.plain)

                    Button {
                        state.checkpoint()
                        state.stack.texts.remove(at: index)
                        state.selectedTextID = nil
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 32)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Text("双击文字可编辑")
                    .font(Theme.body(11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 20)
        }
    }

    private func colorRow(selection: UInt32, onPick: @escaping (UInt32) -> Void) -> some View {
        let palette: [UInt32] = [
            0xFFFFFF, 0x000000, 0xFF3B30, 0xFF9500, 0xFFCC00,
            0x34C759, 0x00C7BE, 0x0A84FF, 0xAF52DE, 0xFF2D55,
        ]
        return ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(palette, id: \.self) { hex in
                    Button { onPick(hex) } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 26, height: 26)
                            .overlay {
                                Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1)
                            }
                            .overlay {
                                if selection == hex {
                                    Circle()
                                        .strokeBorder(Color(hex: 0x4C8DFF), lineWidth: 2.5)
                                        .padding(-4)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 5)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Text sheet

    private var isTextSheetPresented: Binding<Bool> {
        Binding(
            get: { state.editingTextID != nil },
            set: { if !$0 { state.editingTextID = nil } }
        )
    }

    private var textSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField("输入文字", text: $state.textDraft)
                    .font(Theme.body(18))
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                Spacer()
            }
            .navigationTitle("文本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { cancelTextEditing() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { commitTextEditing() }
                }
            }
        }
        .presentationDetents([.height(190)])
    }

    private func beginAddingText() {
        let item = ImageTextItem(
            string: "",
            center: CGPoint(x: state.stack.crop.midX, y: state.stack.crop.midY),
            colorHex: state.textColor
        )
        state.checkpoint()
        state.stack.texts.append(item)
        state.selectedTextID = item.id
        state.textDraft = ""
        state.editingTextID = item.id
    }

    /// Re-editing an existing item mutates it on commit, so the checkpoint has
    /// to be taken here — `beginAddingText` only covers newly created items.
    private func beginEditingText(_ item: ImageTextItem) {
        state.checkpoint()
        state.selectedTextID = item.id
        state.textDraft = item.string
        state.editingTextID = item.id
    }

    private func commitTextEditing() {
        defer {
            state.editingTextID = nil
            state.discardCheckpointIfUnchanged()
        }
        guard let id = state.editingTextID,
              let index = state.stack.texts.firstIndex(where: { $0.id == id })
        else { return }

        let trimmed = state.textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            state.stack.texts.remove(at: index)
            state.selectedTextID = nil
        } else {
            state.stack.texts[index].string = trimmed
            state.stack.texts[index].colorHex = state.textColor
        }
    }

    private func cancelTextEditing() {
        defer {
            state.editingTextID = nil
            state.discardCheckpointIfUnchanged()
        }
        guard let id = state.editingTextID,
              let index = state.stack.texts.firstIndex(where: { $0.id == id })
        else { return }
        // A brand-new item with no text yet shouldn't linger.
        if state.stack.texts[index].string.isEmpty {
            state.stack.texts.remove(at: index)
            state.selectedTextID = nil
        }
    }

    // MARK: Gestures

    private func canvasGesture(_ transform: ImageDisplayTransform) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                switch state.activeTool {
                case .draw: updateLiveStroke(value, transform: transform)
                case .mosaic: updateLiveMosaic(value, transform: transform)
                case .crop: updateCrop(value, transform: transform)
                default: break
                }
            }
            .onEnded { value in
                switch state.activeTool {
                case .draw: finishLiveStroke()
                case .mosaic: finishLiveMosaic()
                case .crop: cropDrag = .none
                default: break
                }
                _ = value
            }
    }

    private func updateLiveStroke(_ value: DragGesture.Value, transform: ImageDisplayTransform) {
        let point = transform.normalized(value.location).clampedToUnitSquare()
        if var stroke = liveStroke {
            // Drop samples closer than ~2pt; smoothing handles the rest.
            if let last = stroke.points.last {
                let lastView = transform.viewPoint(last)
                guard lastView.distance(to: value.location) > 2 else { return }
            }
            stroke.points.append(point)
            liveStroke = stroke
        } else {
            liveStroke = ImageStroke(
                points: [point],
                colorHex: state.strokeColor,
                widthFraction: transform.widthFraction(fromViewLength: state.strokeWidth),
                isEraser: state.isErasing
            )
        }
    }

    private func finishLiveStroke() {
        guard let stroke = liveStroke else { return }
        liveStroke = nil
        guard !stroke.points.isEmpty else { return }
        state.checkpoint()
        state.stack.strokes.append(stroke)
    }

    private func updateLiveMosaic(_ value: DragGesture.Value, transform: ImageDisplayTransform) {
        let start = transform.normalized(value.startLocation).clampedToUnitSquare()
        let current = transform.normalized(value.location).clampedToUnitSquare()
        liveMosaic = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    private func finishLiveMosaic() {
        guard let rect = liveMosaic else { return }
        liveMosaic = nil
        // Ignore taps and hairlines.
        guard rect.width > 0.01, rect.height > 0.01 else { return }
        state.checkpoint()
        state.stack.mosaics.append(ImageMosaicRect(rect: rect, style: state.mosaicStyle))
        state.refreshPreview()
    }

    /// One gesture for the whole crop area; the grabbed handle is classified on
    /// the first change so nine overlapping hit targets can't fight.
    private func updateCrop(_ value: DragGesture.Value, transform: ImageDisplayTransform) {
        if cropDrag == .none {
            cropOrigin = state.stack.crop
            cropDrag = classifyCropDrag(at: value.startLocation, transform: transform)
            guard cropDrag != .none else { return }
            state.checkpoint()
        }

        let start = transform.normalized(value.startLocation)
        let current = transform.normalized(value.location)
        let dx = current.x - start.x
        let dy = current.y - start.y

        var rect = cropOrigin
        switch cropDrag {
        case .none:
            return
        case .interior:
            rect.origin.x += dx
            rect.origin.y += dy
            rect = rect.clampedToUnitSquare()
            state.stack.crop = rect
            return
        case .corner(let cx, let cy):
            apply(dx: dx, alongX: cx, to: &rect)
            apply(dy: dy, alongY: cy, to: &rect)
        case .edgeX(let cx):
            apply(dx: dx, alongX: cx, to: &rect)
        case .edgeY(let cy):
            apply(dy: dy, alongY: cy, to: &rect)
        }

        // Order matters: aspect, then clamp, then minimum size.
        rect = applyAspect(to: rect, aspect: state.stack.cropAspect, anchor: cropDrag)
        rect = rect.clampedToUnitSquare()
        rect = enforceMinimum(rect)
        state.stack.crop = rect
    }

    private func apply(dx: CGFloat, alongX edge: Int, to rect: inout CGRect) {
        if edge < 0 {
            let newX = min(rect.minX + dx, rect.maxX - 0.08)
            rect.size.width = rect.maxX - newX
            rect.origin.x = newX
        } else {
            rect.size.width = max(0.08, rect.width + dx)
        }
    }

    private func apply(dy: CGFloat, alongY edge: Int, to rect: inout CGRect) {
        if edge < 0 {
            let newY = min(rect.minY + dy, rect.maxY - 0.08)
            rect.size.height = rect.maxY - newY
            rect.origin.y = newY
        } else {
            rect.size.height = max(0.08, rect.height + dy)
        }
    }

    private func classifyCropDrag(
        at point: CGPoint,
        transform: ImageDisplayTransform
    ) -> CropDragTarget {
        let rect = transform.viewRect(state.stack.crop)
        let slop: CGFloat = 28

        let nearMinX = abs(point.x - rect.minX) < slop
        let nearMaxX = abs(point.x - rect.maxX) < slop
        let nearMinY = abs(point.y - rect.minY) < slop
        let nearMaxY = abs(point.y - rect.maxY) < slop
        let insideY = point.y > rect.minY - slop && point.y < rect.maxY + slop
        let insideX = point.x > rect.minX - slop && point.x < rect.maxX + slop

        if nearMinX && nearMinY { return .corner(x: -1, y: -1) }
        if nearMaxX && nearMinY { return .corner(x: 1, y: -1) }
        if nearMinX && nearMaxY { return .corner(x: -1, y: 1) }
        if nearMaxX && nearMaxY { return .corner(x: 1, y: 1) }
        if nearMinX && insideY { return .edgeX(-1) }
        if nearMaxX && insideY { return .edgeX(1) }
        if nearMinY && insideX { return .edgeY(-1) }
        if nearMaxY && insideX { return .edgeY(1) }
        if rect.contains(point) { return .interior }
        return .none
    }

    /// Constrains the free axis so the crop matches the locked pixel ratio.
    private func applyAspect(
        to rect: CGRect,
        aspect: ImageCropAspect,
        anchor: CropDragTarget
    ) -> CGRect {
        guard let ratio = aspect.pixelRatio(baseSize: attachment.pixelSize) else { return rect }
        let pixels = attachment.pixelSize
        guard pixels.width > 0, pixels.height > 0 else { return rect }

        // Convert the pixel ratio into normalized space.
        let normalizedRatio = ratio * Double(pixels.height / pixels.width)
        var result = rect

        switch anchor {
        case .edgeY, .corner(_, _):
            // Height drove the change: derive width from it.
            result.size.width = result.height * CGFloat(normalizedRatio)
        default:
            result.size.height = result.width / CGFloat(normalizedRatio)
        }

        if result.width > 1 {
            result.size.width = 1
            result.size.height = result.width / CGFloat(normalizedRatio)
        }
        if result.height > 1 {
            result.size.height = 1
            result.size.width = result.height * CGFloat(normalizedRatio)
        }
        return result
    }

    private func enforceMinimum(_ rect: CGRect) -> CGRect {
        var result = rect
        result.size.width = max(result.width, 0.08)
        result.size.height = max(result.height, 0.08)
        return result.clampedToUnitSquare()
    }

    private func textGesture(
        _ item: ImageTextItem,
        transform: ImageDisplayTransform
    ) -> some Gesture {
        let drag = DragGesture()
            .onChanged { value in
                guard let index = state.stack.texts.firstIndex(where: { $0.id == item.id }) else { return }
                if textDragOrigin == nil {
                    textDragOrigin = item.center
                    state.checkpoint()
                    state.selectedTextID = item.id
                }
                guard let origin = textDragOrigin else { return }
                let start = transform.normalized(value.startLocation)
                let current = transform.normalized(value.location)
                state.stack.texts[index].center = CGPoint(
                    x: origin.x + (current.x - start.x),
                    y: origin.y + (current.y - start.y)
                ).clampedToUnitSquare()
            }
            .onEnded { _ in textDragOrigin = nil }

        let magnify = MagnifyGesture()
            .onChanged { value in
                guard let index = state.stack.texts.firstIndex(where: { $0.id == item.id }) else { return }
                if textScaleOrigin == nil {
                    textScaleOrigin = item.fontFraction
                    state.checkpoint()
                }
                guard let origin = textScaleOrigin else { return }
                state.stack.texts[index].fontFraction = min(max(origin * value.magnification, 0.015), 0.5)
            }
            .onEnded { _ in textScaleOrigin = nil }

        let rotate = RotateGesture()
            .onChanged { value in
                guard let index = state.stack.texts.firstIndex(where: { $0.id == item.id }) else { return }
                if textRotationOrigin == nil {
                    textRotationOrigin = item.rotation
                    state.checkpoint()
                }
                guard let origin = textRotationOrigin else { return }
                state.stack.texts[index].rotation = origin + value.rotation.radians
            }
            .onEnded { _ in textRotationOrigin = nil }

        return drag.simultaneously(with: magnify.simultaneously(with: rotate))
    }

    // MARK: Commit

    private func commit() {
        Task {
            // isIdentity short-circuits the composite *and* the re-upload.
            let data = await state.exportIfNeeded()
            onCommit(state.stack, data)
            dismiss()
        }
    }
}

// MARK: - Color helper

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Previews

/// Synthetic gradient stand-in so previews don't depend on the photo library.
private func previewAttachment() -> ComposeImageAttachment {
    let size = CGSize(width: 1200, height: 900)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
        let colors = [UIColor.systemTeal.cgColor, UIColor.systemIndigo.cgColor] as CFArray
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 1]
        )!
        context.cgContext.drawLinearGradient(
            gradient,
            start: .zero,
            end: CGPoint(x: size.width, y: size.height),
            options: []
        )
        UIColor.white.withAlphaComponent(0.9).setFill()
        UIBezierPath(ovalIn: CGRect(x: 480, y: 330, width: 240, height: 240)).fill()
    }

    return ComposeImageAttachment(
        originalData: image.jpegData(compressionQuality: 0.9) ?? Data(),
        pixelSize: size,
        fileName: "preview.jpg",
        mimeType: "image/jpeg"
    )
}

#Preview("编辑器") {
    ImageEditorView(attachment: previewAttachment()) { _, _ in }
}

#Preview("缩略图条") {
    var uploading = previewAttachment()
    uploading.upload = .uploading
    var failed = previewAttachment()
    failed.upload = .failed("上传失败")
    var ready = previewAttachment()
    ready.upload = .ready("upload://abc")
    ready.edits.filter = .mono

    return ComposeAttachmentStrip(
        attachments: [ready, uploading, failed],
        onTap: { _ in },
        onDelete: { _ in },
        onRetry: { _ in }
    )
    .padding(.vertical, 30)
    .background(Theme.bg)
}
