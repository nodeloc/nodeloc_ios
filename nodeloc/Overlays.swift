//
//  Overlays.swift
//  nodeloc
//
//  Full-screen and drawer overlays: sidebar, post detail, notifications,
//  settings, and Nodeloc Pro.
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import WebKit


// MARK: - Compose

private enum ComposeFocusField: Hashable {
    case title
    case body
}

private enum ComposeLinkKind: String, Identifiable {
    case link
    case image
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .link: "添加链接"
        case .image: "添加图片链接"
        case .video: "添加视频链接"
        }
    }

    var message: String {
        switch self {
        case .link: "选中文字会变成链接；没有选中内容时会插入一个可编辑的链接标题。"
        case .image: "先用图片链接占位，发布时会转成 Discourse 图片语法。"
        case .video: "先用视频链接占位，发布时会转成 Discourse 链接。"
        }
    }

    var fallbackLabel: String {
        switch self {
        case .link: "链接标题"
        case .image: "图片"
        case .video: "视频"
        }
    }
}

private struct ComposeMediaAttachment: Identifiable {
    let id = UUID()
    let kind: ComposeLinkKind
    let label: String
    let composerURLString: String
    let previewURL: URL?

    var markdown: String {
        switch kind {
        case .image:
            "![\(escapedLabel)](\(composerURLString))"
        case .video:
            "[\(escapedLabel)](\(composerURLString))"
        case .link:
            "[\(escapedLabel)](\(composerURLString))"
        }
    }

    private var escapedLabel: String {
        label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }
}

private enum RichTextMarkdownRenderer {
    static func markdown(from text: AttributedString, mediaKindsByURL: [String: ComposeLinkKind]) -> String {
        let rendered = text.runs.reduce(into: "") { output, run in
            let rawText = String(text.characters[run.range])
            let mediaKind = run.link.flatMap { mediaKindsByURL[$0.absoluteString] }
            output += markdown(for: rawText, link: run.link, intent: run.inlinePresentationIntent, mediaKind: mediaKind)
        }
        return normalizeRichBullets(in: rendered)
    }

    private static func markdown(
        for rawText: String,
        link: URL?,
        intent: InlinePresentationIntent?,
        mediaKind: ComposeLinkKind?
    ) -> String {
        guard !rawText.isEmpty else { return "" }
        if let link {
            let label = sanitizedLinkLabel(rawText, fallback: mediaKind?.fallbackLabel ?? link.absoluteString)
            switch mediaKind {
            case .image:
                return "![\(label)](\(link.absoluteString))"
            case .video, .link, nil:
                let styledLabel = inlineStyled(label, intent: intent)
                return "[\(styledLabel)](\(link.absoluteString))"
            }
        }
        return inlineStyled(rawText, intent: intent)
    }

    private static func inlineStyled(_ text: String, intent: InlinePresentationIntent?) -> String {
        guard let intent else { return text }
        var rendered = text
        if intent.contains(.stronglyEmphasized) {
            rendered = "**\(rendered)**"
        }
        if intent.contains(.emphasized) {
            rendered = "*\(rendered)*"
        }
        if intent.contains(.strikethrough) {
            rendered = "~~\(rendered)~~"
        }
        return rendered
    }

    private static func sanitizedLinkLabel(_ text: String, fallback: String) -> String {
        let label = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        let nonEmpty = label.isEmpty ? fallback : label
        return nonEmpty
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private static func normalizeRichBullets(in text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line in
                let indentation = line.prefix { $0 == " " || $0 == "\t" }
                let bodyStart = line.firstIndex { $0 != " " && $0 != "\t" } ?? line.endIndex
                let body = line[bodyStart...]
                guard body.hasPrefix("• ") else { return line }
                return String(indentation) + "- " + String(body.dropFirst(2))
            }
            .joined(separator: "\n")
    }
}

struct ComposeOverlay: View {
    @Environment(AppState.self) private var app
    @State private var store = ComposeStore()
    @State private var title = ""
    @State private var bodyText = AttributedString()
    @State private var selectedCommunity: SidebarNodeSummary?
    @State private var showsNodePicker = false
    @State private var bodySelection = AttributedTextSelection()
    @State private var pendingLinkKind: ComposeLinkKind?
    @State private var pendingLinkRange: Range<AttributedString.Index>?
    @State private var linkURLText = ""
    @State private var imageSelections: [PhotosPickerItem] = []
    @State private var videoSelection: PhotosPickerItem?
    @State private var uploadingMediaKind: ComposeLinkKind?
    @State private var mediaAttachments: [ComposeMediaAttachment] = []
    @State private var imageAttachments: [ComposeImageAttachment] = []
    @State private var videoAttachment: ComposeVideoAttachment?
    @State private var editingAttachmentID: UUID?
    @State private var isTrimmingVideo = false
    /// Set the instant a video is picked, before the async decode finishes.
    /// Without this the image button stays enabled during that window and both
    /// media kinds can end up attached at once.
    @State private var isPreparingVideo = false
    /// Set on teardown so in-flight ingest tasks discard their temp files
    /// instead of attaching to a composer that's already gone.
    @State private var isComposerClosing = false
    @State private var poll: PollDraft?
    @State private var redEnvelope: RedEnvelopeDraft?
    @State private var redEnvelopeDraft = RedEnvelopeDraft()
    @State private var showsRedEnvelopeSheet = false
    @State private var lottery: LotteryDraft?
    @State private var lotteryDraft = LotteryDraft()
    @State private var showsLotterySheet = false
    /// Set when the topic posted but a follow-up record didn't.
    @State private var followUpRetryMessage: String?
    @FocusState private var focusedField: ComposeFocusField?

    /// One under the site's default `max_uploads_per_minute` of 10, leaving a
    /// slot for a post-edit re-upload.
    private let maxImageSelection = 9

    /// Derived, never stored — the toolbar can't fall out of sync with what's
    /// actually attached. Images and video are mutually exclusive.
    private var mediaMode: ComposeMediaMode {
        if videoAttachment != nil || isPreparingVideo { return .video }
        return imageAttachments.isEmpty ? .empty : .images
    }

    var body: some View {
        VStack(spacing: 0) {
            composeHeader
            composeEditor
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composeToolbar
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await store.loadCommunities() }
        .onAppear {
            focusedField = .title
            // Opened from a node page, so that node starts selected. Consumed
            // here so a later compose from the home feed doesn't inherit it.
            if let preselected = app.composePreselectedNode {
                selectedCommunity = preselected
                app.composePreselectedNode = nil
            }
        }
        .onDisappear { cleanUpMediaTempFiles() }
        .onChange(of: imageSelections) { _, items in
            ingestPickedImages(items)
        }
        .onChange(of: videoSelection) { _, item in
            ingestPickedVideo(item)
        }
        .fullScreenCover(isPresented: $showsNodePicker) {
            ComposeNodePicker(store: store, selection: $selectedCommunity)
        }
        .fullScreenCover(item: editingAttachmentBinding) { target in
            ImageEditorView(attachment: target.attachment) { edits, data in
                applyEdit(edits, exportedData: data, to: target.attachment.id)
            }
        }
        .fullScreenCover(isPresented: $isTrimmingVideo) {
            if let video = videoAttachment {
                VideoTrimmerView(attachment: video) { plan, exportedURL in
                    applyVideoEdit(plan, exportedURL: exportedURL, to: video.id)
                }
            }
        }
        .sheet(isPresented: $showsRedEnvelopeSheet) {
            RedEnvelopeSheet(
                draft: $redEnvelopeDraft,
                limits: store.redEnvelopeLimits,
                userPoints: store.userPoints
            ) { confirmed in
                redEnvelope = confirmed
            }
        }
        .sheet(isPresented: $showsLotterySheet) {
            LotterySheet(
                draft: $lotteryDraft,
                limits: store.lotteryLimits,
                trustLevels: store.trustLevelNames,
                isAttached: lottery != nil
            ) { confirmed in
                lottery = confirmed
            }
        }
        .alert(pendingLinkKind?.title ?? "添加链接", isPresented: isLinkPromptPresented) {
            TextField("https://example.com", text: $linkURLText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) { resetLinkPrompt() }
            Button("添加") { commitLinkPrompt() }
        } message: {
            Text(pendingLinkKind?.message ?? "")
        }
        // The topic is already live at this point, so the only choices are
        // retrying the follow-up records or leaving the post without them.
        .alert(
            "部分内容未创建",
            isPresented: Binding(
                get: { followUpRetryMessage != nil },
                set: { if !$0 { followUpRetryMessage = nil } }
            )
        ) {
            Button("重试") { retryFollowUps() }
            Button("不了", role: .cancel) {
                followUpRetryMessage = nil
                closeOverlay(app)
            }
        } message: {
            Text(followUpRetryMessage ?? "")
        }
    }

