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
        case .link: AppString("添加链接")
        case .image: AppString("添加图片链接")
        case .video: AppString("添加视频链接")
        }
    }

    var message: String {
        switch self {
        case .link: AppString("选中文字会变成链接；没有选中内容时会插入一个可编辑的链接标题。")
        case .image: AppString("先用图片链接占位，发布时会转成 Discourse 图片语法。")
        case .video: AppString("先用视频链接占位，发布时会转成 Discourse 链接。")
        }
    }

    var fallbackLabel: String {
        switch self {
        case .link: AppString("链接标题")
        case .image: AppString("图片")
        case .video: AppString("视频")
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
    /// How to dismiss. Nil means this was presented the usual way (through
    /// `app.overlay = .compose`) and closing means clearing that.
    ///
    /// A screen that is *itself* inside a full-screen cover has to present the
    /// composer locally and pass its own dismissal: `app.overlay` renders in
    /// `MainView`, behind the cover, so the composer would open where nobody
    /// can see it. It still takes focus, so the keyboard rises over a page that
    /// appears unchanged — the same shape of bug as the reader's, see
    /// `PostDetailOverlay.onClose`.
    var onClose: (() -> Void)?

    @Environment(AppState.self) private var app
    @State private var store = ComposeStore()
    @State private var title = ""
    @State private var bodyText = AttributedString()
    @State private var selectedCommunity: SidebarNodeSummary?
    @State private var showsNodePicker = false
    /// The rich editor's selection, boxed because its type is iOS 26 only.
    @State private var selectionBox = RichSelectionBox()
    /// The plain editor's selection. `TextSelection` is iOS 18, so no box.
    @State private var plainSelection: TextSelection?
    /// `@user` / `#node` completion for the body.
    @State private var mentions = MentionAutocompleteStore()
    /// The topic this post quotes, shown as the card it will cook into.
    @State private var repostTopic: AppState.RepostTopic?
    /// Set when the composer is editing an existing topic rather than writing a
    /// new one: same screen, different verb.
    @State private var editTarget: AppState.TopicEdit?
    /// Editing markdown as source rather than as rich text. Set for a post whose
    /// body carries syntax the rich editor can't represent — applying attributes
    /// to that text would produce `**## 标题**`, and nothing here would ever put
    /// the syntax back together.
    @State private var isSourceMode = false
    /// Reference rendering of the version being edited.
    @State private var showsRenderedReference = true
    /// Height the body text needs, measured from a hidden copy of it.
    @State private var bodyMeasuredHeight: CGFloat = 0
    /// The bottom inset's measured height: toolbar, plus the mention bar when
    /// one is open.
    @State private var bottomBarHeight: CGFloat = 0
    /// Room left below the editor's top edge inside the scroll view.
    @State private var bodyAvailableHeight: CGFloat = 0
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
            VStack(spacing: 0) {
                // Pinned above the toolbar rather than placed after the editor.
                //
                // It used to live in the scroll content, with the editor sized to
                // leave room for it — arithmetic that was wrong twice, because it
                // rests on `bounds(of: .scrollView)` still describing the visible
                // region once the keyboard is up. Here there is nothing to
                // compute: the card is *part of* the inset the editor is laid out
                // against, so neither the toolbar nor the keyboard can cover it,
                // and it reads as what it is — an attachment on the draft.
                if let repostTopic {
                    RepostOneboxCard(topic: repostTopic) {
                        withAnimation(.quick) { self.repostTopic = nil }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                    .background(Theme.bg)
                }

                // Above the toolbar, directly under the keyboard's edge: the
                // suggestion has to be reachable without covering the draft.
                if !mentions.suggestions.isEmpty {
                    MentionSuggestionBar(suggestions: mentions.suggestions) { pickMention($0) }
                }
                composeToolbar
                    .padding(.horizontal, 16)
                    .padding(.bottom, Self.toolbarBottomPadding)
            }
            // Measured, not assumed: this block is the toolbar *and* the mention
            // bar when one is showing, and whatever is above it has to clear
            // both. See `bodyEditorHeight`.
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ComposeBottomBarKey.self,
                        value: proxy.size.height
                    )
                }
            }
            .onPreferenceChange(ComposeBottomBarKey.self) { height in
                bottomBarHeight = height
            }
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
            // A chat transcript is server-rendered markdown ([chat] wrappers and
            // all), so it goes in as source rather than through the rich editor,
            // which would rewrite it.
            if let prefillBody = app.composePrefillBody {
                bodyText = AttributedString(prefillBody)
                isSourceMode = true
                app.composePrefillBody = nil
            }
            if let target = app.composeEditTarget {
                editTarget = target
                app.composeEditTarget = nil
                title = target.title
                bodyText = AttributedString(target.raw)
                isSourceMode = MarkdownSource.needsSourceEditing(target.raw)
                if let categoryID = target.categoryID {
                    Task { selectedCommunity = await NodeCatalog.shared.node(id: categoryID) }
                }
            }
            if let topic = app.composeRepostTopic {
                repostTopic = topic
                app.composeRepostTopic = nil
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
        .alert(pendingLinkKind?.title ?? AppString("添加链接"), isPresented: isLinkPromptPresented) {
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
            AppString("部分内容未创建"),
            isPresented: Binding(
                get: { followUpRetryMessage != nil },
                set: { if !$0 { followUpRetryMessage = nil } }
            )
        ) {
            Button("重试") { retryFollowUps() }
            Button("不了", role: .cancel) {
                followUpRetryMessage = nil
                dismiss()
            }
        } message: {
            Text(followUpRetryMessage ?? "")
        }
    }

    /// Says what mode this is and why, with the published rendering underneath
    /// to edit against — there is no live preview, because Discourse cooks
    /// markdown in the browser and has no server-side endpoint for it.
    @ViewBuilder
    private var sourceModeNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                Text("Markdown 源码编辑")
                    .font(Theme.body(12, weight: .semibold))

                Spacer(minLength: 8)

                if editTarget?.rendered != nil {
                    Button {
                        withAnimation(.quick) { showsRenderedReference.toggle() }
                    } label: {
                        Text(showsRenderedReference ? AppString("隐藏原文") : AppString("查看原文"))
                            .font(Theme.body(12, weight: .semibold))
                    }
                    .buttonStyle(.pressable)
                }
            }
            .foregroundStyle(Theme.accent)

            Text("这篇帖子里有手机端富文本编辑器无法还原的语法（标题、列表、表格、插件等），因此按源码编辑，保存时原样提交。")
                .font(Theme.body(11))
                .foregroundStyle(Theme.muted(0.55))
                .fixedSize(horizontal: false, vertical: true)

            if showsRenderedReference, let rendered = editTarget?.rendered {
                PostContentView(content: rendered, metrics: .body)
                    // Reference only: tapping a link or an image here would
                    // leave the draft.
                    .allowsHitTesting(false)
                    .padding(12)
                    .frame(maxHeight: 220)
                    .clipped()
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.divider, lineWidth: 1)
                    }
            }
        }
        .padding(.bottom, 12)
    }

    /// The floating toolbar's block in the bottom safe-area inset: the capsule
    /// itself plus the padding under it. A constant shared with the toolbar, so
    /// the two can't drift apart.
    private static let toolbarHeight: CGFloat = 46
    private static let toolbarBottomPadding: CGFloat = 8

    /// What the bottom inset actually occupies, measured. Falls back to the
    /// toolbar's own geometry until the first measurement lands.
    private var bottomInsetHeight: CGFloat {
        bottomBarHeight > 0 ? bottomBarHeight : Self.toolbarHeight + Self.toolbarBottomPadding
    }

    /// Fills whatever room is left, and grows past it once the text is longer.
    ///
    /// A fixed floor was wrong in both directions: 320pt left the field short of
    /// the screen with the keyboard down, and pushed the repost card under the
    /// keyboard with it up. This follows the space actually available.
    ///
    /// The reserve has to include the toolbar. `bounds(of: .scrollView)` measures
    /// to the scroll view's own bottom edge, and the toolbar is a
    /// `safeAreaInset` *over* that edge — so sizing the editor to fill down to it
    /// parked the repost card behind the toolbar until you scrolled.
    /// Fills the room above the bottom inset, and grows past it once the text is
    /// longer than that.
    ///
    /// Nothing is reserved for the repost card any more: the card sits *in* the
    /// inset, so the measured `bottomInsetHeight` already accounts for it.
    private var bodyEditorHeight: CGFloat {
        let fill = max(0, bodyAvailableHeight - bottomInsetHeight - 8)
        let floor = max(132, fill)
        return max(floor, bodyMeasuredHeight + 16)
    }

    /// A space when empty, so the measurement is one line rather than zero.
    private var bodyMeasurementText: String {
        let text = String(bodyText.characters)
        return text.isEmpty ? " " : text
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
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34)
            }
            .glassButton(tint: Theme.bg.opacity(0.34), shape: .circle)
            .shadow(color: .black.opacity(0.08), radius: 9, y: 6)

            Button {
                showsNodePicker = true
            } label: {
                HStack(spacing: 6) {
                    Text(selectedCommunity.map { "n/\($0.slug)" } ?? AppString("选择节点"))
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
            .glassButton(tint: Theme.bg.opacity(0.34), shape: .capsule)
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
                        Text(editTarget == nil ? AppString("发帖") : AppString("保存"))
                            .font(Theme.body(15, weight: .semibold))
                    }
                }
                .foregroundStyle(canPost ? Theme.text : Theme.muted(0.38))
                .padding(.horizontal, 14)
                .frame(height: 34)
            }
            .glassButton(tint: Theme.bg.opacity(0.34), shape: .capsule)
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

                if isSourceMode {
                    sourceModeNotice
                }

                ZStack(alignment: .topLeading) {
                    if bodyText.characters.isEmpty {
                        Text("正文文本（可选）")
                            .font(Theme.body(16))
                            .foregroundStyle(Theme.muted(0.62))
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }

                    bodyEditor
                        .font(isSourceMode ? .system(size: 15, design: .monospaced) : Theme.body(16))
                        .foregroundStyle(Theme.text)
                        .scrollContentBackground(.hidden)
                        .background(.clear)
                        .focused($focusedField, equals: .body)
                        // Elastic, not a fixed 320pt: that minimum pushed
                        // anything after the editor — the repost card — below
                        // the keyboard where it couldn't be seen. The height
                        // follows the text, measured by the hidden copy below,
                        // so typing grows the editor and eases the card down.
                        .frame(height: bodyEditorHeight, alignment: .top)
                        // How much room is left below the editor's top edge.
                        // `bounds(of: .scrollView)` is the visible rect in local
                        // coordinates, so its `maxY` *is* the distance from here
                        // to the bottom of what can be seen — and it shrinks and
                        // grows with the keyboard, which is what makes the field
                        // fill the space when the keyboard goes away.
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ComposeBodyRoomKey.self,
                                    value: proxy.bounds(of: .scrollView)?.maxY ?? 0
                                )
                            }
                        }
                        .onPreferenceChange(ComposeBodyRoomKey.self) { room in
                            bodyAvailableHeight = room
                        }
                        .background {
                            // Same font and insets as the editor, so its
                            // measured height is the editor's.
                            Text(bodyMeasurementText)
                                .font(Theme.body(16))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: ComposeBodyHeightKey.self,
                                            value: geometry.size.height
                                        )
                                    }
                                )
                                .hidden()
                        }
                        .onPreferenceChange(ComposeBodyHeightKey.self) { measured in
                            bodyMeasuredHeight = measured
                        }
                        // A token depends on the caret as much as on the text,
                        // so both changes have to re-evaluate it.
                        .onChange(of: bodyText) { _, _ in refreshMentions() }
                        .onChange(of: bodyCaretOffset) { _, _ in refreshMentions() }
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
                        Text(attachment.kind == .image ? AppString("图片已上传") : AppString("视频已上传"))
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
                    .buttonStyle(.pressable)
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
    /// Rich where the system has it, plain where it doesn't.
    @ViewBuilder
    private var bodyEditor: some View {
        if #available(iOS 26.0, *) {
            TextEditor(text: $bodyText, selection: selectionBox.binding)
        } else {
            // Writes back through the same `bodyText` storage everything else
            // reads, so nothing downstream knows which editor is running.
            // Flattening loses no attributes: below 26 none get applied,
            // because `usesMarkdownTokens` sends the buttons down the markdown
            // path instead.
            TextEditor(
                text: Binding(
                    get: { bodyPlainText },
                    set: { bodyText = AttributedString($0) }
                ),
                selection: $plainSelection
            )
        }
    }

    // MARK: @ / # completion

    private var bodyPlainText: String { String(bodyText.characters) }

    /// The caret as a character offset into the body, from whichever editor
    /// is running.
    private var bodyCaretOffset: Int? {
        if #available(iOS 26.0, *) {
            return selectionBox.caretOffset(in: bodyText)
        }
        return plainSelection?.caretOffset(in: bodyPlainText)
    }

    private func refreshMentions() {
        guard let bodyCaretOffset else {
            mentions.clear()
            return
        }
        mentions.update(text: bodyPlainText, caretOffset: bodyCaretOffset)
    }

    /// Spliced rather than rebuilt: the body carries bold, italics and links,
    /// and recreating it from plain text to insert a name would drop them all.
    private func pickMention(_ suggestion: MentionSuggestion) {
        guard let insertion = mentions.insertion(for: suggestion, in: bodyPlainText) else { return }
        let characters = bodyText.characters
        let lower = characters.index(characters.startIndex, offsetBy: insertion.range.lowerBound)
        let upper = characters.index(characters.startIndex, offsetBy: insertion.range.upperBound)
        bodyText.replaceSubrange(lower..<upper, with: AttributedString(insertion.replacement))

        let updated = bodyText.characters
        let caret = min(insertion.caretOffset, updated.count)
        let point = updated.index(updated.startIndex, offsetBy: caret)
        setBodySelection(point..<point)
    }

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
                    toggleInlineIntent(.stronglyEmphasized, placeholder: AppString("加粗文字"))
                }
                toolbarIcon("LucideItalic", isActive: selectionHasInlineIntent(.emphasized)) {
                    toggleInlineIntent(.emphasized, placeholder: AppString("斜体文字"))
                }
                toolbarIcon("LucideStrikethrough", isActive: selectionHasInlineIntent(.strikethrough)) {
                    toggleInlineIntent(.strikethrough, placeholder: AppString("删除线文字"))
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
        .frame(height: Self.toolbarHeight)
        .glassSurface(tint: Theme.bg.opacity(0.42))
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
        .buttonStyle(.pressable)
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
        .buttonStyle(.pressable)
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
        .buttonStyle(.pressable)
        .disabled(store.isSubmitting || blocked)
    }

    private func toolbarColor(disabled: Bool, isActive: Bool) -> Color {
        if disabled { return Theme.muted(0.28) }
        if isActive { return Color(light: 0x3366FF, dark: 0x7EA7FF) }
        return Theme.text
    }

    /// Whether formatting is written as markdown characters rather than as
    /// attributes on the text.
    ///
    /// True in source mode, where the draft is submitted verbatim — and true
    /// below iOS 26, which has no styled editor to hold attributes. The
    /// buttons keep working there: they wrap the selection in `**` the way the
    /// web composer does, through the same branch source mode already used.
    private var usesMarkdownTokens: Bool {
        isSourceMode || !ComposerFormatting.isAvailable
    }

    /// Whether the selection is already a link.
    ///
    /// Only meaningful where attributes exist. On the markdown-token path the
    /// emphasis is characters in the text rather than an attribute on it, so
    /// there is nothing to light the button up from — and claiming otherwise
    /// would be worse than a button that never highlights.
    private var selectionHasLink: Bool {
        guard #available(iOS 26.0, *), !usesMarkdownTokens else { return false }
        return selectionBox.selection.attributes(in: bodyText)[\.link].contains { $0 != nil }
    }

    private func selectionHasInlineIntent(_ intent: InlinePresentationIntent) -> Bool {
        guard #available(iOS 26.0, *), !usesMarkdownTokens else { return false }
        let values = Array(selectionBox.selection.attributes(in: bodyText)[\.inlinePresentationIntent])
        return !values.isEmpty && values.allSatisfy { $0?.contains(intent) == true }
    }

    /// The selected range, from whichever editor is running.
    ///
    /// Every editing action goes through this and `setBodySelection` — which is
    /// why a second editor costs two functions here rather than fifteen.
    private func selectedBodyRange() -> Range<AttributedString.Index> {
        if #available(iOS 26.0, *) {
            switch selectionBox.selection.indices(in: bodyText) {
            case .insertionPoint(let index):
                return index..<index
            case .ranges(let ranges):
                return ranges.ranges.first ?? bodyText.endIndex..<bodyText.endIndex
            @unknown default:
                return bodyText.endIndex..<bodyText.endIndex
            }
        }

        // The plain editor indexes the flattened string, so its offsets have to
        // be walked back into the attributed storage.
        let plain = bodyPlainText
        guard let plainSelection, let caret = plainSelection.caretOffset(in: plain) else {
            return bodyText.endIndex..<bodyText.endIndex
        }
        let count = bodyText.characters.count
        let upper = bodyText.index(bodyText.startIndex, offsetByCharacters: min(caret, count))
        switch plainSelection.indices {
        case .selection(let range) where !range.isEmpty:
            let lower = plain.distance(from: plain.startIndex, to: range.lowerBound)
            return bodyText.index(bodyText.startIndex, offsetByCharacters: min(lower, count))..<upper
        default:
            return upper..<upper
        }
    }

    /// Selects a range in whichever editor is running.
    private func setBodySelection(_ range: Range<AttributedString.Index>) {
        if #available(iOS 26.0, *) {
            selectionBox.selection = range.isEmpty
                ? AttributedTextSelection(insertionPoint: range.lowerBound)
                : AttributedTextSelection(range: range)
            return
        }

        let characters = bodyText.characters
        let lower = characters.distance(from: characters.startIndex, to: range.lowerBound)
        let upper = characters.distance(from: characters.startIndex, to: range.upperBound)
        let plain = bodyPlainText
        guard lower <= plain.count, upper <= plain.count else { return }
        let start = plain.index(plain.startIndex, offsetBy: lower)
        let end = plain.index(plain.startIndex, offsetBy: upper)
        plainSelection = start == end
            ? TextSelection(insertionPoint: start)
            : TextSelection(range: start..<end)
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
            setBodySelection(lower..<upper)
        } else {
            let insertionPoint = bodyText.index(replacementStart, offsetByCharacters: replacement.characters.count)
            setBodySelection(insertionPoint..<insertionPoint)
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
        if usesMarkdownTokens {
            wrapSelection(with: markdownDelimiter(for: intent), placeholder: placeholder)
            return
        }
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
        setBodySelection(range)
        focusedField = .body
    }

    private func markdownDelimiter(for intent: InlinePresentationIntent) -> String {
        if intent.contains(.stronglyEmphasized) { return "**" }
        if intent.contains(.strikethrough) { return "~~" }
        return "*"
    }

    /// Wraps the selection in markdown, or drops in a placeholder already
    /// wrapped when there's nothing selected.
    private func wrapSelection(with delimiter: String, placeholder: String) {
        let range = selectedBodyRange()
        let selected = String(bodyText.characters[range])
        let inner = selected.isEmpty ? placeholder : selected
        let replacement = AttributedString(delimiter + inner + delimiter)
        replaceBodyText(
            in: range,
            with: replacement,
            // Leave the words selected, not the delimiters, so typing replaces
            // the placeholder.
            selecting: delimiter.count..<(delimiter.count + inner.count)
        )
    }

    private func showLinkPrompt(_ kind: ComposeLinkKind) {
        pendingLinkRange = selectedBodyRange()
        pendingLinkKind = kind
        if #available(iOS 26.0, *), !usesMarkdownTokens {
            linkURLText = selectionBox.selection.attributes(in: bodyText)[\.link]
                .compactMap { $0?.absoluteString }
                .first ?? ""
        } else {
            linkURLText = ""
        }
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
        if usesMarkdownTokens {
            // A `.link` attribute would be invisible here and thrown away on
            // save, since the source text is submitted verbatim.
            let selected = String(bodyText.characters[range])
            let label = selected.isEmpty ? ComposeLinkKind.link.fallbackLabel : selected
            replaceBodyText(
                in: range,
                with: AttributedString("[\(label)](\(url.absoluteString))"),
                selecting: 1..<(1 + label.count)
            )
            return
        }

        if range.isEmpty {
            insertLinkedText(ComposeLinkKind.link.fallbackLabel, url: url, in: range, selectingLabel: true)
        } else {
            bodyText[range].link = url
            setBodySelection(range)
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
            store.errorText = AppString("一次最多添加 \(maxImageSelection) 张图片。")
        }

        for item in accepted {
            Task { await ingestPickedImage(item) }
        }
    }

    private func ingestPickedImage(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
            store.errorText = AppString("无法读取所选图片。")
            return
        }
        guard let size = await ImageEditRenderer.pixelSize(of: data) else {
            store.errorText = AppString("无法读取所选图片。")
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
                store.errorText = AppString("无法读取所选视频。")
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
                store.errorText = AppString("无法暂存所选视频。")
                return
            }

            guard let meta = await VideoExporter.metadata(for: localURL) else {
                VideoExporter.discard(localURL)
                store.errorText = AppString("无法读取视频信息。")
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
            videoAttachment?.upload = .failed(AppString("无法读取视频文件。"))
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
            videoAttachment?.posterUpload = .failed(AppString("没有可用的封面帧。"))
            return
        }
        guard let sha1 = attachment.videoSHA1 else {
            // The upload URL wasn't the expected /uploads/.../<sha1>.<ext>
            // shape, so there's no filename that Discourse would match.
            videoAttachment?.posterUpload = .failed(AppString("无法从上传地址解析视频 SHA1，封面已跳过。"))
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
        let template = AppString("\(prefix)AMA:\n\n可以问我：\n• ")
        replaceBodyText(in: range, with: template, selecting: template.count..<template.count)
    }

    private func toggleBulletList() {
        let range = selectedBodyRange()
        if range.isEmpty && bodyText.characters.isEmpty {
            replaceBodyText(in: range, with: AttributedString(bulletMarker))
            return
        }

        let lineRange = bodyLineRange(for: range)
        let lineText = String(bodyText.characters[lineRange])
        if range.isEmpty && lineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            replaceBodyText(in: range, with: AttributedString(bulletMarker))
            return
        }

        let lines = lineText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let contentLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let shouldRemove = !contentLines.isEmpty && contentLines.allSatisfy { line in
            isBulletLine(lineBody(afterIndentIn: line))
        }
        let replacement = lines
            .map { toggledBulletLine($0, removing: shouldRemove) }
            .joined(separator: "\n")

        replaceBodyText(in: lineRange, with: replacement, selecting: 0..<replacement.count)
    }

    /// Rewrites the selected lines' leading `#`s. Level 0 strips them, matching
    /// `applyHeading(0, …)` in the web toolbar.
    private func applyHeading(_ level: Int) {
        // Already literal `#` markers, so this needs no source-mode variant.
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
        wrapSelection(opening: "[spoiler]", closing: "[/spoiler]", placeholder: AppString("剧透内容"))
    }

    private func wrapSmallText() {
        wrapSelection(opening: "<small>", closing: "</small>", placeholder: AppString("小号文字"))
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

    /// What a list line starts with. The rich editor shows a real bullet and the
    /// markdown renderer converts it; source mode is submitted verbatim, so it
    /// has to be markdown already.
    private var bulletMarker: String { isSourceMode ? "- " : "• " }

    private func isBulletLine(_ body: some StringProtocol) -> Bool {
        body.hasPrefix("• ") || (isSourceMode && (body.hasPrefix("- ") || body.hasPrefix("* ")))
    }

    private func toggledBulletLine(_ line: String, removing: Bool) -> String {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
        let indentation = line.prefix { $0 == " " || $0 == "\t" }
        let body = lineBody(afterIndentIn: line)
        if removing {
            return isBulletLine(body)
                ? String(indentation) + String(body.dropFirst(2))
                : line
        }
        if isBulletLine(body) { return line }
        if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("• ") {
            return String(indentation) + bulletMarker + String(body.dropFirst(2))
        }
        return String(indentation) + bulletMarker + body
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
        // Source mode is verbatim: the text *is* the markdown, so it must not go
        // through the rich renderer — which would, among other things, rewrite a
        // line starting with "• " into a list item. Only the blank lines around
        // it are trimmed; leading spaces can be an indented code block.
        let bodyMarkdown = isSourceMode
            ? String(bodyText.characters).trimmingCharacters(in: .newlines)
            : RichTextMarkdownRenderer.markdown(from: bodyText, mediaKindsByURL: [:])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        let mediaMarkdown = mediaAttachments
            .map(\.markdown)
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A poll is plain markup carried by the post body; the red envelope is
        // not, and gets created in a second request after the topic exists.
        let pollMarkup = pollMarkupIfValid()

        // Last, and on a line of its own: that is the only shape Discourse
        // oneboxes, and joining with a blank line keeps it that way whatever the
        // body ends with. Last rather than first so the published post reads in
        // the same order the composer previews — your words, then what you are
        // quoting.
        let repostMarkdown = repostTopic?.url.absoluteString ?? ""

        return [imageMarkdown, videoMarkdown, bodyMarkdown, pollMarkup, mediaMarkdown, repostMarkdown]
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
        if let editTarget {
            save(editTarget)
            return
        }
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
                dismiss()
            case .postedWithFollowUpFailure(let message):
                // The post is live and can't be rolled back — let the user
                // retry rather than dropping the extras silently.
                followUpRetryMessage = message
            }
        }
    }

    /// Saves an edit: the title (and node) belong to the topic, the body to its
    /// first post, so this is two calls on two endpoints — the composer just
    /// presents them as one form.
    private func save(_ target: AppState.TopicEdit) {
        Task {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = composedBodyMarkdown()
            let client = DiscourseClient()
            do {
                if trimmedTitle != target.title || selectedCommunity?.id != target.categoryID {
                    try await client.updateTopic(
                        id: target.topicID,
                        title: trimmedTitle == target.title ? nil : trimmedTitle,
                        categoryID: selectedCommunity?.id == target.categoryID ? nil : selectedCommunity?.id
                    )
                }
                if body != target.raw {
                    try await client.updatePost(id: target.postID, raw: body)
                }
                ToastCenter.shared.show(AppString("已保存修改"))
                dismiss()
            } catch {
                ToastCenter.shared.showError(error)
            }
        }
    }

    /// Dismisses the composer whichever way it was presented.
    private func dismiss() {
        if let onClose {
            onClose()
        } else {
            closeOverlay(app)
        }
    }

    private func retryFollowUps() {
        followUpRetryMessage = nil
        Task {
            if await store.retryFollowUps(redEnvelope: redEnvelope, lottery: lottery) {
                dismiss()
            } else {
                followUpRetryMessage = store.errorText ?? AppString("仍然创建失败。")
            }
        }
    }
}

