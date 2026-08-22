//
//  ComposeOverlay.swift
//  nodeloc
//
//  The post composer: rich text, node selection, media, polls, red envelopes,
//  and lotteries.
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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
            // Reposting a topic pre-fills the title and body for editing.
            if let prefillTitle = app.composePrefillTitle {
                title = prefillTitle
                app.composePrefillTitle = nil
            }
            if let prefillBody = app.composePrefillBody {
                bodyText = AttributedString(prefillBody)
                app.composePrefillBody = nil
                focusedField = .body
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