    private var canPost: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && selectedCommunity != nil
        && !store.isSubmitting
        && !store.isUploadingMedia
        && failedUploadCount == 0
        && pollError == nil
        // The topic is already live once this is set; re-posting would create a
        // duplicate and charge the red envelope twice.
        && !store.hasPublished
    }

    /// An invalid poll emits no markup, so posting would quietly drop it.
    private var pollError: String? {
        poll?.validationError(maximumOptions: store.pollMaximumOptions)
    }

    private var isLinkPromptPresented: Binding<Bool> {
        Binding {
            pendingLinkKind != nil
        } set: { isPresented in
            if !isPresented {
                resetLinkPrompt()
            }
        }
    }

    private var composeHeader: some View {
        HStack(spacing: 12) {
            Button { closeOverlay(app) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
            .buttonBorderShape(.circle)
            .shadow(color: .black.opacity(0.08), radius: 9, y: 6)

            Button {
                showsNodePicker = true
            } label: {
                HStack(spacing: 6) {
                    Text(selectedCommunity.map { "n/\($0.slug)" } ?? "选择节点")
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.muted(0.65))
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
            }
            .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
            .buttonBorderShape(.capsule)
            .shadow(color: .black.opacity(0.08), radius: 9, y: 6)

            Spacer(minLength: 8)

            Button {
                submit()
            } label: {
                Group {
                    if store.isSubmitting {
                        ProgressView()
                            .tint(Theme.muted(0.55))
                    } else {
                        Text("发帖")
                            .font(Theme.body(15, weight: .semibold))
                    }
                }
                .foregroundStyle(canPost ? Theme.text : Theme.muted(0.38))
                .padding(.horizontal, 14)
                .frame(height: 34)
            }
            .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
            .buttonBorderShape(.capsule)
            .disabled(!canPost)
            .opacity(canPost ? 1 : 0.58)
            .shadow(color: .black.opacity(0.08), radius: 9, y: 6)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 22)
    }

    private var composeEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                TextField("标题", text: $title, axis: .vertical)
                    .font(Theme.heading(22, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1...3)
                    .textInputAutocapitalization(.sentences)
                    .focused($focusedField, equals: .title)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .body }

                // Media sits above the body, matching where it lands in the
                // posted markdown.
                if !imageAttachments.isEmpty {
                    ComposeAttachmentStrip(
                        attachments: imageAttachments,
                        onTap: { editingAttachmentID = $0.id },
                        onDelete: { removeImageAttachment($0.id) },
                        onRetry: { retryUpload($0.id) }
                    )
                    .padding(.horizontal, -20)
                }

                if let video = videoAttachment {
                    ComposeVideoTile(
                        attachment: video,
                        onTap: { isTrimmingVideo = true },
                        onDelete: { removeVideoAttachment() },
                        onRetry: { Task { await uploadVideoAttachment() } }
                    )
                }

                if poll != nil {
                    PollComposerCard(
                        draft: Binding(
                            get: { poll ?? PollDraft() },
                            set: { poll = $0 }
                        ),
                        maximumOptions: store.pollMaximumOptions,
                        onRemove: { poll = nil }
                    )
                }

                if let envelope = redEnvelope {
                    RedEnvelopeChip(
                        draft: envelope,
                        onTap: { showsRedEnvelopeSheet = true },
                        onRemove: { redEnvelope = nil }
                    )
                }

                if let lotteryDraw = lottery {
                    LotteryChip(
                        draft: lotteryDraw,
                        onTap: { showsLotterySheet = true },
                        onRemove: { lottery = nil }
                    )
                }

                ZStack(alignment: .topLeading) {
                    if bodyText.characters.isEmpty {
                        Text("正文文本（可选）")
                            .font(Theme.body(16))
                            .foregroundStyle(Theme.muted(0.62))
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $bodyText, selection: $bodySelection)
                        .font(Theme.body(16))
                        .foregroundStyle(Theme.text)
                        .scrollContentBackground(.hidden)
                        .background(.clear)
                        .focused($focusedField, equals: .body)
                        .frame(minHeight: 320, alignment: .top)
                }

                if !mediaAttachments.isEmpty {
                    composeMediaAttachments
                }

                if let errorText = store.errorText {
                    Text(errorText)
                        .font(Theme.body(13, weight: .medium))
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if failedUploadCount > 0 {
                    Text("有 \(failedUploadCount) 张图片上传失败，点击缩略图重试。")
                        .font(Theme.body(13, weight: .medium))
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if store.isUploadingMedia {
                    Text("正在上传媒体...")
                        .font(Theme.body(13, weight: .medium))
                        .foregroundStyle(Theme.muted(0.62))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
        .tint(Color(light: 0x3366FF, dark: 0x7EA7FF))
    }

    private var composeMediaAttachments: some View {
        VStack(spacing: 8) {
            ForEach(mediaAttachments) { attachment in
                HStack(spacing: 10) {
                    mediaThumbnail(for: attachment)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(attachment.label)
                            .font(Theme.body(14, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Text(attachment.kind == .image ? "图片已上传" : "视频已上传")
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.muted(0.58))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Button {
                        mediaAttachments.removeAll { $0.id == attachment.id }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.muted(0.62))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(Theme.surface.opacity(0.86), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.divider, lineWidth: 1)
                )
            }
        }
    }

    @ViewBuilder
    private func mediaThumbnail(for attachment: ComposeMediaAttachment) -> some View {
        if attachment.kind == .image, let previewURL = attachment.previewURL {
            AsyncImage(url: previewURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                default:
                    Image(systemName: "photo")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.58))
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.hover)
                Image(systemName: attachment.kind == .video ? "play.fill" : "paperclip")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.text)
            }
            .frame(width: 48, height: 48)
        }
    }

    /// Scrolls horizontally: nine buttons plus the divider overflow a phone's
    /// width, and shrinking them below 44pt would break the minimum tap target.
    private var composeToolbar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                // Content insertions first, then text formatting.
                toolbarImagePicker
                toolbarVideoPicker
                toolbarLotteryButton
                toolbarRedEnvelopeButton
                toolbarPollButton

                Rectangle()
                    .fill(Theme.divider)
                    .frame(width: 1, height: 28)
                    .padding(.horizontal, 8)

                toolbarIcon("LucideBold", isActive: selectionHasInlineIntent(.stronglyEmphasized)) {
                    toggleInlineIntent(.stronglyEmphasized, placeholder: "加粗文字")
                }
                toolbarIcon("LucideItalic", isActive: selectionHasInlineIntent(.emphasized)) {
                    toggleInlineIntent(.emphasized, placeholder: "斜体文字")
                }
                toolbarIcon("LucideStrikethrough", isActive: selectionHasInlineIntent(.strikethrough)) {
                    toggleInlineIntent(.strikethrough, placeholder: "删除线文字")
                }
                toolbarIcon("LucideList") { toggleBulletList() }
                toolbarHeadingButton
                toolbarIcon("LucideLink", isActive: selectionHasLink) { showLinkPrompt(.link) }
                toolbarIcon("LucideQuote") { toggleBlockquote() }
                toolbarIcon("LucideEyeOff") { wrapSpoiler() }
            }
            .padding(.horizontal, 6)
        }
        .scrollIndicators(.hidden)
        // Let the row shrink to its content when it fits, so a short toolbar
        // stays centred instead of stretching to a full-width pill.
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .glassEffect(.regular.tint(Theme.bg.opacity(0.42)), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.08), radius: 18, y: 10)
    }

    /// One poll per post, matching the web builder.
    private var toolbarPollButton: some View {
        toolbarIcon(
            "LucideVote",
            disabled: !store.canCreatePoll,
            isActive: poll != nil
        ) {
            if poll == nil {
                poll = PollDraft()
            } else {
                poll = nil
            }
        }
    }

    private var toolbarRedEnvelopeButton: some View {
        toolbarIcon(
            "LucideHandCoins",
            disabled: !store.isRedEnvelopeEnabled,
            isActive: redEnvelope != nil
        ) {
            showsRedEnvelopeSheet = true
        }
    }

    /// One lottery per post, enforced server-side by a uniqueness constraint on
    /// `post_id`.
    private var toolbarLotteryButton: some View {
        toolbarIcon(
            "LucideGift",
            disabled: !store.isLotteryEnabled,
            isActive: lottery != nil
        ) {
            showsLotterySheet = true
        }
    }

    /// "Text size" in Discourse's composer is heading level, not a `[size]`
    /// bbcode — core has no such tag. Mirrors the `heading` toolbar button's
    /// popup: H1–H4, normal paragraph, and `<small>`.
    private var toolbarHeadingButton: some View {
        Menu {
            ForEach(1...4, id: \.self) { level in
                Button("标题 \(level)") { applyHeading(level) }
            }
            Button("正文") { applyHeading(0) }
            Button("小号文字") { wrapSmallText() }
        } label: {
            toolbarAssetIcon("LucideType", disabled: false, isActive: false)
        }
    }

    /// Lucide icons ship as template-rendered vector assets, so they tint from
    /// `foregroundStyle` exactly like SF Symbols did.
    private func toolbarAssetIcon(_ name: String, disabled: Bool, isActive: Bool) -> some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 21, height: 21)
            .foregroundStyle(toolbarColor(disabled: disabled, isActive: isActive))
            .frame(width: 44, height: 40)
    }

    private func toolbarIcon(
        _ assetName: String,
        disabled: Bool = false,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            toolbarAssetIcon(assetName, disabled: disabled, isActive: isActive)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    /// Multi-select image picker. Remaining capacity shrinks as attachments are
    /// added so a second batch can't push past the rate limit. Disabled once a
    /// video is attached — Discourse posts read better with one media kind, and
    /// the poster/SHA1 pairing assumes a single video.
    private var toolbarImagePicker: some View {
        let atCapacity = imageAttachments.count >= maxImageSelection
        let blocked = !mediaMode.allowsImages || atCapacity

        return PhotosPicker(
            selection: $imageSelections,
            maxSelectionCount: max(1, maxImageSelection - imageAttachments.count),
            selectionBehavior: .ordered,
            matching: .images,
            preferredItemEncoding: .compatible
        ) {
            toolbarAssetIcon("LucideImage", disabled: blocked, isActive: mediaMode == .images)
        }
        .buttonStyle(.plain)
        .disabled(store.isSubmitting || blocked)
    }

    /// Single video picker, disabled while images are attached.
    private var toolbarVideoPicker: some View {
        let blocked = !mediaMode.allowsVideo

        return PhotosPicker(
            selection: $videoSelection,
            matching: .videos,
            preferredItemEncoding: .compatible
        ) {
            Group {
                if uploadingMediaKind == .video {
                    ProgressView()
                        .tint(Theme.text)
                        .frame(width: 44, height: 40)
                } else {
                    toolbarAssetIcon("LucideSquarePlay", disabled: blocked, isActive: mediaMode == .video)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(store.isSubmitting || blocked)
    }

    private func toolbarColor(disabled: Bool, isActive: Bool) -> Color {
        if disabled { return Theme.muted(0.28) }
        if isActive { return Color(light: 0x3366FF, dark: 0x7EA7FF) }
        return Theme.text
    }

    private var selectionHasLink: Bool {
        bodySelection.attributes(in: bodyText)[\.link].contains { $0 != nil }
    }

    private func selectionHasInlineIntent(_ intent: InlinePresentationIntent) -> Bool {
        let values = Array(bodySelection.attributes(in: bodyText)[\.inlinePresentationIntent])
        return !values.isEmpty && values.allSatisfy { $0?.contains(intent) == true }
    }

    private func selectedBodyRange() -> Range<AttributedString.Index> {
        switch bodySelection.indices(in: bodyText) {
        case .insertionPoint(let index):
            index..<index
        case .ranges(let ranges):
            ranges.ranges.first ?? bodyText.endIndex..<bodyText.endIndex
        @unknown default:
            bodyText.endIndex..<bodyText.endIndex
        }
    }

    private func replaceBodyText(
        in range: Range<AttributedString.Index>,
        with replacement: AttributedString,
        selecting selectionInReplacement: Range<Int>? = nil
    ) {
        let lowerOffset = bodyText.characters.distance(from: bodyText.startIndex, to: range.lowerBound)
        bodyText.replaceSubrange(range, with: replacement)

        let replacementStart = bodyText.index(bodyText.startIndex, offsetByCharacters: lowerOffset)
        if let selectionInReplacement {
            let lower = bodyText.index(replacementStart, offsetByCharacters: selectionInReplacement.lowerBound)
            let upper = bodyText.index(replacementStart, offsetByCharacters: selectionInReplacement.upperBound)
            bodySelection = selectionInReplacement.isEmpty
                ? AttributedTextSelection(insertionPoint: lower)
                : AttributedTextSelection(range: lower..<upper)
        } else {
            let insertionPoint = bodyText.index(replacementStart, offsetByCharacters: replacement.characters.count)
            bodySelection = AttributedTextSelection(insertionPoint: insertionPoint)
        }
        focusedField = .body
    }

    private func replaceBodyText(
        in range: Range<AttributedString.Index>,
        with replacement: String,
        selecting selectionInReplacement: Range<Int>? = nil
    ) {
        replaceBodyText(in: range, with: AttributedString(replacement), selecting: selectionInReplacement)
    }

    private func toggleInlineIntent(_ intent: InlinePresentationIntent, placeholder: String) {
        let range = selectedBodyRange()
        if range.isEmpty {
            var replacement = AttributedString(placeholder)
            replacement[replacement.startIndex..<replacement.endIndex].inlinePresentationIntent = intent
            replaceBodyText(in: range, with: replacement, selecting: 0..<replacement.characters.count)
            return
        }

        let shouldRemove = selectionHasInlineIntent(intent)
        for run in bodyText[range].runs {
            var current = run.inlinePresentationIntent ?? []
            if shouldRemove {
                current.remove(intent)
            } else {
                current.insert(intent)
            }
            bodyText[run.range].inlinePresentationIntent = current.isEmpty ? nil : current
        }
        bodySelection = AttributedTextSelection(range: range)
        focusedField = .body
    }

    private func showLinkPrompt(_ kind: ComposeLinkKind) {
        pendingLinkRange = selectedBodyRange()
        pendingLinkKind = kind
        linkURLText = bodySelection.attributes(in: bodyText)[\.link]
            .compactMap { $0?.absoluteString }
            .first ?? ""
    }

    private func commitLinkPrompt() {
        guard pendingLinkKind == .link, let url = normalizedURL(from: linkURLText) else {
            resetLinkPrompt()
            return
        }

        let range = pendingLinkRange ?? selectedBodyRange()
        applyLink(url, in: range)
        resetLinkPrompt()
    }

    private func resetLinkPrompt() {
        pendingLinkKind = nil
        pendingLinkRange = nil
        linkURLText = ""
    }

    private func applyLink(_ url: URL, in range: Range<AttributedString.Index>) {
        if range.isEmpty {
            insertLinkedText(ComposeLinkKind.link.fallbackLabel, url: url, in: range, selectingLabel: true)
        } else {
            bodyText[range].link = url
            bodySelection = AttributedTextSelection(range: range)
            focusedField = .body
        }
    }

    private func insertLinkedText(
        _ label: String,
        url: URL,
        in range: Range<AttributedString.Index>,
        selectingLabel: Bool
    ) {
        var replacement = AttributedString(label)
        replacement[replacement.startIndex..<replacement.endIndex].link = url
        replaceBodyText(
            in: range,
            with: replacement,
            selecting: selectingLabel ? 0..<replacement.characters.count : nil
        )
    }

    // MARK: Image attachments

    /// Adds a tile for every picked photo immediately (decoding only enough for
    /// a thumbnail), then uploads them through the serial queue. The strip fills
    /// in instantly rather than waiting on the network.
    private func ingestPickedImages(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        imageSelections = []

        let capacity = maxImageSelection - imageAttachments.count
        guard capacity > 0 else { return }
        let accepted = items.prefix(capacity)
        if items.count > capacity {
            store.errorText = "一次最多添加 \(maxImageSelection) 张图片。"
        }

        for item in accepted {
            Task { await ingestPickedImage(item) }
        }
    }

    private func ingestPickedImage(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
            store.errorText = "无法读取所选图片。"
            return
        }
        guard let size = await ImageEditRenderer.pixelSize(of: data) else {
            store.errorText = "无法读取所选图片。"
            return
        }

        let type = item.supportedContentTypes.first { $0.conforms(to: .image) } ?? .jpeg
        let ext = type.preferredFilenameExtension ?? "jpg"
        let attachment = ComposeImageAttachment(
            originalData: data,
            pixelSize: size,
            fileName: "nodeloc-image-\(UUID().uuidString).\(ext)",
            mimeType: type.preferredMIMEType ?? "image/jpeg"
        )

        imageAttachments.append(attachment)
        await uploadImageAttachment(id: attachment.id)
    }

    /// Uploads whatever bytes the attachment currently represents — the original
    /// on first pass, the composited export after an edit.
    private func uploadImageAttachment(id: UUID) async {
        guard let index = imageAttachments.firstIndex(where: { $0.id == id }) else { return }
        let attachment = imageAttachments[index]
        let payload = attachment.uploadedData ?? attachment.originalData
        let previousURL = attachment.upload.composerURLString

        imageAttachments[index].upload = .uploading

        do {
            let upload = try await store.uploadMedia(
                data: payload,
                fileName: attachment.fileName,
                mimeType: attachment.mimeType
            )
            guard let url = upload.composerURLString else {
                throw ComposeUploadError.encodingFailed
            }
            // The attachment may have been deleted or re-edited mid-flight.
            guard let current = imageAttachments.firstIndex(where: { $0.id == id }) else { return }
            imageAttachments[current].upload = .ready(url)
        } catch {
            guard let current = imageAttachments.firstIndex(where: { $0.id == id }) else { return }
            // Keep the prior URL usable rather than blanking the post's markdown
            // because a re-upload failed.
            if let previousURL {
                imageAttachments[current].upload = .ready(previousURL)
                store.errorText = store.uploadFailureText(error)
            } else {
                imageAttachments[current].upload = .failed(store.uploadFailureText(error))
            }
        }
    }

    private func removeImageAttachment(_ id: UUID) {
        imageAttachments.removeAll { $0.id == id }
        ComposeThumbnailCache.shared.removeAll(forAttachment: id)
    }

    private func retryUpload(_ id: UUID) {
        Task { await uploadImageAttachment(id: id) }
    }

    /// Commits an edit from the editor: stores the new stack, swaps in the
    /// composited bytes, and re-uploads once.
    private func applyEdit(_ edits: ImageEditStack, exportedData: Data?, to id: UUID) {
        guard let index = imageAttachments.firstIndex(where: { $0.id == id }) else { return }

        imageAttachments[index].edits = edits
        imageAttachments[index].editsRevision += 1
        ComposeThumbnailCache.shared.removeAll(forAttachment: id)

        guard let exportedData else { return }
        imageAttachments[index].uploadedData = exportedData
        Task { await uploadImageAttachment(id: id) }
    }

    /// `fullScreenCover(item:)` needs an Identifiable payload, and the sheet has
    /// to read the *current* attachment so a re-open shows prior edits.
    private var editingAttachmentBinding: Binding<ComposeEditorTarget?> {
        Binding {
            guard let id = editingAttachmentID,
                  let attachment = imageAttachments.first(where: { $0.id == id })
            else { return nil }
            return ComposeEditorTarget(attachment: attachment)
        } set: { target in
            editingAttachmentID = target?.attachment.id
        }
    }

    // MARK: Video attachment

    /// Copies the picked video to a temp file, pulls a poster frame locally, and
    /// shows the tile before any network work starts.
    private func ingestPickedVideo(_ item: PhotosPickerItem?) {
        guard let item else { return }
        // A second pick while one is still decoding would orphan the first
        // temp file and race the mutual-exclusion flag.
        guard !isPreparingVideo, videoAttachment == nil else {
            videoSelection = nil
            return
        }

        isPreparingVideo = true
        Task {
            uploadingMediaKind = .video
            defer {
                uploadingMediaKind = nil
                isPreparingVideo = false
                videoSelection = nil
            }

            guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
                store.errorText = "无法读取所选视频。"
                return
            }

            let type = item.supportedContentTypes.first { $0.conforms(to: .movie) } ?? .quickTimeMovie
            let ext = type.preferredFilenameExtension ?? "mov"
            let localURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("nodeloc-video-\(UUID().uuidString)")
                .appendingPathExtension(ext)

            do {
                try data.write(to: localURL)
            } catch {
                store.errorText = "无法暂存所选视频。"
                return
            }

            guard let meta = await VideoExporter.metadata(for: localURL) else {
                VideoExporter.discard(localURL)
                store.errorText = "无法读取视频信息。"
                return
            }

            var attachment = ComposeVideoAttachment(
                sourceURL: localURL,
                pixelSize: meta.pixelSize,
                duration: meta.duration,
                fileName: "nodeloc-video-\(UUID().uuidString).\(ext)",
                mimeType: type.preferredMIMEType ?? "video/quicktime"
            )
            attachment.posterData = await VideoExporter.posterPNG(for: localURL)

            // The composer may have been closed during the decode.
            guard !isComposerClosing else {
                VideoExporter.discard(localURL)
                return
            }

            videoAttachment = attachment
            await uploadVideoAttachment()
        }
    }

    /// Uploads the video, then the poster named after the video's SHA1.
    private func uploadVideoAttachment() async {
        guard let attachment = videoAttachment else { return }
        let id = attachment.id
        videoAttachment?.upload = .uploading

        let payloadURL = attachment.uploadURL
        guard let data = try? Data(contentsOf: payloadURL, options: .mappedIfSafe) else {
            guard videoAttachment?.id == id else { return }
            videoAttachment?.upload = .failed("无法读取视频文件。")
            return
        }

        do {
            let upload = try await store.uploadMedia(
                data: data,
                fileName: attachment.fileName,
                mimeType: attachment.mimeType
            )
            guard let url = upload.composerURLString else {
                throw ComposeUploadError.encodingFailed
            }
            // The attachment may have been removed or replaced mid-flight.
            guard videoAttachment?.id == id else { return }
            videoAttachment?.upload = .ready(url)
            videoAttachment?.videoSHA1 = VideoExporter.sha1(fromUploadURL: upload.url)

            await uploadVideoPoster(id: id)
        } catch {
            guard videoAttachment?.id == id else { return }
            videoAttachment?.upload = .failed(store.uploadFailureText(error))
        }
    }

    /// Discourse pairs a poster to its video purely by filename, so this needs
    /// the video's SHA1 first. A failure here costs the post's thumbnail, not
    /// the video, so it never blocks posting — but it is recorded rather than
    /// swallowed, otherwise a missing thumbnail is undiagnosable.
    private func uploadVideoPoster(id: UUID) async {
        guard let attachment = videoAttachment, attachment.id == id else { return }

        guard let posterData = attachment.posterData else {
            videoAttachment?.posterUpload = .failed("没有可用的封面帧。")
            return
        }
        guard let sha1 = attachment.videoSHA1 else {
            // The upload URL wasn't the expected /uploads/.../<sha1>.<ext>
            // shape, so there's no filename that Discourse would match.
            videoAttachment?.posterUpload = .failed("无法从上传地址解析视频 SHA1，封面已跳过。")
            return
        }

        videoAttachment?.posterUpload = .uploading
        do {
            let upload = try await store.uploadVideoPoster(data: posterData, videoSHA1: sha1)
            guard videoAttachment?.id == id else { return }
            videoAttachment?.posterUpload = .ready(upload.composerURLString ?? "")
        } catch {
            guard videoAttachment?.id == id else { return }
            videoAttachment?.posterUpload = .failed(store.uploadFailureText(error))
        }
    }

    private func removeVideoAttachment() {
        guard let attachment = videoAttachment else { return }
        VideoExporter.discard(attachment.sourceURL)
        VideoExporter.discard(attachment.exportedURL)
        videoAttachment = nil
    }

    /// Commits a trim/GIF edit and re-uploads when the export produced a new file.
    private func applyVideoEdit(_ plan: VideoEditPlan, exportedURL: URL?, to id: UUID) {
        guard videoAttachment?.id == id else {
            VideoExporter.discard(exportedURL)
            return
        }

        videoAttachment?.plan = plan
        videoAttachment?.editsRevision += 1

        guard let exportedURL else { return }
        // Replace any earlier export so temp files don't pile up.
        VideoExporter.discard(videoAttachment?.exportedURL)
        videoAttachment?.exportedURL = exportedURL
        videoAttachment?.fileName = plan.asGIF
            ? "nodeloc-video-\(UUID().uuidString).gif"
            : "nodeloc-video-\(UUID().uuidString).mp4"
        videoAttachment?.mimeType = plan.asGIF ? "image/gif" : "video/mp4"

        Task {
            // The poster should reflect the new first frame after a trim.
            guard let source = videoAttachment?.sourceURL, videoAttachment?.id == id else {
                // Deleted while we were switching files — don't strand the export.
                VideoExporter.discard(exportedURL)
                return
            }
            let poster = await VideoExporter.posterPNG(for: source, at: plan.startSeconds)
            guard videoAttachment?.id == id else {
                VideoExporter.discard(exportedURL)
                return
            }
            videoAttachment?.posterData = poster
            await uploadVideoAttachment()
        }
    }

    /// Temp files live in NSTemporaryDirectory, which the system only reclaims
    /// under pressure. Videos are large, so the composer removes its own on the
    /// way out rather than leaving them for an eventual purge.
    private func cleanUpMediaTempFiles() {
        isComposerClosing = true
        VideoExporter.discard(videoAttachment?.sourceURL)
        VideoExporter.discard(videoAttachment?.exportedURL)
        videoAttachment = nil
    }

    private func insertAMATemplate() {
        let range = selectedBodyRange()
        let prefix = needsLeadingParagraphBreak(before: range.lowerBound) ? "\n\n" : ""
        let template = "\(prefix)AMA:\n\n可以问我：\n• "
        replaceBodyText(in: range, with: template, selecting: template.count..<template.count)
    }

    private func toggleBulletList() {
        let range = selectedBodyRange()
        if range.isEmpty && bodyText.characters.isEmpty {
            replaceBodyText(in: range, with: "• ")
            return
        }

        let lineRange = bodyLineRange(for: range)
        let lineText = String(bodyText.characters[lineRange])
        if range.isEmpty && lineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            replaceBodyText(in: range, with: "• ")
            return
        }

        let lines = lineText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let contentLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let shouldRemove = !contentLines.isEmpty && contentLines.allSatisfy { line in
            lineBody(afterIndentIn: line).hasPrefix("• ")
        }
        let replacement = lines
            .map { toggledBulletLine($0, removing: shouldRemove) }
            .joined(separator: "\n")

        replaceBodyText(in: lineRange, with: replacement, selecting: 0..<replacement.count)
    }

    /// Rewrites the selected lines' leading `#`s. Level 0 strips them, matching
    /// `applyHeading(0, …)` in the web toolbar.
    private func applyHeading(_ level: Int) {
        let lineRange = bodyLineRange(for: selectedBodyRange())
        let lineText = String(bodyText.characters[lineRange])
        let prefix = level > 0 ? String(repeating: "#", count: level) + " " : ""

        let replacement = lineText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let stripped = Self.strippingHeadingMarkers(from: String(line))
                return stripped.isEmpty ? stripped : prefix + stripped
            }
            .joined(separator: "\n")

        replaceBodyText(in: lineRange, with: replacement, selecting: 0..<replacement.count)
    }

    private static func strippingHeadingMarkers(from line: String) -> String {
        var body = Substring(line).drop { $0 == " " || $0 == "\t" }
        guard body.first == "#" else { return String(body) }
        body = body.drop { $0 == "#" }
        return String(body.drop { $0 == " " })
    }

    /// `> ` prefix per line, like the blockquote button's `applyList("> ", …)`.
    private func toggleBlockquote() {
        let lineRange = bodyLineRange(for: selectedBodyRange())
        let lineText = String(bodyText.characters[lineRange])
        let lines = lineText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let contentLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let shouldRemove = !contentLines.isEmpty && contentLines.allSatisfy {
            $0.drop { $0 == " " || $0 == "\t" }.hasPrefix(">")
        }

        let replacement = lines
            .map { line -> String in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                if shouldRemove {
                    let body = line.drop { $0 == " " || $0 == "\t" }
                    guard body.hasPrefix(">") else { return line }
                    return String(body.dropFirst().drop { $0 == " " })
                }
                return "> " + line
            }
            .joined(separator: "\n")

        replaceBodyText(in: lineRange, with: replacement, selecting: 0..<replacement.count)
    }

    /// `[spoiler]…[/spoiler]` from the spoiler-alert plugin. Block mode, so the
    /// tags sit on their own lines like the plugin's `useBlockMode: true`.
    private func wrapSpoiler() {
        wrapSelection(opening: "[spoiler]", closing: "[/spoiler]", placeholder: "剧透内容")
    }

    private func wrapSmallText() {
        wrapSelection(opening: "<small>", closing: "</small>", placeholder: "小号文字")
    }

    /// Surrounds the selection, or inserts a placeholder and selects it so the
    /// user can type over it immediately.
    private func wrapSelection(opening: String, closing: String, placeholder: String) {
        let range = selectedBodyRange()
        let selected = String(bodyText.characters[range])
        let content = selected.isEmpty ? placeholder : selected
        let replacement = opening + content + closing
        // Land the caret on the content, not the markup.
        let selectionStart = opening.count
        replaceBodyText(
            in: range,
            with: replacement,
            selecting: selectionStart..<(selectionStart + content.count)
        )
    }

    private func bodyLineRange(for range: Range<AttributedString.Index>) -> Range<AttributedString.Index> {
        let plain = String(bodyText.characters)
        guard !plain.isEmpty else { return range }

        let lowerOffset = bodyText.characters.distance(from: bodyText.startIndex, to: range.lowerBound)
        let upperOffset = bodyText.characters.distance(from: bodyText.startIndex, to: range.upperBound)
        let stringLower = plain.index(plain.startIndex, offsetBy: lowerOffset)
        let stringUpper = plain.index(plain.startIndex, offsetBy: upperOffset)
        let stringLineRange = plain.lineRange(for: stringLower..<stringUpper)
        let lineLowerOffset = plain.distance(from: plain.startIndex, to: stringLineRange.lowerBound)
        let lineUpperOffset = plain.distance(from: plain.startIndex, to: stringLineRange.upperBound)
        let lower = bodyText.index(bodyText.startIndex, offsetByCharacters: lineLowerOffset)
        let upper = bodyText.index(bodyText.startIndex, offsetByCharacters: lineUpperOffset)
        return lower..<upper
    }

    private func toggledBulletLine(_ line: String, removing: Bool) -> String {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
        let indentation = line.prefix { $0 == " " || $0 == "\t" }
        let body = lineBody(afterIndentIn: line)
        if removing {
            return body.hasPrefix("• ")
                ? String(indentation) + String(body.dropFirst(2))
                : line
        }
        if body.hasPrefix("• ") { return line }
        if body.hasPrefix("- ") || body.hasPrefix("* ") {
            return String(indentation) + "• " + String(body.dropFirst(2))
        }
        return String(indentation) + "• " + body
    }

    private func lineBody(afterIndentIn line: String) -> Substring {
        let bodyStart = line.firstIndex { $0 != " " && $0 != "\t" } ?? line.endIndex
        return line[bodyStart...]
    }

    private func needsLeadingParagraphBreak(before index: AttributedString.Index) -> Bool {
        let offset = bodyText.characters.distance(from: bodyText.startIndex, to: index)
        guard offset > 0 else { return false }
        let plain = String(bodyText.characters)
        let before = plain.index(plain.startIndex, offsetBy: offset - 1)
        return plain[before] != "\n"
    }

    private func normalizedURL(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") && !trimmed.hasPrefix("mailto:") {
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
        if url.scheme == "mailto" { return url }
        return url.host == nil ? nil : url
    }

    /// Images lead, then the prose, then any link/video attachments — matching
    /// the composer's own top-to-bottom layout. Only successfully uploaded
    /// images contribute, so a failed upload never emits a broken `![]()`.
    private func composedBodyMarkdown() -> String {
        // Images and video are mutually exclusive, so at most one of these is
        // non-empty.
        let imageMarkdown = imageAttachments
            .compactMap(\.markdown)
            .joined(separator: "\n\n")
        let videoMarkdown = videoAttachment?.markdown ?? ""
        let bodyMarkdown = RichTextMarkdownRenderer.markdown(from: bodyText, mediaKindsByURL: [:])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mediaMarkdown = mediaAttachments
            .map(\.markdown)
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A poll is plain markup carried by the post body; the red envelope is
        // not, and gets created in a second request after the topic exists.
        let pollMarkup = pollMarkupIfValid()

        return [imageMarkdown, videoMarkdown, bodyMarkdown, pollMarkup, mediaMarkdown]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func pollMarkupIfValid() -> String {
        guard let poll,
              poll.validationError(maximumOptions: store.pollMaximumOptions) == nil
        else { return "" }
        return poll.markup()
    }

    /// Media that failed to upload contributes no markdown, so posting now would
    /// silently drop it. Surfaced in the composer and blocks the post button.
    /// A failed *poster* doesn't count — the video still posts fine without one.
    private var failedUploadCount: Int {
        let images = imageAttachments.count {
            if case .failed = $0.upload { return true } else { return false }
        }
        let video: Int
        if case .failed = videoAttachment?.upload { video = 1 } else { video = 0 }
        return images + video
    }

    private func submit() {
        Task {
            let outcome = await store.submit(
                title: title,
                body: composedBodyMarkdown(),
                node: selectedCommunity,
                redEnvelope: redEnvelope,
                lottery: lottery
            )
            switch outcome {
            case .failed:
                break
            case .posted:
                closeOverlay(app)
            case .postedWithFollowUpFailure(let message):
                // The post is live and can't be rolled back — let the user
                // retry rather than dropping the extras silently.
                followUpRetryMessage = message
            }
        }
    }

    private func retryFollowUps() {
        followUpRetryMessage = nil
        Task {
            if await store.retryFollowUps(redEnvelope: redEnvelope, lottery: lottery) {
                closeOverlay(app)
            } else {
                followUpRetryMessage = store.errorText ?? "仍然创建失败。"
            }
        }
    }
}