/// The bottom inset block's height (toolbar + mention bar).
private struct ComposeBottomBarKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ComposeBodyRoomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ComposeBodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Repost

/// The topic a repost quotes, drawn as the card it will cook into.
///
/// Rendered through `PostOneboxView` — the same view the reader uses for a real
/// onebox — so the preview and the published post look alike instead of being
/// two guesses at the same thing. Removable, since a repost with the quote taken
/// out is just a new topic.
private struct RepostOneboxCard: View {
    let topic: AppState.RepostTopic
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.2.squarepath")
                    .font(.system(size: 11, weight: .semibold))
                Text("转发")
                    .font(Theme.body(12, weight: .semibold))
                Spacer(minLength: 8)
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.muted(0.5))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("移除转发的帖子")
            }
            .foregroundStyle(Theme.accent)

            PostOneboxView(onebox: onebox)
                // The card is a preview here, not a link to follow: tapping it
                // in the composer would leave the draft.
                .allowsHitTesting(false)
        }
    }

    private var onebox: PostOnebox {
        PostOnebox(
            url: topic.url.absoluteString,
            title: topic.title,
            descriptionText: topic.excerpt ?? [topic.node, topic.author.map { "@\($0)" }]
                .compactMap { $0 }
                .joined(separator: " · "),
            imageURL: topic.imageURL?.absoluteString,
            faviconURL: nil
        )
    }
}

#Preview("转发") {
    let app = AppState()
    app.authed = true
    app.composePrefillTitle = AppString("隔壁的青春版邀请码一枚（雾）")
    app.composeRepostTopic = AppState.RepostTopic(
        id: 106033,
        title: AppString("隔壁的青春版邀请码一枚（雾）"),
        url: URL(string: "https://www.nodeloc.com/t/topic/106033")!,
        node: "n/lottery",
        author: "xiaibao",
        excerpt: AppString("免费区开启自动续费自动生成0元账单仍需手动点击确认后续期，仅作为提醒。")
    )
    return ComposeOverlay()
        .environment(app)
        .environment(VideoMuteState.shared)
        .environment(VideoPosterStore.shared)
        .environment(EmojiImageStore.shared)
}