// MARK: - Compose node picker

/// Full-page node chooser for the composer, mirroring the web plugin's picker:
/// recently posted-to nodes first, then joined nodes, then the rest.
private struct ComposeNodePicker: View {
    @Environment(\.dismiss) private var dismiss
    let store: ComposeStore
    @Binding var selection: SidebarNodeSummary?
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.isLoadingCommunities && store.nodeOptions.isEmpty {
                        loadingRow
                    }

                    ForEach(filteredOptions) { option in
                        nodeRow(option)
                    }

                    if !store.isLoadingCommunities && filteredOptions.isEmpty {
                        emptyRow
                    }
                }
                .padding(.bottom, 96)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Theme.bg.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            searchField
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
        .task { await store.loadCommunities() }
    }

    private var header: some View {
        ZStack {
            Text("发布至")
                .font(Theme.heading(17, weight: .semibold))
                .foregroundStyle(Theme.text)

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Theme.text)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)
        }
    }

    private func nodeRow(_ option: ComposeNodeOption) -> some View {
        let node = option.node

        return Button {
            selection = node
            dismiss()
        } label: {
            HStack(spacing: 12) {
                NodeSummaryIcon(node: node, size: 44, cornerRadius: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text("n/\(node.slug)")
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)

                    Text(subtitle(for: option))
                        .font(Theme.body(12, weight: .medium))
                        .foregroundStyle(Theme.muted(0.6))
                        .lineLimit(1)

                    if !node.description.isEmpty {
                        Text(node.description)
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.muted(0.62))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: 8)

                if selection?.id == node.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(for option: ComposeNodeOption) -> String {
        let members = option.node.memberCount.isEmpty ? "" : "\(option.node.memberCount) 成员"
        return [members, option.reasonText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var filteredOptions: [ComposeNodeOption] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return store.nodeOptions }
        return store.nodeOptions.filter { option in
            option.node.name.localizedCaseInsensitiveContains(term)
                || option.node.slug.localizedCaseInsensitiveContains(term)
                || option.node.description.localizedCaseInsensitiveContains(term)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.muted(0.56))
            TextField("搜索节点", text: $query)
                .font(Theme.body(15))
                .foregroundStyle(Theme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .glassBackground(in: Capsule(), tint: Theme.bg.opacity(0.36))
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Theme.accent)
            Text("正在加载节点")
                .font(Theme.body(14, weight: .medium))
                .foregroundStyle(Theme.muted(0.58))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var emptyRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
            Text("没有匹配的节点")
                .font(Theme.body(13))
            Spacer()
        }
        .foregroundStyle(Theme.muted(0.54))
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Sidebar

struct SidebarOverlay: View {
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    let panelWidth: CGFloat?
    @State private var store = SidebarStore()

    init(panelWidth: CGFloat? = nil) {
        self.panelWidth = panelWidth
    }

    var body: some View {
        GeometryReader { proxy in
            let panelWidth = panelWidth ?? min(proxy.size.width * 0.86, 330)

            sidebarPanel(
                width: panelWidth,
                topInset: proxy.safeAreaInsets.top,
                bottomInset: proxy.safeAreaInsets.bottom
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .task { await store.load(isSignedIn: isSignedIn) }
    }

    private func sidebarPanel(width: CGFloat, topInset: CGFloat, bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    topShortcuts

                    sidebarSection("推荐应用") {
                        appsSection
                    }

                    if isSignedIn {
                        sidebarSection("Custom Feed") {
                            customFeedsSection
                        }
                    }

                    sidebarSection("最近访问") {
                        recentNodesSection
                    }

                    sidebarSection("Resources") {
                        resourcesSection
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, topInset + 16)
                .padding(.bottom, bottomInset + 28)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(Theme.bg)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.divider)
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 28, x: 10, y: 0)
        .ignoresSafeArea(edges: .vertical)
    }

    private var topShortcuts: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(shortcutItems) { item in
                Button {
                    perform(item.action)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 24)
                        Text(item.title)
                            .font(Theme.body(14, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(item.isPrimary ? Theme.accent : Theme.text)
                    .padding(.horizontal, 11)
                    .frame(height: 46)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(item.isPrimary ? Theme.accent.opacity(0.34) : Theme.divider, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var appsSection: some View {
        VStack(spacing: 3) {
            ForEach(store.apps.prefix(5)) { item in
                sidebarImageRow(
                    title: item.name,
                    subtitle: "应用",
                    imageURL: item.logoURL,
                    fallbackIcon: "cube.fill",
                    tint: Theme.accent,
                    badge: nil
                ) {
                    perform(.openApp(item.slug))
                }
            }
            sidebarMenuRow(
                SidebarMenuItem(title: "浏览全部应用", subtitle: "Apps On NodeLoc", icon: "gamecontroller.fill", action: .browseApps)
            )
        }
    }

    private var customFeedsSection: some View {
        VStack(spacing: 3) {
            if store.customFeeds.isEmpty {
                emptySidebarRow("还没有 Custom Feed", icon: "rectangle.stack.badge.plus")
            } else {
                ForEach(store.customFeeds.prefix(6)) { feed in
                    sidebarColorRow(
                        title: feed.name,
                        subtitle: feed.description,
                        color: sidebarColor(feed.colorHex),
                        icon: "line.3.horizontal.decrease.circle.fill",
                        badge: feed.nodeCount.map { "\($0)" }
                    ) {
                        perform(.open(feed.url ?? "/custom-feeds"))
                    }
                }
            }

            sidebarMenuRow(
                SidebarMenuItem(title: "创建 Custom Feed", subtitle: "把多个节点组合成一个流", icon: "plus.circle.fill", action: .open("/custom-feeds"))
            )
        }
    }

    private var recentNodesSection: some View {
        VStack(spacing: 3) {
            ForEach(store.recentNodes.prefix(8)) { node in
                sidebarImageRow(
                    title: "n/\(node.slug)",
                    subtitle: node.name,
                    imageURL: node.logoURL,
                    fallbackIcon: "circle.grid.2x2.fill",
                    tint: sidebarColor(node.colorHex),
                    badge: node.isCreator ? "主理" : (node.memberCount.isEmpty ? nil : node.memberCount)
                ) {
                    perform(.open(node.url ?? "/n/\(node.slug)"))
                }
            }

            sidebarMenuRow(
                SidebarMenuItem(title: "浏览全部节点", subtitle: "Nodes", icon: "list.bullet", action: .browseNodes)
            )
        }
    }

    private var resourcesSection: some View {
        VStack(spacing: 3) {
            ForEach(store.resources) { resource in
                if resource.dividerAbove {
                    FadingRule()
                        .padding(.vertical, 0)
                }
                sidebarMenuRow(
                    SidebarMenuItem(title: resource.title, subtitle: resource.url, icon: mappedResourceIcon(resource.icon), action: .open(resource.url))
                )
            }
        }
    }

    private func sidebarSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(Theme.body(11, weight: .semibold))
                .foregroundStyle(Theme.muted(0.48))
                .textCase(.uppercase)
                .padding(.horizontal, 8)

            content()
        }
    }

    private func sidebarMenuRow(_ item: SidebarMenuItem) -> some View {
        Button {
            perform(item.action)
        } label: {
            HStack(spacing: 12) {
                iconShell(systemName: item.icon, tint: Theme.text.opacity(0.88))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(Theme.body(15, weight: item.isPrimary ? .semibold : .regular))
                        .foregroundStyle(Theme.text)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.muted(0.5))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let badge = item.badge {
                    Text(badge)
                        .font(Theme.body(10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.selected, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                item.isPrimary ? Theme.hover : Color.clear,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func sidebarImageRow(
        title: String,
        subtitle: String?,
        imageURL: URL?,
        fallbackIcon: String,
        tint: Color,
        badge: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 12) {
                sidebarIcon(imageURL: imageURL, fallbackIcon: fallbackIcon, tint: tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.body(15, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.muted(0.5))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let badge, !badge.isEmpty {
                    Text(badge)
                        .font(Theme.body(10, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.55))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func sidebarColorRow(
        title: String,
        subtitle: String?,
        color: Color,
        icon: String,
        badge: String?,
        action: @escaping () -> Void
    ) -> some View {
        sidebarImageRow(
            title: title,
            subtitle: subtitle,
            imageURL: nil,
            fallbackIcon: icon,
            tint: color,
            badge: badge,
            action: action
        )
    }

    private func emptySidebarRow(_ title: String, icon: String) -> some View {
        HStack(spacing: 12) {
            iconShell(systemName: icon, tint: Theme.muted(0.45))
            Text(title)
                .font(Theme.body(13))
                .foregroundStyle(Theme.muted(0.54))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private func sidebarIcon(imageURL: URL?, fallbackIcon: String, tint: Color) -> some View {
        Group {
            if let imageURL {
                CachedRemoteImage(url: imageURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Image(systemName: fallbackIcon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint)
                }
            } else {
                Image(systemName: fallbackIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 34, height: 34)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
    }

    private func iconShell(systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            }
    }

    private func perform(_ action: SidebarAction) {
        withAnimation(.easeInOut(duration: 0.2)) {
            switch action {
            case .home:
                app.tab = .home
                app.overlay = nil
            case .hot:
                openSitePath("/top")
            case .browseNodes:
                app.overlay = .browseNodes
            case .createNode:
                app.overlay = .createNode
            case .open(let path):
                openSitePath(path)
            case .search:
                app.tab = .search
                app.overlay = nil
            case .browseApps:
                app.overlay = .appsDirectory
            case .openApp(let slug):
                openApp(slug: slug)
            }
        }
    }

    /// The sidebar row only carries a slug, so the app is fetched before the
    /// detail page opens.
    private func openApp(slug: String) {
        app.overlay = .appsDirectory
        Task {
            guard let fetched = try? await DiscourseClient().app(slug: slug).directoryApp else { return }
            app.selectedApp = fetched
            withAnimation(.easeInOut(duration: 0.2)) {
                app.overlay = .appDetail
            }
        }
    }

    private var isSignedIn: Bool {
        app.authed || DiscourseAuth.shared.isAuthenticated
    }

    private var shortcutItems: [SidebarMenuItem] {
        [
            SidebarMenuItem(title: "首页", subtitle: nil, icon: "house.fill", isPrimary: app.tab == .home, action: .home),
            SidebarMenuItem(title: "热门", subtitle: nil, icon: "flame.fill", action: .hot),
            SidebarMenuItem(title: "浏览节点", subtitle: nil, icon: "square.grid.2x2.fill", action: .browseNodes),
            SidebarMenuItem(title: "创建节点", subtitle: nil, icon: "plus.circle.fill", isPrimary: store.canCreateNode, action: .createNode)
        ]
    }

    private func openSitePath(_ path: String) {
        guard let url = nodelocSiteURL(path) else { return }
        openURL(url)
        app.overlay = nil
    }

    private func sidebarColor(_ hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let value = UInt32(cleaned, radix: 16) else { return Theme.accent }
        return Color(hex: value)
    }

    private func mappedResourceIcon(_ icon: String) -> String {
        switch icon {
        case "circle-info": return "info.circle"
        case "circle-question": return "questionmark.circle"
        case "file-lines": return "doc.text"
        case "shield-halved": return "shield"
        case "right-to-bracket": return "key"
        case "wallet": return "wallet.pass"
        case "rectangle-ad": return "megaphone"
        case "circle-check": return "checkmark.seal"
        case "heart": return "heart"
        case "handshake": return "hands.sparkles"
        default: return icon
        }
    }
}

private struct SidebarMenuItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let icon: String
    var isPrimary: Bool = false
    var badge: String? = nil
    let action: SidebarAction
}

private enum SidebarAction {
    case home
    case hot
    case browseNodes
    case createNode
    case open(String)
    case search
    /// Opens the native app directory instead of the web category.
    case browseApps
    /// Opens one app's detail page by slug.
    case openApp(String)
}

// MARK: - Browse nodes

struct BrowseNodesOverlay: View {
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var store = NodeBrowseStore()
    @State private var query = ""
    @State private var showsSearch = false
    @State private var showsGroupList = false
    @State private var selectedNode: SidebarNodeSummary?
    let showsCloseButton: Bool
    private let headerIconFrame: CGFloat = 34
    private let headerContentHeight: CGFloat = 56

    init(showsCloseButton: Bool = true) {
        self.showsCloseButton = showsCloseButton
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: headerContentHeight)

                        if showsGroupList {
                            groupListContent
                        } else {
                            VStack(alignment: .leading, spacing: 28) {
                                topicChipsSection

                                if store.isLoading {
                                    loadingRow("正在加载节点")
                                }

                                categoryPreviewSections

                                if let errorText = store.errorText {
                                    Text(errorText)
                                        .font(Theme.body(13, weight: .medium))
                                        .foregroundStyle(Theme.danger)
                                        .padding(.horizontal, 16)
                                }
                            }
                            .padding(.top, 18)
                            .padding(.bottom, 110)
                        }
                    }
                }
                .scrollIndicators(.hidden)

                browseHeader()
                    .zIndex(1)

                if let selectedNode {
                    NodeDetailOverlay(node: selectedNode) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                            self.selectedNode = nil
                        }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(20)
                }
            }
            .background(Theme.bg.ignoresSafeArea())
        }
        .task { await store.load() }
    }

    private func browseHeader() -> some View {
        ZStack {
            Text(headerTitle)
                .font(Theme.heading(20, weight: .semibold))
                .foregroundStyle(Theme.text)

            HStack {
                if showsCloseButton || showsGroupList {
                    Button { handleBack() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .frame(width: headerIconFrame, height: headerIconFrame)
                    }
                    .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
                    .buttonBorderShape(.circle)
                    .shadow(color: .black.opacity(0.08), radius: 9, y: 6)
                } else {
                    // Root of the nodes tab: no back destination, so the slot
                    // holds the sidebar toggle like the home feed does.
                    SidebarMenuButton()
                }

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                        app.overlay = .createNode
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: headerIconFrame, height: headerIconFrame)
                }
                .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
                .buttonBorderShape(.circle)
                .shadow(color: .black.opacity(0.08), radius: 9, y: 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background {
            Rectangle()
                .fill(Theme.bg.opacity(0.3))
                .ignoresSafeArea(edges: .top)
        }
    }

    private var headerTitle: String {
        showsGroupList ? (store.selectedGroup?.name ?? "节点") : "节点"
    }

    private func handleBack() {
        if showsGroupList {
            withAnimation(.easeInOut(duration: 0.2)) {
                showsGroupList = false
            }
        } else {
            closeOverlay(app)
        }
    }

    private var topicChipsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("按主题浏览节点")
                .font(Theme.heading(17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 16)

            ScrollView(.horizontal) {
                LazyHGrid(
                    rows: Array(repeating: GridItem(.fixed(36), spacing: 11), count: 3),
                    alignment: .top,
                    spacing: 10
                ) {
                    if store.groups.isEmpty {
                        ForEach(fallbackTopicLabels, id: \.self) { label in
                            topicChip(title: label, isSelected: false) {}
                                .disabled(true)
                        }
                    } else {
                        ForEach(store.groups) { group in
                            topicChip(title: group.name, isSelected: store.selectedGroup?.id == group.id) {
                                openGroup(group)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .frame(height: 130)
        }
    }

    private var groupListContent: some View {
        VStack(spacing: 10) {
            if store.isLoadingGroup {
                loadingRow("正在加载 \(store.selectedGroup?.name ?? "节点")")
            }

            ForEach(Array(store.groupNodes.enumerated()), id: \.element.id) { index, node in
                rankedCommunityCard(node, rank: index + 1)
            }

            if !store.isLoadingGroup && store.groupNodes.isEmpty {
                emptyRow("这里还没有可浏览的节点", icon: "tray")
                    .padding(.horizontal, 16)
            }

            if let errorText = store.errorText {
                Text(errorText)
                    .font(Theme.body(13, weight: .medium))
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 110)
    }

    @ViewBuilder
    private var categoryPreviewSections: some View {
        if previewGroups.isEmpty {
            recommendedSection
        } else {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(previewGroups) { group in
                    categoryPreviewSection(group)
                }
            }
        }
    }

    private var previewGroups: [NodeGroupSummary] {
        Array(store.groups.prefix(6))
    }

    private func categoryPreviewSection(_ group: NodeGroupSummary) -> some View {
        let nodes = store.previewNodes(for: group)

        return VStack(alignment: .leading, spacing: 14) {
            Button {
                openGroup(group)
            } label: {
                HStack {
                    Text(group.name)
                        .font(Theme.heading(20, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer()
                    Text("更多")
                        .font(Theme.body(13, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.58))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.text)
                }
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)

            if nodes.isEmpty, store.isLoading {
                loadingRow("正在加载 \(group.name)")
            } else if nodes.isEmpty {
                emptyRow("暂无节点", icon: "tray")
                    .padding(.horizontal, 16)
            } else {
                horizontalCommunityCards(nodes: nodes)
            }
        }
    }

    private var recommendedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("为你推荐")
                .font(Theme.heading(17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 16)

            horizontalCommunityCards(nodes: Array(store.recommended.prefix(8)))
        }
    }

    @ViewBuilder
    private var relatedSection: some View {
        let nodes = relatedNodes
        if !nodes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(relatedTitle)
                        .font(Theme.heading(20, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.text)
                }
                .padding(.horizontal, 16)

                horizontalCommunityCards(nodes: nodes)
            }
        }
    }

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("搜索结果")
                .font(Theme.heading(20, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 16)

            VStack(spacing: 10) {
                ForEach(searchResults) { node in
                    wideCommunityCard(node)
                }
                if searchResults.isEmpty {
                    emptyRow("没有匹配的节点", icon: "magnifyingglass")
                        .padding(.horizontal, 16)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.muted(0.56))
            TextField("搜索节点", text: $query)
                .font(Theme.body(16))
                .foregroundStyle(Theme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .glassBackground(in: Capsule(), tint: Theme.bg.opacity(0.36))
        .padding(.horizontal, 16)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchResults: [SidebarNodeSummary] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let previewNodes = store.groupPreviews.values.flatMap { $0 }
        let allNodes = store.recommended + store.groupNodes + previewNodes
        var seen = Set<Int>()
        return allNodes.filter { node in
            guard seen.insert(node.id).inserted else { return false }
            return node.name.localizedCaseInsensitiveContains(term)
                || node.slug.localizedCaseInsensitiveContains(term)
                || node.description.localizedCaseInsensitiveContains(term)
        }
    }

    private var relatedNodes: [SidebarNodeSummary] {
        if !store.groupNodes.isEmpty { return Array(store.groupNodes.prefix(8)) }
        return Array(store.recommended.dropFirst(2).prefix(6))
    }

    private var relatedTitle: String {
        if let selectedGroup = store.selectedGroup {
            return "更多 \(selectedGroup.name) 类似内容"
        }
        return "更多类似内容"
    }

    private func openGroup(_ group: NodeGroupSummary) {
        withAnimation(.easeInOut(duration: 0.2)) {
            showsGroupList = true
        }
        Task { await store.loadGroup(group) }
    }

    private var fallbackTopicLabels: [String] {
        [
            "互联网文化", "游戏", "问答与故事", "影视", "科技", "食物",
            "胜地与旅行", "流行文化", "体育", "商业与金融", "人文与艺术",
            "教育与职业", "时尚与美容", "新闻与政治", "交通工具"
        ]
    }

    private func topicChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.body(13, weight: .medium))
                .foregroundStyle(isSelected ? Theme.bg : Theme.text)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(isSelected ? Theme.text : Theme.bg, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(isSelected ? Theme.text.opacity(0.18) : Theme.divider, lineWidth: 1.2)
                }
        }
        .buttonStyle(.plain)
    }

    private func horizontalCommunityCards(nodes: [SidebarNodeSummary]) -> some View {
        GeometryReader { proxy in
            let cardWidth = max(286, min(360, proxy.size.width - 70))

            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(nodePairs(from: nodes)) { pair in
                        communityCard(pair, width: cardWidth)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
        .frame(height: 272)
    }

    private func nodePairs(from nodes: [SidebarNodeSummary]) -> [NodeCardPair] {
        stride(from: 0, to: nodes.count, by: 2).map { index in
            NodeCardPair(
                first: nodes[index],
                second: index + 1 < nodes.count ? nodes[index + 1] : nil
            )
        }
    }

    private func communityCard(_ pair: NodeCardPair, width: CGFloat) -> some View {
        VStack(spacing: 14) {
            compactCommunityCard(pair.first, width: width)
            if let second = pair.second {
                compactCommunityCard(second, width: width)
            } else {
                Spacer(minLength: 0)
                    .frame(height: 120)
            }
        }
        .frame(width: width, height: 254, alignment: .top)
    }

    private func compactCommunityCard(_ node: SidebarNodeSummary, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                NodeSummaryIcon(node: node, size: 44, cornerRadius: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName(for: node))
                        .font(Theme.heading(15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(memberText(for: node))
                        .font(Theme.body(12, weight: .medium))
                        .foregroundStyle(Theme.muted(0.62))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                joinButton(for: node)
            }

            Text(node.description)
                .font(Theme.body(12))
                .foregroundStyle(Theme.muted(0.62))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(width: width, height: 120, alignment: .top)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1.2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { openNode(node) }
    }

    private func wideCommunityCard(_ node: SidebarNodeSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                NodeSummaryIcon(node: node, size: 44, cornerRadius: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName(for: node))
                        .font(Theme.heading(15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(memberText(for: node))
                        .font(Theme.body(12, weight: .medium))
                        .foregroundStyle(Theme.muted(0.62))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                joinButton(for: node)
            }

            Text(node.description)
                .font(Theme.body(12))
                .foregroundStyle(Theme.muted(0.62))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1.2)
        }
        .padding(.horizontal, 16)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { openNode(node) }
    }

    private func rankedCommunityCard(_ node: SidebarNodeSummary, rank: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(rank)")
                .font(Theme.body(15, weight: .semibold))
                .foregroundStyle(Theme.muted(0.62))
                .monospacedDigit()
                .frame(width: 34, height: 44, alignment: .center)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    NodeSummaryIcon(node: node, size: 44, cornerRadius: 22)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName(for: node))
                            .font(Theme.heading(15, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Text(memberText(for: node))
                            .font(Theme.body(12, weight: .medium))
                            .foregroundStyle(Theme.muted(0.62))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    joinButton(for: node)
                }

                Text(node.description)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.muted(0.62))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1.2)
        }
        .padding(.horizontal, 16)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { openNode(node) }
    }

    /// 加入 is a filled call to action; 已加入 is a quiet outline. Same shape,
    /// different weight — the joined state is a status, not an invitation to
    /// tap again.
    private func joinButton(for node: SidebarNodeSummary) -> some View {
        Button {
            openNode(node)
        } label: {
            Text(node.isJoined ? "已加入" : "加入")
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(node.isJoined ? Theme.muted(0.62) : Theme.bg)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(node.isJoined ? Theme.surface : Theme.text, in: Capsule())
                .overlay {
                    if node.isJoined {
                        Capsule().strokeBorder(Theme.divider, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func memberText(for node: SidebarNodeSummary) -> String {
        node.memberCount.isEmpty ? "成员" : "\(node.memberCount) 成员"
    }

    private func displayName(for node: SidebarNodeSummary) -> String {
        node.name.isEmpty ? node.slug : node.name
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(Theme.accent)
            Text(text)
                .font(Theme.body(15, weight: .medium))
                .foregroundStyle(Theme.muted(0.58))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func emptyRow(_ text: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
            Text(text)
                .font(Theme.body(13))
            Spacer()
        }
        .foregroundStyle(Theme.muted(0.54))
        .padding(.vertical, 12)
    }

    private func openNode(_ node: SidebarNodeSummary) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            selectedNode = node
        }
    }
}

// MARK: - Node detail

/// A single node: banner header, membership, and its topic list in one of three
/// reading modes (compact / expand / card).
struct NodeDetailOverlay: View {
    @Environment(AppState.self) private var app
    let node: SidebarNodeSummary
    let onClose: () -> Void

    @State private var store = NodeDetailStore()
    /// Shared and persisted, so the choice survives leaving the node and relaunching.
    private let readingMode = NodeReadingModeStore.shared
    @State private var descriptionExpanded = false
    @State private var showSortPicker = false
    @State private var showAbout = false
    @State private var scrollOffset: CGFloat = 0
    /// Media opened straight from a card, without entering the post.
    @State private var viewerImages: [PostImage] = []
    @State private var viewerIndex = 0
    @State private var viewerVideo: PostVideo?
    /// The post whose media is open, for the viewer's chrome and actions.
    @State private var viewerMediaPost: Post?

    private let headerControlHeight: CGFloat = 34
    /// Extends below the floating buttons; the safe-area inset is added on top.
    private let bannerHeight: CGFloat = 78
    /// Anchor for the scroll-to-top the node capsule performs.
    private let topAnchor = "node-top"

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                // Everything scrolls together: banner, node info, sort bar, list.
                ScrollView {
                    VStack(spacing: 0) {
                        banner
                            .id(topAnchor)
                        nodeSummary
                        modeBar
                        topicList
                            .padding(.bottom, 40)
                    }
                    // Root of the width chain. Without this the VStack sizes to its
                    // widest descendant and the ScrollView adopts that, so a single
                    // long title or description shifts the entire page sideways.
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .refreshable { await store.refresh() }
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    max(0, geo.contentOffset.y)
                } action: { _, newValue in
                    scrollOffset = newValue
                }

                // Floating chrome, kept clear of the status bar. The banner still
                // bleeds up behind it via its own safe-area padding.
                floatingHeader(scrollProxy: proxy)
                    .padding(.top, topSafeAreaInset)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .zIndex(10)
            }
        }
        .background(Theme.bg)
        .ignoresSafeArea(edges: .top)
        .task(id: node.id) { await store.load(node: node) }
        .sheet(isPresented: $showSortPicker) { sortSheet }
        .sheet(isPresented: $showAbout) { aboutSheet }
        // Card media opens its viewer here, over the list, so closing returns
        // to the same scroll position rather than to a post.
        // Both viewers get the same chrome; the node is already known here.
        .postImageFullScreen(
            images: $viewerImages,
            selection: $viewerIndex,
            presentation: viewerMediaPost.map { PostVideoPresentation(post: $0, node: node) },
            onComment: { if let post = viewerMediaPost { open(post) } }
        )
        .postVideoFullScreen(
            video: $viewerVideo,
            presentation: viewerMediaPost.map { PostVideoPresentation(post: $0, node: node) },
            onComment: { if let post = viewerMediaPost { open(post) } }
        )
    }

    /// Opens a card's media directly — video full screen, images in the viewer.
    private func openMedia(for post: Post) {
        viewerMediaPost = post
        if let videoURL = post.videoURL {
            viewerVideo = PostVideo(src: videoURL.absoluteString, posterSrc: post.imageURL?.absoluteString)
            return
        }
        let images = post.media.map {
            PostImage(src: $0.url.absoluteString, width: $0.width, height: $0.height)
        }
        guard !images.isEmpty else {
            // No media to show; fall back to opening the topic.
            open(post)
            return
        }
        viewerImages = images
        viewerIndex = 0
    }

    /// Sort picker, presented like Reddit's "帖子排序依据" sheet.
    private var sortSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ForEach(store.availableSorts) { option in
                    Button {
                        showSortPicker = false
                        Task { await store.select(sort: option) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: option.icon)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(store.sort == option ? Theme.accent : Theme.muted(0.55))
                                .frame(width: 26)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .font(Theme.body(15, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                Text(option.detail)
                                    .font(Theme.body(11))
                                    .foregroundStyle(Theme.muted(0.5))
                            }

                            Spacer(minLength: 0)

                            if store.sort == option {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(store.sort == option ? Theme.accent.opacity(0.07) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .background(Theme.bg)
            .navigationTitle("话题排序依据")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    /// Mirrors the web plugin's about panel: identity, description, the three
    /// counts, and the moderator list.
    private var aboutSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        NodeAvatar(node: node, size: 52, cornerRadius: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("n/\(store.slug)")
                                .font(Theme.body(13))
                                .foregroundStyle(Theme.muted(0.58))
                            Text(store.name)
                                .font(Theme.heading(18, weight: .bold))
                                .foregroundStyle(Theme.text)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !store.descriptionText.isEmpty {
                        Text(store.descriptionText)
                            .font(Theme.body(14))
                            .foregroundStyle(Theme.text.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 0) {
                        aboutStat(store.memberCount, "成员")
                        aboutStat(store.topicCount, "主题")
                        aboutStat(store.postCount, "帖子")
                    }

                    if !store.moderators.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("版主")
                                .font(Theme.body(13, weight: .semibold))
                                .foregroundStyle(Theme.muted(0.6))

                            ForEach(store.moderators) { moderator in
                                HStack(spacing: 10) {
                                    RemoteAvatar(
                                        url: moderator.avatarTemplate
                                            .flatMap { DiscourseClient().avatarURL(template: $0, size: 96) },
                                        letter: String(moderator.username.prefix(1)).uppercased(),
                                        variant: abs(moderator.username.hashValue),
                                        size: 34
                                    )
                                    VStack(alignment: .leading, spacing: 1) {
                                        if let name = moderator.name, !name.isEmpty {
                                            Text(name)
                                                .font(Theme.body(14, weight: .semibold))
                                                .foregroundStyle(Theme.text)
                                        }
                                        Text("u/\(moderator.username)")
                                            .font(Theme.body(12))
                                            .foregroundStyle(Theme.muted(0.55))
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.bg)
            .navigationTitle("关于节点")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func aboutStat(_ value: Int?, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value.map(Self.groupedCount) ?? "—")
                .font(Theme.heading(17, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(label)
                .font(Theme.body(12))
                .foregroundStyle(Theme.muted(0.55))
        }
        .frame(maxWidth: .infinity)
    }

    private static func groupedCount(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    // MARK: Header chrome

    /// 0 → 1 as the node header scrolls away, revealing the inline node pill.
    private var titleRevealProgress: CGFloat {
        min(max((scrollOffset - 50) / 70, 0), 1)
    }

    private func floatingHeader(scrollProxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            glassButton(borderShape: .circle, action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.headerText)
                    .frame(width: headerControlHeight, height: headerControlHeight)
            }

            // Node identity, revealed once the header has scrolled past. Tapping
            // returns to the top, the same gesture as the profile capsule.
            glassButton(borderShape: .capsule) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    scrollProxy.scrollTo(topAnchor, anchor: .top)
                }
            } label: {
                HStack(spacing: 6) {
                    NodeAvatar(node: node, size: 22, cornerRadius: 11)
                    Text("n/\(store.slug)")
                        .font(Theme.body(12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        // Long slugs shrink rather than widen the capsule: the
                        // row has ~74pt of slack on a 393pt screen and none on
                        // an SE, so growing here would clip the back button.
                        .minimumScaleFactor(0.75)
                }
                .padding(.leading, 6)
                .padding(.trailing, 12)
                .frame(height: headerControlHeight)
            }
            // Claims its intrinsic width before the Spacer takes the rest;
            // without this the slug collapses to "n..." even with room to spare.
            .layoutPriority(1)
            // Only tappable once nearly opaque, matching the profile capsule, so
            // a faint capsule can't swallow taps meant for what's underneath.
            .allowsHitTesting(titleRevealProgress > 0.9)
            .opacity(titleRevealProgress)
            .accessibilityLabel("回到顶部")

            // All the slack sits between the pill and the tools, so the pill
            // stays next to the back button instead of floating in the centre.
            Spacer(minLength: 8)

            headerTools
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// 新建 / 搜索 / 更多 in one glass capsule.
    ///
    /// The glass goes on the capsule with `.interactive()`, which is what gives
    /// the press response. The previous version layered `.plain` buttons over a
    /// capsule marked `allowsHitTesting(false)`, so neither the capsule nor the
    /// buttons could ever react — that inert glass layer was the bug.
    ///
    /// Three icons, not four: measured in a real host the row needs 319pt with
    /// three, against 320pt of usable width on an SE. 分享 lives in the menu.
    private var headerTools: some View {
        HStack(spacing: 6) {
            Button(action: startCompose) { toolIcon("plus") }
                .buttonStyle(.plain)
                .accessibilityLabel("在本节点发帖")

            Button(action: startNodeSearch) { toolIcon("magnifyingglass") }
                .buttonStyle(.plain)
                .accessibilityLabel("在本节点内搜索")

            Menu {
                nodeMenuContent
            } label: {
                toolIcon("ellipsis")
            }
            .accessibilityLabel("更多")
        }
        .padding(.horizontal, 8)
        // Matches the node pill exactly: `.buttonStyle(.glass)` adds 7pt above
        // and below its 34pt label for a 48pt capsule, so this reproduces that
        // padding rather than pinning a height that would drift if the shared
        // control height changes.
        .padding(.vertical, 7)
        .glassEffect(
            .regular.tint(Theme.bg.opacity(0.34)).interactive(),
            in: .capsule
        )
        .shadow(color: .black.opacity(0.08), radius: 9, y: 6)
    }

    /// A tap target inside the shared capsule. Narrower than the control height
    /// so three of them plus the node pill still fit on a small phone.
    private func toolIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.text)
            .frame(width: 28, height: headerControlHeight)
            .contentShape(Rectangle())
    }

    /// The node's public page, for sharing.
    private var nodeShareURL: URL {
        DiscourseConfig.baseURL.appending(path: "n/\(store.slug.isEmpty ? node.slug : store.slug)")
    }

    @ViewBuilder
    private var nodeMenuContent: some View {
        Button {
            showAbout = true
        } label: {
            Label("关于本节点", systemImage: "info.circle")
        }

        ShareLink(item: nodeShareURL) {
            Label("分享", systemImage: "square.and.arrow.up")
        }

        // The level the server reports is only this user's when signed in;
        // anonymously it's the site default, so offering it would be a lie.
        if DiscourseAuth.shared.isAuthenticated {
            Divider()

            Menu {
                Picker("通知级别", selection: Binding(
                    get: { store.notificationLevel },
                    set: { level in Task { await store.setNotificationLevel(level) } }
                )) {
                    ForEach(NodeNotificationLevel.menuOrder) { level in
                        Label(level.label, systemImage: level.icon).tag(level)
                    }
                }
            } label: {
                Label("通知级别", systemImage: store.notificationLevel.icon)
            }
        }
    }

    /// Opens the composer with this node already chosen.
    private func startCompose() {
        app.composePreselectedNode = node
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            app.overlay = .compose
        }
    }

    /// Opens search scoped to this node. `#slug` is Discourse's own category
    /// filter; the trailing space leaves the caret ready for the search terms.
    private func startNodeSearch() {
        let slug = store.slug.isEmpty ? node.slug : store.slug
        app.searchInitialQuery = "#\(slug) "
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            app.overlay = .search
        }
    }

    /// Inline 加入 button, sitting on the name row like Reddit's.
    private var joinButton: some View {
        Button {
            Task { await store.toggleJoin() }
        } label: {
            HStack(spacing: 4) {
                if store.isTogglingJoin {
                    ProgressView().controlSize(.mini).tint(store.isJoined ? Theme.text : .white)
                } else if !store.isJoined {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                }
                Text(store.isJoined ? "已加入" : "加入")
                    .font(Theme.body(13, weight: .semibold))
            }
            .foregroundStyle(store.isJoined ? Theme.text : .white)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(store.isJoined ? Theme.surface : Theme.text, in: Capsule())
            .overlay {
                if store.isJoined {
                    Capsule().strokeBorder(Theme.divider, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(store.isTogglingJoin)
    }

    private func glassButton<Label: View>(
        borderShape: ButtonBorderShape,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label().frame(height: headerControlHeight)
        }
        .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
        .buttonBorderShape(borderShape)
        .shadow(color: .black.opacity(0.08), radius: 9, y: 6)
    }

    // MARK: Banner + summary

    @ViewBuilder
    private var banner: some View {
        // Runs to the very top, behind the status bar and floating buttons.
        let height = bannerHeight + topSafeAreaInset
        return Group {
            if let backgroundURL = store.backgroundURL {
                CachedRemoteImage(url: backgroundURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    bannerFallback
                }
            } else {
                bannerFallback
            }
        }
        // `filledBanner` sizes an empty box first and hangs the image in an
        // overlay. Applying `.scaledToFill()` directly and then clipping does
        // NOT contain it: fill scales to cover the height, so a wide image
        // reports a frame far wider than the screen and the ScrollView adopts
        // that — clipping only trims the drawing, not the frame.
        .filledBanner(height: height, clip: Rectangle())
    }

    private var bannerFallback: some View {
        LinearGradient(
            colors: [nodeAccentColor(store.colorHex).opacity(0.55), nodeAccentColor(store.colorHex).opacity(0.18)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .frame(maxWidth: .infinity)
    }

    /// Reddit-style: logo + name + 加入 on one row, stats underneath, then the
    /// description with an expand toggle.
    private var nodeSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                NodeAvatar(node: node, size: 52, cornerRadius: 26)
                    .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 3))

                VStack(alignment: .leading, spacing: 2) {
                    Text("n/\(store.slug)")
                        .font(Theme.heading(19, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(statsText)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.58))
                        .lineLimit(1)
                }
                // Yields width to the avatar and join button rather than
                // reporting the slug's intrinsic size.
                .frame(maxWidth: .infinity, alignment: .leading)

                joinButton
            }

            if !store.descriptionText.isEmpty {
                Text(store.descriptionText)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.text.opacity(0.8))
                    .lineLimit(descriptionExpanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    // Measured 455pt unbounded on a 393pt screen for
                    // n/chit-chat: without a width budget it drags the whole
                    // page sideways.
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { descriptionExpanded.toggle() }
                } label: {
                    Text(descriptionExpanded ? "收起" : "查看更多内容")
                        .font(Theme.body(13, weight: .semibold))
                        .foregroundStyle(Color(light: 0x2F6DF6, dark: 0x7EA7FF))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// "每周 47 千位访客 · 758 个贡献" style line under the name.
    private var statsText: String {
        var parts: [String] = []
        if let members = store.memberCount { parts.append("\(compact(members)) 位成员") }
        if let topics = store.topicCount { parts.append("\(compact(topics)) 主题") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1000 { return String(format: "%.1fk", Double(value) / 1000) }
        return "\(value)"
    }

    // MARK: Reading mode bar

    private var modeBar: some View {
        HStack(spacing: 10) {
            Button { showSortPicker = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: store.sort.icon)
                        .font(.system(size: 12, weight: .semibold))
                    Text(store.sort.label)
                        .font(Theme.body(13, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.5))
                }
                .foregroundStyle(Theme.text)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Menu {
                // Writes go through the store rather than straight to a
                // @State, so the choice is persisted for next launch.
                Picker("阅读模式", selection: Binding(
                    get: { readingMode.mode },
                    set: { readingMode.select($0) }
                )) {
                    ForEach(NodeReadingMode.allCases) { option in
                        Label(option.label, systemImage: option.icon).tag(option)
                    }
                }
            } label: {
                Image(systemName: readingMode.mode.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    // MARK: Topics

    @ViewBuilder
    private var topicList: some View {
        if store.isLoading && store.posts.isEmpty {
            NodelocLoader(progress: nil)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
        } else if store.posts.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.35))
                Text(store.errorText ?? "还没有主题")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.muted(0.5))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 52)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(store.posts) { post in
                    NodeTopicRow(
                        post: post,
                        mode: readingMode.mode,
                        onTap: { open(post) },
                        onMediaTap: { openMedia(for: post) }
                    )
                }

                if store.isLoadingMore {
                    ProgressView().tint(Theme.accent).padding(.vertical, 20)
                } else {
                    Color.clear
                        .frame(height: 1)
                        .onAppear { Task { await store.loadMore() } }
                }
            }
            // A LazyVStack sizes to its widest child, and the ScrollView then
            // adopts that. Bounding the stack itself gives every row a real
            // width to lay out within, instead of each row's content deciding.
            .frame(maxWidth: .infinity)
        }
    }

    private func open(_ post: Post) {
        app.selectedPost = post
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            app.overlay = .post
        }
    }

    private var topSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }
            .first ?? 47
    }
}

/// Node logo, falling back to a colored initial.
/// One topic, rendered per reading mode.
private struct NodeTopicRow: View {
    let post: Post
    let mode: NodeReadingMode
    let onTap: () -> Void
    /// Card mode only: media opens straight into its own viewer, skipping the
    /// post. Nil elsewhere, where a tap anywhere should open the topic.
    var onMediaTap: (() -> Void)?

    /// Measured, not assumed — the card's own width, minus its padding.
    @State private var mediaWidth: CGFloat = 0

    /// Card media takes the image's own shape, clamped 16:9 … 4:5.
    private var cardMediaHeight: CGFloat {
        let first = post.media.first
        return Theme.FeedMedia.height(
            forWidth: max(mediaWidth, 1),
            mediaWidth: first?.width,
            mediaHeight: first?.height
        )
    }

    var body: some View {
        Group {
            switch mode {
            case .compact, .expand:
                Button(action: onTap) {
                    if mode == .compact { compactRow } else { expandRow }
                }
                .buttonStyle(.plain)

            case .card:
                // Not a Button: the media inside needs its own tap target, and a
                // nested Button inside a Button doesn't reliably take precedence.
                // A tap gesture on the container plus one on the media does.
                cardRow
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
            }
        }
        // Backstop for the whole row. A ScrollView adopts its widest child as
        // the content width, so one row that reports an oversized minimum drags
        // every sibling out with it.
        .clampedToWidth()
    }

    /// Discourse-mobile style: one dense line per topic with a reply count.
    private var compactRow: some View {
        HStack(spacing: 10) {
            RemoteAvatar(url: post.avatarURL, letter: post.avatarLetter, variant: post.variant, size: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(post.title)
                    .font(Theme.body(14, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    Text(post.node)
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.muted(0.5))
                    Text("·").foregroundStyle(Theme.muted(0.35))
                    Text(post.time)
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.muted(0.45))
                }
            }

            Spacer(minLength: 8)

            Text("\(post.comments)")
                .font(Theme.body(13, weight: .semibold))
                .foregroundStyle(post.comments > 0 ? Theme.accent : Theme.muted(0.4))
                .frame(minWidth: 26, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 56)
        }
    }

    /// Reddit "expand": author line, then title + tags on the left with a small
    /// square thumbnail on the right, then the action row.
    private var expandRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(post.title)
                        .font(Theme.heading(16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        // Vertical-only fixedSize: the horizontal axis must stay
                        // flexible or a long CJK title (measured at 873pt on a
                        // real chit-chat post) reports that as its width.
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !post.tags.isEmpty {
                        tagBadges
                    }
                }
                // Takes the width left over beside the thumbnail rather than
                // its content's intrinsic size, which is what lets the title
                // wrap instead of pushing the row wider.
                .frame(maxWidth: .infinity, alignment: .leading)

                if let imageURL = post.imageURL {
                    CachedRemoteImage(url: imageURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Theme.neutral300
                    }
                    .frame(width: 78, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    /// Reddit "card": title, excerpt and large edge-to-edge media.
    private var cardRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            Text(post.title)
                .font(Theme.heading(16, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !post.tags.isEmpty {
                tagBadges
            }

            if let videoURL = post.videoURL {
                FeedVideoTile(url: videoURL, posterURL: post.imageURL, onTap: onMediaTap)
            } else if let imageURL = post.imageURL {
                // Reddit-style: the card takes the image's own shape rather
                // than a fixed height, so portrait photos aren't letterboxed
                // and panoramas aren't cropped to a sliver.
                CachedRemoteImage(url: imageURL) { image in
                    image.resizable()
                } placeholder: {
                    Theme.neutral300
                }
                .filledBanner(
                    height: cardMediaHeight,
                    clip: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                // Opens the image viewer rather than the post.
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onTapGesture { onMediaTap?() }
            } else if !post.excerpt.isEmpty {
                Text(post.excerpt)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.text.opacity(0.72))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }

            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { proxy in
            // Inside the horizontal padding, so this is the media's own width.
            proxy.size.width - 28
        } action: { width in
            mediaWidth = width
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    /// Topic tags, styled like Reddit's flair chips.
    private var tagBadges: some View {
        HStack(spacing: 6) {
            ForEach(post.tags.prefix(3), id: \.self) { tag in
                Text(tag)
                    .font(Theme.body(11, weight: .semibold))
                    .foregroundStyle(Theme.accent700)
                    .lineLimit(1)
                    // Three capsules of unbounded text can exceed the screen.
                    // Truncating a long tag is better than widening the page.
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
                    .layoutPriority(-1)
            }
            Spacer(minLength: 0)
        }
        .clampedToWidth()
    }

    private var header: some View {
        HStack(spacing: 7) {
            RemoteAvatar(url: post.avatarURL, letter: post.avatarLetter, variant: post.variant, size: 24)
            Text(post.authorUsername ?? post.node)
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                // `lineLimit` alone still reports the full string as the view's
                // minimum width; this is what lets a long username shrink.
                .layoutPriority(-1)
            Text("· \(post.time)")
                .font(Theme.body(11))
                .foregroundStyle(Theme.muted(0.46))
                .fixedSize()
            if post.pinned {
                Label("置顶", systemImage: "pin.fill")
                    .labelStyle(CompactLabelStyle())
                    .font(Theme.body(10, weight: .semibold))
                    .foregroundStyle(Theme.accent700)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 7)
                    .background(Theme.accent.opacity(0.1), in: Capsule())
            }
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        HStack(spacing: 14) {
            Label("\(post.baseVotes)", systemImage: "arrow.up")
                .labelStyle(CompactLabelStyle())
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.6))
            Label("\(post.comments)", systemImage: "bubble.right")
                .labelStyle(CompactLabelStyle())
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.6))
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Apps

/// Grid of published apps from the discourse-apps directory.
struct AppsDirectoryOverlay: View {
    @Environment(AppState.self) private var app
    @State private var store = AppsDirectoryStore()

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                if store.isLoading && store.apps.isEmpty {
                    NodelocLoader(progress: nil)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                } else if store.visibleApps.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Theme.muted(0.35))
                        Text(store.errorText ?? "没有找到应用")
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.muted(0.5))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(store.visibleApps) { item in
                            Button {
                                app.selectedApp = item
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    app.overlay = .appDetail
                                }
                            } label: {
                                AppTile(app: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await store.load() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Button { closeOverlay(app) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
                .buttonBorderShape(.circle)

                Spacer()

                Text("应用")
                    .font(Theme.heading(18, weight: .semibold))
                    .foregroundStyle(Theme.text)

                Spacer()

                Color.clear.frame(width: 34, height: 34)
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.45))
                TextField("搜索应用", text: Binding(
                    get: { store.query },
                    set: { store.query = $0 }
                ))
                .font(Theme.body(14))
                .foregroundStyle(Theme.text)
                .autocorrectionDisabled()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }
}

/// One app in the directory grid: logo, name, install count.
private struct AppTile: View {
    let app: DirectoryApp

    var body: some View {
        VStack(spacing: 6) {
            AppLogo(app: app, size: 64, cornerRadius: 16)

            Text(app.name)
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 32, alignment: .top)

            if let installs = app.installsCount {
                Text("\(installs) 次安装")
                    .font(Theme.body(10))
                    .foregroundStyle(Theme.muted(0.48))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// App logo with a lettered fallback.
/// App detail: metadata plus entry points to play or to discuss.
struct AppDetailOverlay: View {
    @Environment(AppState.self) private var app
    @State private var store = AppsDirectoryStore()
    @State private var installID: Int?
    @State private var isResolving = true
    @State private var webviewTarget: WebviewTarget?

    /// `fullScreenCover(item:)` needs an Identifiable payload.
    private struct WebviewTarget: Identifiable {
        let url: URL
        let installID: Int
        var id: String { url.absoluteString }
    }

    private let client = DiscourseClient()

    private var item: DirectoryApp? { app.selectedApp }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        summary(item)
                        actions(item)

                        if let description = item.description, !description.isEmpty {
                            Text(description)
                                .font(Theme.body(14))
                                .foregroundStyle(Theme.text.opacity(0.82))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        let readme = DiscourseFormat.plainText(item.readmeCooked)
                        if !readme.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("说明")
                                    .font(Theme.heading(15, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                Text(readme)
                                    .font(Theme.body(13))
                                    .foregroundStyle(Theme.text.opacity(0.76))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .task(id: item?.id) { await resolveInstall() }
        .fullScreenCover(item: $webviewTarget) { target in
            if let item {
                AppWebViewOverlay(
                    app: item,
                    installID: target.installID,
                    url: target.url
                ) {
                    webviewTarget = nil
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { app.overlay = .appsDirectory }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
            .buttonBorderShape(.circle)

            Spacer()

            Button { closeOverlay(app) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
            .buttonBorderShape(.circle)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func summary(_ item: DirectoryApp) -> some View {
        HStack(alignment: .top, spacing: 14) {
            AppLogo(app: item, size: 76, cornerRadius: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(Theme.heading(21, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)

                if let author = item.author?.username {
                    Text("@\(author)")
                        .font(Theme.body(13, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.6))
                }

                HStack(spacing: 6) {
                    if let installs = item.installsCount {
                        Text("\(installs) 次安装")
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.muted(0.55))
                    }
                    if let version = item.versionNumber {
                        Text("·").foregroundStyle(Theme.muted(0.35))
                        Text("v\(version)")
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.muted(0.55))
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func actions(_ item: DirectoryApp) -> some View {
        HStack(spacing: 10) {
            // Only webview apps can run natively, and only once an install id
            // resolves — otherwise the discussion is the only entry point.
            if item.isWebview {
                Button {
                    guard let installID else { return }
                    webviewTarget = WebviewTarget(
                        url: client.appWebviewURL(installID: installID),
                        installID: installID
                    )
                } label: {
                    HStack(spacing: 6) {
                        if isResolving {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
                        }
                        Text("开始游戏")
                            .font(Theme.body(15, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(installID == nil ? Theme.muted(0.3) : Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(installID == nil)
            }

            Button { openDiscussion(item) } label: {
                Label("查看讨论", systemImage: "bubble.left.and.bubble.right")
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(item.hostTopicID == nil)
        }
    }

    private func resolveInstall() async {
        guard let item, item.isWebview else {
            isResolving = false
            return
        }
        isResolving = true
        installID = await store.installID(for: item)
        isResolving = false
    }

    /// Opens the app's host topic through the existing post reader.
    private func openDiscussion(_ item: DirectoryApp) {
        guard let topicID = item.hostTopicID else { return }
        app.selectedPost = Post(
            id: topicID,
            node: "",
            avatarLetter: String(item.name.prefix(1)).uppercased(),
            variant: item.id % 2,
            time: "",
            title: item.name,
            excerpt: item.description ?? "",
            baseVotes: 0,
            comments: 0,
            hasImage: false
        )
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            app.overlay = .post
        }
    }
}

/// Runs a webview app edge-to-edge, with the site's own controls in a capsule
/// the app cannot draw over — mirroring the web plugin's app menu (关于 / 举报)
/// plus an explicit exit.
struct AppWebViewOverlay: View {
    let app: DirectoryApp
    let installID: Int
    let url: URL
    let onClose: () -> Void

    @State private var isLoading = true
    @State private var showAbout = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AppWebView(url: url, isLoading: $isLoading)

            controls
                .padding(.trailing, 12)
                .padding(.top, 6)
        }
        // Edge-to-edge: the app owns the whole screen.
        .ignoresSafeArea()
        .background(Color.black)
        .sheet(isPresented: $showAbout) {
            AppAboutSheet(app: app, installID: installID)
        }
    }

    /// One capsule: ellipsis menu + exit, like the mini-program chrome.
    private var controls: some View {
        HStack(spacing: 2) {
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.text)
                    .frame(width: 30, height: 30)
            }

            Menu {
                Button {
                    showAbout = true
                } label: {
                    Label("关于", systemImage: "info.circle")
                }
                Button(role: .destructive, action: onClose) {
                    Label("退出小程序", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }

            Divider()
                .frame(height: 16)
                .overlay(Theme.divider)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 5)
        .frame(height: 34)
        .glassEffect(.regular.tint(Theme.bg.opacity(0.5)), in: .capsule)
        .shadow(color: .black.opacity(0.12), radius: 9, y: 4)
        // Clear of the status bar, since the frame ignores safe areas.
        .padding(.top, appTopSafeAreaInset)
    }
}

/// What this app is and what it is allowed to do — the plugin's about modal.
private struct AppAboutSheet: View {
    let app: DirectoryApp
    let installID: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        AppLogo(app: app, size: 56, cornerRadius: 14)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name)
                                .font(Theme.heading(18, weight: .bold))
                                .foregroundStyle(Theme.text)
                            if let author = app.author?.username {
                                Text("@\(author)")
                                    .font(Theme.body(13, weight: .semibold))
                                    .foregroundStyle(Theme.muted(0.6))
                            }
                        }
                        Spacer(minLength: 0)
                    }

                    if let description = app.description, !description.isEmpty {
                        Text(description)
                            .font(Theme.body(14))
                            .foregroundStyle(Theme.text.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 0) {
                        factRow("作者", app.author?.username ?? "—")
                        factRow("版本", app.versionNumber.map { "v\($0)" } ?? "—")
                        factRow("安装", "#\(installID)")
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.divider, lineWidth: 1)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("此应用可以做什么")
                            .font(Theme.heading(15, weight: .semibold))
                            .foregroundStyle(Theme.text)

                        if permissions.isEmpty {
                            Text("除了在此面板上绘制内容以外，什么都不做。")
                                .font(Theme.body(13))
                                .foregroundStyle(Theme.muted(0.6))
                        } else {
                            ForEach(permissions, id: \.self) { permission in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Theme.accent)
                                        .padding(.top, 2)
                                    Text(permission)
                                        .font(Theme.body(13))
                                        .foregroundStyle(Theme.text.opacity(0.8))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    Text("应用运行在沙盒中，无法访问你的账号，只能做上述权限允许的事情。")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .navigationTitle("关于此应用")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .tint(Theme.text)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(Theme.body(13))
                .foregroundStyle(Theme.muted(0.6))
            Spacer()
            Text(value)
                .font(Theme.body(13, weight: .semibold))
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 14)
        }
    }

    /// Plain-language scope labels, matching the plugin's own wording.
    private var permissions: [String] {
        let described = [
            "kv": "为你在此应用内保存数据",
            "kv.shared": "读取所有人在此应用中共享的内容，例如排行榜",
            "ui": "显示提示，并将你带到本站的其他页面",
            "points": "向你发放积分",
            "realtime": "在有内容变化时通知其他玩家",
            "schedule": "按计划定时运行",
            "webview": "绘制自己的界面，而不使用本站的组件"
        ]
        return (app.approvedScopes ?? []).map { described[$0] ?? $0 }
    }
}

/// Top inset used by views that intentionally ignore safe areas.
private var appTopSafeAreaInset: CGFloat {
    UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }
        .first ?? 47
}

/// The app's code runs one level deeper, inside the server document's
/// opaque-origin iframe, so the document is loaded as-is.
private struct AppWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Games are touch-driven: a long-press or drag on the canvas would
        // otherwise start text selection and raise the copy/lookup callout over
        // the game. This is a WebKit-level preference, so it also covers the
        // app's sandboxed iframe — which is an opaque origin we cannot inject
        // CSS or JS into.
        configuration.preferences.isTextInteractionEnabled = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // Scrolling itself stays enabled so apps with long content still work.
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.backgroundColor = .black
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(isLoading: $isLoading) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let isLoading: Binding<Bool>

        init(isLoading: Binding<Bool>) {
            self.isLoading = isLoading
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading.wrappedValue = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading.wrappedValue = false
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            isLoading.wrappedValue = false
        }
    }
}

// MARK: - Create node

private enum CreateNodeFocusField: Hashable {
    case name
    case slug
    case description
}

struct CreateNodeOverlay: View {
    @Environment(AppState.self) private var app
    @State private var store = CreateNodeStore()
    @State private var name = ""
    @State private var slug = ""
    @State private var description = ""
    @State private var colorHex = CreateNodeStore.availableColors[0]
    @State private var manualSlug = false
    @FocusState private var focusedField: CreateNodeFocusField?

    var body: some View {
        VStack(spacing: 0) {
            createHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    titleEditor
                    slugEditor
                    parentPicker
                    colorPicker
                    descriptionEditor
                    authHint
                    errorText
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await store.loadParents() }
        .onAppear { focusedField = .name }
        .onChange(of: name) { _, newValue in
            if !manualSlug {
                slug = Self.sanitizedSlug(newValue)
            }
        }
    }

    private var createHeader: some View {
        HStack(spacing: 12) {
            Button { closeOverlay(app) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
            .buttonBorderShape(.circle)
            .shadow(color: .black.opacity(0.08), radius: 9, y: 6)

            parentCategoryMenu

            Spacer(minLength: 8)

            Button {
                submit()
            } label: {
                Group {
                    if store.isSubmitting {
                        ProgressView()
                            .tint(Theme.muted(0.55))
                    } else {
                        Text("创建")
                            .font(Theme.body(15, weight: .semibold))
                    }
                }
                .foregroundStyle(canCreate ? Theme.text : Theme.muted(0.38))
                .padding(.horizontal, 14)
                .frame(height: 34)
            }
            .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
            .buttonBorderShape(.capsule)
            .disabled(!canCreate)
            .opacity(canCreate ? 1 : 0.58)
            .shadow(color: .black.opacity(0.08), radius: 9, y: 6)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 22)
    }

    private var titleEditor: some View {
        TextField("节点名称", text: $name, axis: .vertical)
            .font(Theme.heading(34, weight: .bold))
            .foregroundStyle(Theme.text)
            .lineLimit(1...2)
            .focused($focusedField, equals: .name)
            .submitLabel(.next)
            .onSubmit { focusedField = .slug }
    }

    private var slugEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("短链接")
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.5))

            HStack(spacing: 6) {
                Text("n/")
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.54))
                TextField("your-node", text: slugBinding)
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .slug)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .description }
                Text("\(slug.count)/12")
                    .font(Theme.body(12, weight: .medium))
                    .foregroundStyle(slug.count > 12 ? Theme.danger : Theme.muted(0.42))
            }
            .padding(.horizontal, 13)
            .frame(height: 42)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            }
        }
    }

    private var parentPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("所属主题")
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.5))

            parentCategoryMenu
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("节点颜色")
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.5))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(CreateNodeStore.availableColors, id: \.self) { color in
                    Button {
                        colorHex = color
                    } label: {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(nodeAccentColor(color))
                            .frame(height: 42)
                            .overlay {
                                if color == colorHex {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .strokeBorder(color == colorHex ? Theme.text.opacity(0.5) : Theme.divider, lineWidth: color == colorHex ? 2 : 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var descriptionEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("简介")
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.5))

            ZStack(alignment: .topLeading) {
                if description.isEmpty {
                    Text("写一句这个节点主要讨论什么")
                        .font(Theme.body(15))
                        .foregroundStyle(Theme.muted(0.46))
                        .padding(.horizontal, 13)
                        .padding(.top, 13)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $description)
                    .font(Theme.body(15))
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .background(.clear)
                    .focused($focusedField, equals: .description)
                    .frame(minHeight: 128)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            }
        }
    }

    private var parentCategoryMenu: some View {
        Menu {
            if store.isLoadingParents {
                Text("加载主题中")
            }
            ForEach(store.parentCategories) { category in
                Button {
                    store.selectedParentID = category.id
                } label: {
                    if store.selectedParentID == category.id {
                        Label(category.name, systemImage: "checkmark")
                    } else {
                        Text(category.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(selectedParentName)
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.muted(0.65))
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
        .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
        .buttonBorderShape(.capsule)
        .shadow(color: .black.opacity(0.08), radius: 9, y: 6)
    }

    @ViewBuilder
    private var authHint: some View {
        if !DiscourseAuth.shared.isAuthenticated {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("需要登录后才能创建节点")
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("创建权限仍由 nodeloc.com 的信任等级和数量限制控制。")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.54))
                }
                Spacer()
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var errorText: some View {
        if let errorText = store.errorText {
            Text(errorText)
                .font(Theme.body(13, weight: .medium))
                .foregroundStyle(Theme.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var slugBinding: Binding<String> {
        Binding {
            slug
        } set: { value in
            manualSlug = true
            slug = Self.sanitizedSlug(value)
        }
    }

    private var selectedParentName: String {
        guard let selectedParentID = store.selectedParentID,
              let category = store.parentCategories.first(where: { $0.id == selectedParentID })
        else {
            return store.isLoadingParents ? "加载中" : "选择主题"
        }
        return category.name
    }

    private var canCreate: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return DiscourseAuth.shared.isAuthenticated
            && (3...50).contains(trimmedName.count)
            && (1...12).contains(slug.count)
            && store.selectedParentID != nil
            && !store.isSubmitting
    }

    private func submit() {
        Task {
            if await store.create(
                name: name,
                slug: slug,
                description: description,
                colorHex: colorHex,
                parentCategoryID: store.selectedParentID
            ) {
                closeOverlay(app)
            }
        }
    }

    private static func sanitizedSlug(_ value: String) -> String {
        var output = ""
        var previousWasDash = false
        for scalar in value.lowercased().unicodeScalars {
            let isAlphanumeric = (48...57).contains(scalar.value)
                || (97...122).contains(scalar.value)
            if isAlphanumeric {
                output.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash && !output.isEmpty {
                output.append("-")
                previousWasDash = true
            }
            if output.count >= 12 { break }
        }
        while output.last == "-" {
            output.removeLast()
        }
        return output
    }
}

// MARK: - Public profile

struct PublicProfileOverlay: View {
    let target: UserProfileTarget
    let onClose: () -> Void
    @State private var store = PublicProfileStore()

    @State private var showBadges = false
    @State private var showNodes = false
    @State private var selectedTab: ProfileStore.ProfileTab = .topics
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                LazyVStack(spacing: 18, pinnedViews: [.sectionHeaders]) {
                    profileHero
                    statsRow

                    Section {
                        tabContent
                            .padding(.top, 6)
                            .padding(.bottom, 34)
                    } header: {
                        tabBar
                    }
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentOffset.y)
            } action: { _, newValue in
                scrollOffset = newValue
            }

            floatingHeader
                .frame(maxWidth: .infinity, alignment: .top)
                .zIndex(10)
        }
        .background(Theme.bg.ignoresSafeArea())
        .task(id: target.id) { await store.load(target: target) }
        .task(id: "\(store.username)-\(selectedTab.rawValue)") { await store.loadTab(selectedTab) }
        .sheet(isPresented: $showBadges) { badgeSheet }
        .sheet(isPresented: $showNodes) { nodesSheet }
    }

    // MARK: Floating header (matches the post reader's chrome)

    private let headerControlHeight: CGFloat = 34
    private let headerHorizontalInset: CGFloat = 16
    private let headerGlassTint = Theme.bg.opacity(0.34)
    private let headerShadow = Color.black.opacity(0.08)

    /// 0 → 1 as the banner scrolls away, revealing the inline user pill.
    private var userRevealProgress: CGFloat {
        min(max((scrollOffset - 60) / 80, 0), 1)
    }

    private var floatingHeader: some View {
        HStack(spacing: 8) {
            headerGlassButton(borderShape: .circle, action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.headerText)
                    .frame(width: headerControlHeight, height: headerControlHeight)
            }

            userPill
                .opacity(userRevealProgress)
                .offset(y: (1 - userRevealProgress) * -4)

            Spacer(minLength: 0)

            headerTools
        }
        .padding(.horizontal, headerHorizontalInset)
        .padding(.top, 8)
    }

    /// Avatar + username, revealed between the back button and the tool pill.
    private var userPill: some View {
        headerGlassButton(borderShape: .capsule, action: {}) {
            HStack(spacing: 6) {
                RemoteAvatar(
                    url: store.avatarURL,
                    letter: store.initial,
                    variant: abs(store.username.hashValue),
                    size: 22
                )
                Text(store.displayName)
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(height: headerControlHeight)
        }
        .allowsHitTesting(false)
    }

    /// Search / share / more in one glass capsule. Same construction as the post
    /// reader's tool cluster: a native glass button provides the capsule, with
    /// the tappable icons layered on top.
    private var headerTools: some View {
        ZStack {
            headerGlassButton(borderShape: .capsule, action: {}) {
                headerToolsChrome
                    .opacity(0)
            }
            .allowsHitTesting(false)

            headerToolsContent
        }
    }

    private var headerToolsChrome: some View {
        HStack(spacing: 4) {
            headerToolIcon("magnifyingglass")
            headerToolIcon("square.and.arrow.up")
            headerToolIcon("ellipsis")
        }
        .padding(.horizontal, 7)
        .frame(height: headerControlHeight)
    }

    private var headerToolsContent: some View {
        HStack(spacing: 4) {
            Button {} label: { headerToolIcon("magnifyingglass") }
                .buttonStyle(.plain)
            Button {} label: { headerToolIcon("square.and.arrow.up") }
                .buttonStyle(.plain)
            Button {} label: { headerToolIcon("ellipsis") }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 7)
        .frame(height: headerControlHeight)
    }

    private func headerToolIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.text)
            .frame(width: 26, height: 26)
    }

    /// Native glass button, matching the post reader and home header chrome.
    private func headerGlassButton<Label: View>(
        borderShape: ButtonBorderShape,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .frame(height: headerControlHeight)
        }
        .buttonStyle(.glass(.regular.tint(headerGlassTint)))
        .buttonBorderShape(borderShape)
        .shadow(color: headerShadow, radius: 9, y: 6)
    }

    /// Banner height, including the area behind the status bar.
    private var bannerHeight: CGFloat { 188 + topSafeAreaInset }

    private var profileHero: some View {
        VStack(spacing: 0) {
            // Runs to the very top, behind the status bar and floating header.
            profileBanner

            profileCard
                .padding(.horizontal, 16)
                .offset(y: -58)
                .padding(.bottom, -58)
        }
    }

    private var topSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }
            .first ?? 47
    }

    /// Fixed-height banner: a tall image is aspect-filled then cropped to
    /// `bannerHeight` rather than pushing the content below it down.
    @ViewBuilder
    private var profileBanner: some View {
        if let backgroundURL = store.backgroundURL {
            CachedRemoteImage(url: backgroundURL) { image in
                image
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: bannerHeight)
                    .clipped()
            } placeholder: {
                profileBannerFallback
            }
        } else {
            profileBannerFallback
        }
    }

    private var profileBannerFallback: some View {
        ZStack {
            Theme.surface
            Image(systemName: "at")
                .font(.system(size: 96, weight: .semibold))
                .foregroundStyle(Theme.muted(0.08))
        }
        .frame(maxWidth: .infinity)
        .frame(height: bannerHeight)
    }

    /// 关注 / 取关 toggle backed by the discourse-follow endpoints.
    private var followButton: some View {
        Button {
            Task { await store.toggleFollow() }
        } label: {
            HStack(spacing: 4) {
                if store.isTogglingFollow {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(store.isFollowing ? Theme.text : .white)
                } else {
                    Image(systemName: store.isFollowing ? "checkmark" : "plus")
                        .font(.system(size: 10, weight: .bold))
                }
                Text(store.isFollowing ? "已关注" : "关注")
                    .font(Theme.body(12, weight: .semibold))
            }
            .foregroundStyle(store.isFollowing ? Theme.text : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(store.isFollowing ? Theme.surface : Theme.accent, in: Capsule())
            .overlay {
                if store.isFollowing {
                    Capsule().strokeBorder(Theme.divider, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(store.isTogglingFollow)
    }

    private var profileCard: some View {
        VStack(spacing: 12) {
            RemoteAvatar(
                url: store.avatarURL,
                letter: store.initial,
                variant: abs(store.username.hashValue),
                size: 96
            )
            .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 5))
            .shadow(color: .black.opacity(0.14), radius: 14, y: 8)
            .offset(y: -44)
            .padding(.bottom, -36)

            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(store.displayName)
                        .font(Theme.heading(24, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    if let title = store.title, !title.isEmpty {
                        titleBadge(title)
                    }
                }

                HStack(spacing: 6) {
                    Text("@\(store.username)")
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.62))

                    if let flair = store.flair {
                        FlairBadge(flair: flair)
                    }

                    if let followers = store.followerCount {
                        Text("·")
                            .font(Theme.body(15, weight: .semibold))
                            .foregroundStyle(Theme.muted(0.38))
                        Text("\(followers) 粉丝")
                            .font(Theme.body(14, weight: .semibold))
                            .foregroundStyle(Theme.muted(0.62))
                    }

                    if store.canFollow {
                        followButton
                    }
                }
            }

            HStack(spacing: 8) {
                profilePill(store.lastSeen, dot: true)
                profilePill(store.joined)
            }

            if !store.roles.isEmpty {
                FlowLayout(spacing: 8, alignment: .center) {
                    ForEach(store.roles, id: \.self) { role in
                        profileChip(role, color: roleColor(role))
                    }
                }
                .frame(maxWidth: .infinity)
            }

            if !store.badges.isEmpty || !store.topCategories.isEmpty {
                FlowLayout(spacing: 8, alignment: .center) {
                    if !store.badges.isEmpty { achievementsLink }
                    if !store.topCategories.isEmpty { nodesLink }
                }
                .frame(maxWidth: .infinity)
            }

            if !store.bio.isEmpty {
                Text(store.bio)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.text.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
            }

            profileMeta

            if store.isLoading {
                ProgressView()
                    .tint(Theme.accent)
                    .padding(.top, 2)
            } else if let errorText = store.errorText {
                Text(errorText)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.danger)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
    }

    /// 头衔 with its admin-designed style, beside the display name. Plain text —
    /// the style itself (color + effect) carries the emphasis, no chrome.
    @ViewBuilder
    private func titleBadge(_ title: String) -> some View {
        if let style = store.titleStyle {
            StyledTitleText(text: title, style: style)
                .lineLimit(1)
        } else {
            Text(title)
                .font(Theme.body(13, weight: .semibold))
                .foregroundStyle(Theme.muted(0.62))
                .lineLimit(1)
        }
    }

    private var achievementsLink: some View {
        Button { showBadges = true } label: {
            HStack(spacing: 8) {
                HStack(spacing: -7) {
                    ForEach(0..<min(3, store.badges.count), id: \.self) { index in
                        Circle()
                            .fill(badgeColor(index))
                            .frame(width: 22, height: 22)
                            .overlay {
                                Image(systemName: "rosette")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 2))
                    }
                }
                Text("\(store.badges.count) 项徽章")
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.5))
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var nodesLink: some View {
        Button { showNodes = true } label: {
            HStack(spacing: 8) {
                HStack(spacing: -7) {
                    ForEach(store.topCategories.prefix(3)) { node in
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 22, height: 22)
                            .overlay {
                                Text(node.letter)
                                    .font(Theme.heading(10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 2))
                    }
                }
                Text("\(store.topCategories.count) 个节点")
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.5))
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func badgeColor(_ index: Int) -> Color {
        let colors: [Color] = [
            Color(light: 0xD99A00, dark: 0xF8D34B),
            Color(light: 0x2F6DF6, dark: 0x7EA7FF),
            Color(light: 0x8A36D6, dark: 0xC99BFF),
            Color(light: 0x1FA36B, dark: 0x5FD6A0)
        ]
        return colors[index % colors.count]
    }

    private var badgeSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(store.badgeDetails.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(badgeColor(index).opacity(0.14))
                                .frame(width: 44, height: 44)
                                .overlay {
                                    Image(systemName: "rosette")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(badgeColor(index))
                                }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                    .font(Theme.body(15, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                if !item.description.isEmpty {
                                    Text(item.description)
                                        .font(Theme.body(12))
                                        .foregroundStyle(Theme.muted(0.6))
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Theme.divider, lineWidth: 1)
                        }
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .navigationTitle("徽章")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var nodesSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(store.topCategories) { node in
                        HStack(spacing: 12) {
                            Avatar(letter: node.letter, variant: node.variant, size: 44, cornerRadius: 12)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(node.name)
                                    .font(Theme.body(15, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                if !node.desc.isEmpty {
                                    Text(node.desc)
                                        .font(Theme.body(12))
                                        .foregroundStyle(Theme.muted(0.6))
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(node.members)
                                .font(Theme.body(11, weight: .semibold))
                                .foregroundStyle(Theme.muted(0.48))
                        }
                        .padding(14)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Theme.divider, lineWidth: 1)
                        }
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .navigationTitle("常去节点")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var profileMeta: some View {
        let items = [store.location, store.website].compactMap { value in
            value?.isEmpty == false ? value : nil
        }
        if !items.isEmpty {
            HStack(spacing: 14) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 5) {
                        Image(systemName: item == store.website ? "link" : "mappin.and.ellipse")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(light: 0x2F6DF6, dark: 0x7EA7FF))
                        Text(item)
                            .font(Theme.body(12, weight: .medium))
                            .foregroundStyle(Theme.muted(0.62))
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    /// Reddit-style stat row, matching the 我的 page.
    private var statsRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(store.stats.enumerated()), id: \.offset) { index, stat in
                VStack(spacing: 3) {
                    Text(stat.value)
                        .font(Theme.heading(17, weight: .bold))
                        .foregroundStyle(stat.label == "能量" || stat.label == "声望" ? Theme.accent : Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(stat.label)
                        .font(Theme.body(10, weight: .medium))
                        .foregroundStyle(Theme.muted(0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)

                if index < store.stats.count - 1 {
                    Rectangle()
                        .fill(Theme.divider)
                        .frame(width: 1, height: 26)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                ForEach(ProfileStore.ProfileTab.allCases) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tab }
                    } label: {
                        VStack(spacing: 7) {
                            Text(tab.rawValue)
                                .font(Theme.body(14, weight: selectedTab == tab ? .semibold : .medium))
                                .foregroundStyle(selectedTab == tab ? Theme.text : Theme.muted(0.5))
                            Rectangle()
                                .fill(selectedTab == tab ? Theme.accent : Color.clear)
                                .frame(height: 2)
                                .clipShape(Capsule())
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        if selectedTab == .energy {
            if store.loadingTab == .energy && store.pointsHistory.isEmpty {
                loadingRow
            } else if store.pointsHistory.isEmpty {
                emptyTab(icon: "bolt.slash", text: "暂无能量历史记录")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(store.pointsHistory) { pointsRow($0) }
                }
            }
        } else if store.loadingTab == selectedTab && (store.actionItems[selectedTab]?.isEmpty ?? true) {
            loadingRow
        } else if let items = store.actionItems[selectedTab], !items.isEmpty {
            LazyVStack(spacing: 0) {
                ForEach(items) { activityRow($0) }
            }
        } else {
            emptyTab(icon: "tray", text: "还没有\(selectedTab.rawValue)")
        }
    }

    private var loadingRow: some View {
        ProgressView()
            .tint(Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 44)
    }

    private func emptyTab(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.muted(0.35))
            Text(text)
                .font(Theme.body(13))
                .foregroundStyle(Theme.muted(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
    }

    private func activityRow(_ item: UserActionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title ?? "无标题")
                .font(Theme.body(15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            let excerpt = DiscourseFormat.plainText(item.excerpt ?? "")
            if !excerpt.isEmpty {
                Text(excerpt)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.muted(0.6))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Text(DiscourseFormat.relative(item.createdAt))
                .font(Theme.body(11, weight: .medium))
                .foregroundStyle(Theme.muted(0.45))
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 16)
        }
    }

    private func pointsRow(_ entry: PointsHistoryEntry) -> some View {
        let points = entry.points ?? 0
        let positive = entry.isPositive ?? (points > 0)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.description ?? "能量变动")
                    .font(Theme.body(14, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(entry.date.map { String($0.prefix(10)) } ?? DiscourseFormat.relative(entry.createdAt))
                    .font(Theme.body(11, weight: .medium))
                    .foregroundStyle(Theme.muted(0.45))
            }
            Spacer(minLength: 8)
            Text(positive ? "+\(points)" : "\(points)")
                .font(Theme.heading(16, weight: .bold))
                .foregroundStyle(positive ? Theme.accent : Theme.danger)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 16)
        }
    }

    private func profilePill(_ text: String, dot: Bool = false) -> some View {
        HStack(spacing: 5) {
            if dot {
                Circle()
                    .fill(Theme.muted(0.32))
                    .frame(width: 8, height: 8)
            }
            Text(text)
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.62))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.hover, in: Capsule())
    }

    private func profileChip(_ text: String, color: Color, icon: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color)
            }
            Text(text)
                .font(Theme.body(11, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.1), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.22), lineWidth: 1))
    }

    private func roleColor(_ role: String) -> Color {
        switch role {
        case "ADMIN", "MOD": return Theme.danger
        case "REGULAR", "LEADER": return Color(light: 0x8A36D6, dark: 0xC99BFF)
        default: return Color(light: 0x2F6DF6, dark: 0x7EA7FF)
        }
    }
}

// MARK: - Post detail

struct PostDetailOverlay: View {
    @Environment(AppState.self) private var app
    let postTransitionNamespace: Namespace.ID
    @State private var topic = TopicStore()
    @State private var draft = ""
    @State private var collapsedCommentIDs: Set<Int> = []
    @State private var detailScrollOffset: CGFloat = 0
    @State private var selectedProfile: UserProfileTarget?
    /// Full-screen image viewer state. Non-empty means the viewer is showing.
    @State private var viewerImages: [PostImage] = []
    @State private var viewerIndex = 0
    /// The post's node, resolved for its logo — `Post` carries only "n/slug".
    @State private var nodeSummary: SidebarNodeSummary?
    @FocusState private var isReplyFocused: Bool

    var body: some View {
        let post = app.selectedPost
        GeometryReader { _ in
            ZStack(alignment: .top) {
                Theme.bg
                    .matchedGeometryEffect(
                        id: postTransitionID(post.id),
                        in: postTransitionNamespace,
                        properties: .frame,
                        anchor: .center,
                        isSource: true
                    )
                    .allowsHitTesting(false)
                    .zIndex(0)

                detailSurface(for: post)
                    .zIndex(1)

                floatingReaderHeader(for: post)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .zIndex(10)

                if let selectedProfile {
                    PublicProfileOverlay(target: selectedProfile) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                            self.selectedProfile = nil
                        }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(30)
                }

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.bg)
        }
        .background(Theme.bg.ignoresSafeArea())
        .task(id: post.id) { await topic.load(topicID: post.id) }
        .task(id: post.node) { nodeSummary = await NodeCatalog.shared.node(slug: post.node) }
        // Identity for the full-screen video chrome. Set here rather than
        // inside PostContentView so the video sees the same like state the
        // post's own action bar does. The loaded topic supplies a better author
        // and reply count than the list item can.
        .environment(
            \.postVideoPresentation,
            PostVideoPresentation(
                post: post,
                node: nodeSummary,
                author: authorProfileTarget(for: post),
                commentCount: replyCount(for: post)
            )
        )
        .environment(
            \.postVideoActions,
            PostVideoActions(
                remoteLike: { Task { await topic.like() } },
                comment: { focusReplyField() }
            )
        )
        // Same chrome as the video viewer, from the same presentation.
        .postImageFullScreen(
            images: $viewerImages,
            selection: $viewerIndex,
            presentation: PostVideoPresentation(
                post: post,
                node: nodeSummary,
                author: authorProfileTarget(for: post),
                commentCount: replyCount(for: post)
            ),
            onRemoteLike: { Task { await topic.like() } },
            onComment: { focusReplyField() }
        )
        .alert(
            topic.pluginErrorText ?? "",
            isPresented: Binding(
                get: { topic.pluginErrorText != nil },
                set: { if !$0 { topic.pluginErrorText = nil } }
            )
        ) {
            Button("好", role: .cancel) { topic.pluginErrorText = nil }
        }
    }

    private let readerTopInset: CGFloat = 62
    // Shared with the full-screen video header so the two stay identical.
    private let readerHeaderControlHeight = FloatingHeader.controlHeight
    private let readerNodePillWidth = FloatingHeader.nodePillWidth
    private let readerHeaderHorizontalInset = FloatingHeader.horizontalInset
    private let readerHeaderGlassTint = FloatingHeader.glassTint
    private let readerHeaderShadow = FloatingHeader.shadow

    private func detailSurface(for post: Post) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: readerTopInset)

                authorLine(for: post)
                    .padding(.bottom, 12)

                Text(post.title)
                    .font(Theme.heading(24, weight: .semibold))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 14)

                if let envelope = topic.redEnvelope {
                    RedEnvelopeBanner(envelope: envelope)
                        .padding(.bottom, 14)
                }

                if topic.content.isEmpty {
                    // Falls back to the list excerpt until the body arrives.
                    Text(post.excerpt)
                        .font(Theme.body(16))
                        .lineSpacing(6)
                        .foregroundStyle(Theme.text.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    PostContentView(
                        content: topic.content,
                        metrics: .body,
                        onImageTap: { image in
                            let images = topic.content.images
                            viewerImages = images
                            viewerIndex = images.firstIndex { $0.src == image.src } ?? 0
                        },
                        pollProvider: { name in
                            guard let poll = topic.firstPostPolls.first(where: { $0.pollName == name }) else {
                                return nil
                            }
                            return AnyView(
                                PollView(
                                    poll: poll,
                                    myVotes: topic.myPollVotes[name] ?? [],
                                    isBusy: topic.pollsInFlight.contains(name),
                                    onVote: { options in
                                        Task { await topic.vote(pollName: name, options: options) }
                                    },
                                    onRemoveVote: {
                                        Task { await topic.removeVote(pollName: name) }
                                    }
                                )
                            )
                        }
                    )
                }

                if let lottery = topic.lottery {
                    LotteryView(
                        lottery: lottery,
                        isBusy: topic.isLotteryBusy,
                        onParticipate: { quantity, isRandom in
                            Task { await topic.participateInLottery(quantity: quantity, isRandom: isRandom) }
                        }
                    )
                    .padding(.top, 18)
                }

                if topic.isLoading && topic.content.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(Theme.accent)
                        Text("Loading full post")
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.muted(0.42))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 16)
                }

                // No cover image here. `post.imageURL` is the feed thumbnail —
                // the body's own first image — so showing it after the content
                // repeated a picture the reader had just scrolled past. It
                // predates the native renderer, which draws body images inline.

                postActions(for: post)
                    .padding(.top, 20)

                repliesSection(for: post)
                    .padding(.top, 28)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Backstop: keeps any single over-wide child from setting the
            // scroll content width for the whole page.
            .clampedToWidth()
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            replyComposer(for: post)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(0, geometry.contentOffset.y)
        } action: { _, newValue in
            detailScrollOffset = newValue
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private var nodeRevealProgress: CGFloat {
        min(max((detailScrollOffset - 36) / 72, 0), 1)
    }

    private func floatingReaderHeader(for post: Post) -> some View {
        HStack(spacing: 8) {
            readerHeaderGlassButton(borderShape: .circle) {
                closeOverlay(app)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .frame(width: readerHeaderControlHeight, height: readerHeaderControlHeight)
            }

            nodePill(for: post)
                .opacity(nodeRevealProgress)
                .offset(y: (1 - nodeRevealProgress) * -4)

            Spacer(minLength: 0)

            readerTools(for: post)
        }
        .padding(.horizontal, readerHeaderHorizontalInset)
        .padding(.top, 8)
        .zIndex(2)
    }

    private func readerHeaderGlassButton<Label: View>(
        borderShape: ButtonBorderShape,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .frame(height: readerHeaderControlHeight)
        }
        .buttonStyle(.glass(.regular.tint(readerHeaderGlassTint)))
        .buttonBorderShape(borderShape)
        .shadow(color: readerHeaderShadow, radius: 9, y: 6)
    }

    private func nodePill(for post: Post) -> some View {
        readerHeaderGlassButton(borderShape: .capsule, action: {}) {
            Text(post.node)
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(width: readerNodePillWidth, height: readerHeaderControlHeight, alignment: .leading)
        }
        .allowsHitTesting(false)
    }

    private func readerTools(for post: Post) -> some View {
        ZStack {
            readerHeaderGlassButton(borderShape: .capsule, action: {}) {
                readerToolsChrome
                    .opacity(0)
            }
            .allowsHitTesting(false)

            readerToolsContent
        }
    }

    private var readerToolsChrome: some View {
        HStack(spacing: 4) {
            readerToolIcon("magnifyingglass")
            readerToolIcon("slider.horizontal.3")
            readerToolIcon("ellipsis")
            readerAvatar
        }
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .frame(height: readerHeaderControlHeight)
    }

    private var readerToolsContent: some View {
        HStack(spacing: 4) {
            Button {
                closeOverlay(app)
                app.tab = .search
            } label: {
                readerToolIcon("magnifyingglass")
            }
            .buttonStyle(.plain)

            Button {} label: {
                readerToolIcon("slider.horizontal.3")
            }
            .buttonStyle(.plain)

            Button {} label: {
                readerToolIcon("ellipsis")
            }
            .buttonStyle(.plain)

            readerAvatar
        }
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .frame(height: readerHeaderControlHeight)
    }

    private func readerToolIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.text)
            .frame(width: 26, height: 26)
    }

    private var readerAvatar: some View {
        RemoteAvatar(
            url: nil,
            letter: SampleData.userInitial,
            variant: 0,
            size: 26
        )
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(Theme.success)
                .frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 1.5))
                .offset(x: 1, y: -1)
        }
    }

    private func authorLine(for post: Post) -> some View {
        HStack(spacing: 9) {
            Button {
                openProfile(authorProfileTarget(for: post))
            } label: {
                RemoteAvatar(
                    url: topic.firstAuthor?.avatarURL ?? post.avatarURL,
                    letter: topic.firstAuthor?.initial ?? post.avatarLetter,
                    variant: post.variant,
                    size: 30,
                    cornerRadius: 9
                )
            }
            .buttonStyle(.plain)
            .disabled(authorProfileTarget(for: post) == nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.firstAuthor?.username ?? post.authorUsername ?? post.node)
                    .font(Theme.body(13, weight: .semibold))
                Text(post.time)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.muted(0.48))
            }
            Spacer(minLength: 0)
            Text("#1")
                .font(Theme.body(12))
                .foregroundStyle(Theme.muted(0.28))
        }
    }

    private func authorProfileTarget(for post: Post) -> UserProfileTarget? {
        if let firstAuthor = topic.firstAuthor {
            return firstAuthor
        }
        guard let username = post.authorUsername else { return nil }
        return UserProfileTarget(
            username: username,
            displayName: post.authorName,
            avatarURL: post.avatarURL
        )
    }

    private func openProfile(_ target: UserProfileTarget?) {
        guard let target else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            selectedProfile = target
        }
    }

    /// Identity and counts shown over a full-screen video.
    /// Dismisses the video cover's keyboard target and focuses the reply box.
    private func focusReplyField() {
        guard DiscourseAuth.shared.isAuthenticated else { return }
        isReplyFocused = true
    }


    private func postActions(for post: Post) -> some View {
        HStack(spacing: 18) {
            Button {
                let wasLiked = app.isLiked(post)
                app.toggleLike(post)
                if !wasLiked { Task { await topic.like() } }
            } label: {
                Label("\(app.voteCount(post))", systemImage: app.isLiked(post) ? "heart.fill" : "heart")
                    .labelStyle(CompactLabelStyle())
                    .foregroundStyle(app.isLiked(post) ? Theme.love : Theme.muted(0.42))
            }
            .buttonStyle(.plain)

            Label("\(replyCount(for: post))", systemImage: "bubble.left")
                .labelStyle(CompactLabelStyle())

            Spacer(minLength: 0)

            Image(systemName: "arrowshape.turn.up.left")
            Image(systemName: "link")
        }
        .font(Theme.body(12, weight: .medium))
        .foregroundStyle(Theme.muted(0.42))
    }

    private func repliesSection(for post: Post) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(replyCount(for: post)) replies")
                    .font(Theme.heading(15, weight: .semibold))
                Spacer()
                Text(post.node)
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.muted(0.42))
            }
            .padding(.bottom, 10)

            LazyVStack(spacing: 0) {
                if topic.isLoading && topic.comments.isEmpty {
                    ProgressView()
                        .tint(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else if topic.comments.isEmpty {
                    Text("No replies yet.")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.muted(0.45))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else {
                    ForEach(visibleComments) { comment in
                        NestedReplyRow(
                            comment: comment,
                            isCollapsed: collapsedCommentIDs.contains(comment.id),
                            onToggleCollapse: { toggleCollapse(comment) },
                            onOpenAuthor: { openProfile($0) },
                            onImageTap: { image in
                                // Page through just this reply's images.
                                let images = comment.content.images
                                viewerImages = images
                                viewerIndex = images.firstIndex { $0.src == image.src } ?? 0
                            }
                        )
                    }

                    if topic.hasMoreComments {
                        loadMoreRepliesButton(for: post)
                    }
                }
            }
        }
    }

    private func loadMoreRepliesButton(for post: Post) -> some View {
        Button {
            Task { await topic.loadMoreComments(topicID: post.id) }
        } label: {
            HStack(spacing: 8) {
                if topic.isLoadingMore {
                    ProgressView()
                        .tint(Theme.accent)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 15, weight: .medium))
                }

                Text(loadMoreTitle)
                    .font(Theme.body(13, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(topic.isLoadingMore)
    }

    private func replyComposer(for post: Post) -> some View {
        HStack(spacing: 10) {
            PlainField(placeholder: DiscourseAuth.shared.isAuthenticated ? "Add a reply…" : "Log in to reply",
                       text: $draft)
                .focused($isReplyFocused)
                .disabled(!DiscourseAuth.shared.isAuthenticated)

            Button {
                let text = draft
                Task {
                    if await topic.submitReply(text, topicID: post.id) { draft = "" }
                }
            } label: {
                ZStack {
                    if topic.isSubmitting {
                        ProgressView().tint(Theme.accent)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .foregroundStyle(Theme.accent)
                .frame(width: 42, height: 42)
                .background(Theme.accent.opacity(0.1), in: Circle())
                .overlay(Circle().strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!DiscourseAuth.shared.isAuthenticated
                      || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || topic.isSubmitting)
            .opacity(replyDisabled ? 0.45 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Theme.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    private var replyDisabled: Bool {
        !DiscourseAuth.shared.isAuthenticated
        || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || topic.isSubmitting
    }

    private var loadMoreTitle: String {
        let count = min(topic.remainingCommentCount, 20)
        return count > 0 ? "Load \(count) more replies" : "Load more replies"
    }

    private func replyCount(for post: Post) -> Int {
        topic.totalReplyCount > 0 ? topic.totalReplyCount : (topic.comments.isEmpty ? post.comments : topic.comments.count)
    }

    private var visibleComments: [PostComment] {
        var output: [PostComment] = []
        var hiddenDepth: Int?

        for comment in topic.comments {
            if let depth = hiddenDepth {
                if comment.nestingDepth > depth {
                    continue
                }
                hiddenDepth = nil
            }

            output.append(comment)

            if collapsedCommentIDs.contains(comment.id), comment.hasChildren {
                hiddenDepth = comment.nestingDepth
            }
        }

        return output
    }

    private func toggleCollapse(_ comment: PostComment) {
        guard comment.hasChildren else { return }
        if collapsedCommentIDs.contains(comment.id) {
            collapsedCommentIDs.remove(comment.id)
        } else {
            collapsedCommentIDs.insert(comment.id)
        }
    }
}

private struct NestedReplyRow: View {
    let comment: PostComment
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    let onOpenAuthor: (UserProfileTarget) -> Void
    var onImageTap: ((PostImage) -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            RedditThreadRails(depth: railDepth)
                .frame(width: contentLeading)

            VStack(alignment: .leading, spacing: 8) {
                replyHeader

                if isCollapsed {
                    Text("Replies hidden")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.42))
                } else {
                    PostContentView(
                        content: comment.content,
                        metrics: .reply,
                        onImageTap: onImageTap
                    )

                    // The red envelope plugin auto-claims on reply, so this is
                    // the outcome of posting rather than an action to take.
                    if let claim = comment.redEnvelopeClaim, let points = claim.points {
                        Label("领取了 \(points) 能量", systemImage: "yensign.circle.fill")
                            .font(Theme.body(11, weight: .semibold))
                            .foregroundStyle(Theme.danger)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.danger.opacity(0.1), in: Capsule())
                    }

                    actionBar
                }
            }
            .padding(.leading, contentLeading)
            .padding(.vertical, Self.verticalPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The indent grows with nesting depth. Without clipping, a deep reply
        // is wider than the screen and the ScrollView adopts that width,
        // dragging every sibling — banner, images, other replies — with it.
        .clampedToWidth()
    }

    private var replyHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                onOpenAuthor(UserProfileTarget(username: comment.author, displayName: nil, avatarURL: comment.avatarURL))
            } label: {
                RemoteAvatar(url: comment.avatarURL, letter: avatarLetter, variant: comment.id, size: 24)
            }
            .buttonStyle(.plain)

            Text(comment.author)
                .font(Theme.body(12, weight: .semibold))

            Text("· \(comment.time)")
                .font(Theme.body(12))
                .foregroundStyle(Theme.muted(0.42))

            if let parentNumber = comment.replyToPostNumber, parentNumber > 1 {
                Text("to #\(parentNumber)")
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.muted(0.34))
            }

            Spacer(minLength: 0)

            Text("#\(comment.postNumber)")
                .font(Theme.body(12))
                .foregroundStyle(Theme.muted(0.26))

            if comment.hasChildren {
                Button(action: onToggleCollapse) {
                    Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.44))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "Expand replies" : "Collapse replies")
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 16) {
            if comment.votes > 0 {
                Label("\(comment.votes)", systemImage: "heart")
                    .labelStyle(CompactLabelStyle())
            }

            Spacer(minLength: 0)

            Image(systemName: "arrowshape.turn.up.left")
            Image(systemName: "link")
        }
        .font(Theme.body(12, weight: .medium))
        .foregroundStyle(Theme.muted(0.38))
    }

    private var contentLeading: CGFloat {
        guard railDepth > 0 else { return 0 }
        return CGFloat(railDepth) * Self.indentStep + Self.railContentGap
    }

    private var railDepth: Int {
        min(max(comment.nestingDepth, 0), Self.maxIndentLevels)
    }

    private var avatarLetter: String {
        comment.author.first.map { String($0).uppercased() } ?? "?"
    }

    fileprivate static let verticalPadding: CGFloat = 12
    fileprivate static let indentStep: CGFloat = 16
    fileprivate static let railContentGap: CGFloat = 8
    fileprivate static let maxIndentLevels: Int = 5
}

private struct RedditThreadRails: View {
    let depth: Int

    var body: some View {
        Canvas { context, size in
            guard visibleDepth > 0 else { return }

            for index in 0..<visibleDepth {
                var path = Path()
                let x = CGFloat(index) * Self.indentStep + Self.railWidth / 2
                path.move(to: CGPoint(x: x, y: -1))
                path.addLine(to: CGPoint(x: x, y: size.height + 1))
                context.stroke(
                    path,
                    with: .color(railColor(for: index)),
                    lineWidth: Self.railWidth
                )
            }
        }
        .allowsHitTesting(false)
    }

    private var visibleDepth: Int {
        min(max(depth, 0), Self.maxIndentLevels)
    }

    private func railColor(for index: Int) -> Color {
        let colors: [Color] = [
            Theme.accent.opacity(0.46),
            Theme.success.opacity(0.38),
            Theme.accent2_600.opacity(0.34),
            Theme.love.opacity(0.32),
            Theme.muted(0.22),
        ]
        return colors[index % colors.count]
    }

    private static let indentStep: CGFloat = NestedReplyRow.indentStep
    private static let maxIndentLevels: Int = NestedReplyRow.maxIndentLevels
    private static let railWidth: CGFloat = 2
}

// MARK: - Notifications

struct NotificationsOverlay: View {
    @State private var store = NotificationsStore()

    var body: some View {
        VStack(spacing: 0) {
            OverlayHeader(title: "Notifications")
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.isLoading && store.items.isEmpty {
                        ProgressView().tint(Theme.accent).padding(.top, 40)
                    }
                    ForEach(store.items) { notification in
                        NotificationRow(notification: notification)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await store.load() }
    }
}

private struct NotificationRow: View {
    let notification: AppNotification

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: iconWeight))
                .foregroundStyle(iconColor)
                .frame(width: 32, height: 32)
                .background(iconBg, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                (Text(notification.name).font(Theme.body(13, weight: .semibold))
                    + Text(" \(notification.text)").font(Theme.body(13)))
                    .foregroundStyle(Theme.text)
                Text(notification.time).font(Theme.body(11)).foregroundStyle(Theme.muted(0.5))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12).padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(notification.unread ? Theme.accent.opacity(0.06) : .clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    private var icon: String {
        switch notification.kind {
        case .like: return "heart.fill"
        case .comment: return "bubble.left"
        case .message: return "envelope.fill"
        case .success: return "checkmark"
        case .star: return "star.fill"
        }
    }
    private var iconWeight: Font.Weight {
        (notification.kind == .success || notification.kind == .comment) ? .bold : .regular
    }
    private var iconColor: Color {
        switch notification.kind {
        case .like: return Theme.love
        case .comment: return Theme.accent700
        case .message: return Theme.text
        case .success: return Theme.success
        case .star: return Theme.accent2_600
        }
    }
    private var iconBg: Color {
        switch notification.kind {
        case .like: return Theme.surface.blended(with: Theme.love, fraction: 0.15)
        case .comment: return Theme.surface.blended(with: Theme.accent, fraction: 0.15)
        case .message: return Theme.surface.blended(with: Theme.text, fraction: 0.08)
        case .success: return Theme.surface.blended(with: Theme.success, fraction: 0.15)
        case .star: return Theme.surface.blended(with: Theme.accent2_500, fraction: 0.18)
        }
    }
}

// MARK: - Settings

struct SettingsOverlay: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            OverlayHeader(title: "Settings")
            ScrollView {
                LazyVStack(spacing: 0) {
                    accountActionRow(label: "通知", icon: "bell.fill", tint: Theme.accent) {
                        app.overlay = .notifications
                    }
                    accountActionRow(label: "Nodeloc Pro", icon: "sparkle", tint: Theme.accent) {
                        app.overlay = .pro
                    }
                    if app.authed && !app.isGuest {
                        accountActionRow(label: "退出登录", icon: "rectangle.portrait.and.arrow.right", tint: Theme.danger, danger: true) {
                            DiscourseLogin.shared.signOut()
                            app.overlay = nil
                            app.onboardingDone = false
                            app.isGuest = false
                            app.authed = false
                        }
                    }

                    ForEach(SampleData.settings) { row in
                        HStack {
                            Text(row.label)
                                .font(Theme.body(14))
                                .foregroundStyle(row.danger ? Theme.danger : Theme.text)
                            Spacer()
                            Text(row.detail).font(Theme.body(12)).foregroundStyle(Theme.muted(0.4))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.muted(0.3))
                        }
                        .padding(.vertical, 14).padding(.horizontal, 20)
                        .contentShape(Rectangle())
                        .onTapGesture { handle(row) }
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Theme.divider).frame(height: 1)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    private func accountActionRow(
        label: String,
        icon: String,
        tint: Color,
        danger: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
            Text(label)
                .font(Theme.body(14))
                .foregroundStyle(danger ? Theme.danger : Theme.text)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.muted(0.3))
        }
        .padding(.vertical, 14).padding(.horizontal, 20)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    private func handle(_ row: SettingRow) {
        guard row.label == "Log out" else { return }
        DiscourseLogin.shared.signOut()
        app.overlay = nil
        app.onboardingDone = false
        app.isGuest = false
        app.authed = false
    }
}

// MARK: - Nodeloc Pro

struct ProOverlay: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app

        VStack(spacing: 0) {
            OverlayHeader(title: "Nodeloc Pro")
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Go further on NODELOC.").font(Theme.heading(32)).padding(.bottom, 6)
                    Text("No ads, custom badges, and priority in the queue.")
                        .font(Theme.body(13)).foregroundStyle(Theme.muted(0.75))
                        .padding(.bottom, 18)

                    VStack(alignment: .leading, spacing: 8) {
                        proFeature("Ad-free browsing")
                        proFeature("Animated profile badge")
                        proFeature("Early access to new Nodes")
                    }
                    .padding(.bottom, 18)

                    SegmentedControl(
                        selection: $app.plan,
                        options: [(.monthly, "Monthly"), (.yearly, "Yearly · save 33%")]
                    )
                    .padding(.bottom, 16)

                    // Price
                    HStack(alignment: .firstTextBaseline) {
                        Text(app.planPrice).font(Theme.heading(26, weight: .semibold))
                        Spacer()
                        Text(app.planPeriod).font(Theme.body(12)).foregroundStyle(Theme.muted(0.55))
                    }
                    .padding(Theme.space3)
                    .frame(maxWidth: .infinity)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
                    .padding(.bottom, 18)

                    // Payment method
                    HStack(spacing: Theme.space3) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Theme.divider, lineWidth: 1)
                            .background(Theme.surface)
                            .frame(width: 26, height: 18)
                            .overlay(Rectangle().fill(Theme.neutral500).frame(height: 2.5).padding(.horizontal, 3), alignment: .center)
                        Text("•••• 4242").font(Theme.body(13))
                        Spacer()
                        Button("Edit") {}.buttonStyle(GhostButtonStyle())
                    }
                    .padding(Theme.space3)
                    .frame(maxWidth: .infinity)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
                    .padding(.bottom, 18)

                    Button("Subscribe") {}
                        .buttonStyle(PrimaryButtonStyle(block: true))

                    Text("Cancel anytime. Renews automatically.")
                        .font(Theme.body(11)).foregroundStyle(Theme.muted(0.45))
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 10)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    private func proFeature(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.success)
            Text(text).font(Theme.body(13))
        }
    }
}
