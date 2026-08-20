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

// MARK: - Shared overlay header

private struct OverlayHeader: View {
    @Environment(AppState.self) private var app
    let title: String
    var titleWeight: Font.Weight = .medium

    var body: some View {
        HStack(spacing: 10) {
            Button { dismissOverlay() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
            .buttonBorderShape(.circle)
            Text(title).font(Theme.body(15, weight: titleWeight))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func dismissOverlay() {
        closeOverlay(app)
    }
}

private func closeOverlay(_ app: AppState) {
    if app.overlay == .post {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            app.overlay = nil
        }
    } else {
        withAnimation(.easeInOut(duration: 0.2)) {
            app.overlay = nil
        }
    }
}

private func nodelocSiteURL(_ path: String) -> URL? {
    if path.hasPrefix("http") { return URL(string: path) }
    if path.hasPrefix("/") {
        return URL(string: path, relativeTo: DiscourseConfig.baseURL)?.absoluteURL
    }
    return URL(string: "/\(path)", relativeTo: DiscourseConfig.baseURL)?.absoluteURL
}

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
    @State private var selectedCommunity: Community?
    @State private var bodySelection = AttributedTextSelection()
    @State private var pendingLinkKind: ComposeLinkKind?
    @State private var pendingLinkRange: Range<AttributedString.Index>?
    @State private var linkURLText = ""
    @State private var imageSelection: PhotosPickerItem?
    @State private var videoSelection: PhotosPickerItem?
    @State private var uploadingMediaKind: ComposeLinkKind?
    @State private var mediaAttachments: [ComposeMediaAttachment] = []
    @FocusState private var focusedField: ComposeFocusField?

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
        .onAppear { focusedField = .title }
        .onChange(of: imageSelection) { _, item in
            uploadPickedMedia(item, kind: .image)
        }
        .onChange(of: videoSelection) { _, item in
            uploadPickedMedia(item, kind: .video)
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
    }

    private var canPost: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && selectedCommunity != nil
        && !store.isSubmitting
        && !store.isUploadingMedia
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

            Menu {
                if store.isLoadingCommunities {
                    Text("加载节点中")
                }
                ForEach(store.communities) { community in
                    Button {
                        selectedCommunity = community
                    } label: {
                        if selectedCommunity?.id == community.id {
                            Label(community.name, systemImage: "checkmark")
                        } else {
                            Text(community.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selectedCommunity?.name ?? "选择节点")
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
                    .font(Theme.heading(34, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1...3)
                    .textInputAutocapitalization(.sentences)
                    .focused($focusedField, equals: .title)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .body }

                ZStack(alignment: .topLeading) {
                    if bodyText.characters.isEmpty {
                        Text("正文文本（可选）")
                            .font(Theme.body(22))
                            .foregroundStyle(Theme.muted(0.62))
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $bodyText, selection: $bodySelection)
                        .font(Theme.body(22))
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

                if store.isUploadingMedia {
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

    private var composeToolbar: some View {
        HStack(spacing: 0) {
            toolbarIcon("link", isActive: selectionHasLink) { showLinkPrompt(.link) }
            toolbarMediaPicker(
                "photo",
                selection: $imageSelection,
                matching: .images,
                kind: .image
            )
            toolbarMediaPicker(
                "play.square",
                selection: $videoSelection,
                matching: .videos,
                kind: .video
            )
            toolbarIcon("list.bullet") { toggleBulletList() }
            toolbarText("AMA") { insertAMATemplate() }

            Rectangle()
                .fill(Theme.divider)
                .frame(width: 1, height: 28)
                .padding(.horizontal, 8)

            toolbarText("B", weight: .bold, isActive: selectionHasInlineIntent(.stronglyEmphasized)) {
                toggleInlineIntent(.stronglyEmphasized, placeholder: "加粗文字")
            }
            toolbarIcon("italic", isActive: selectionHasInlineIntent(.emphasized)) {
                toggleInlineIntent(.emphasized, placeholder: "斜体文字")
            }
            toolbarIcon("strikethrough", isActive: selectionHasInlineIntent(.strikethrough)) {
                toggleInlineIntent(.strikethrough, placeholder: "删除线文字")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .glassEffect(.regular.tint(Theme.bg.opacity(0.42)), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 18, y: 10)
    }

    private func toolbarIcon(
        _ systemImage: String,
        disabled: Bool = false,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(toolbarColor(disabled: disabled, isActive: isActive))
                .frame(width: 44, height: 40)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func toolbarMediaPicker(
        _ systemImage: String,
        selection: Binding<PhotosPickerItem?>,
        matching filter: PHPickerFilter,
        kind: ComposeLinkKind
    ) -> some View {
        PhotosPicker(selection: selection, matching: filter, preferredItemEncoding: .compatible) {
            Group {
                if uploadingMediaKind == kind {
                    ProgressView()
                        .tint(Theme.text)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
            }
            .frame(width: 44, height: 40)
        }
        .buttonStyle(.plain)
        .disabled(store.isUploadingMedia || store.isSubmitting)
        .opacity(store.isUploadingMedia && uploadingMediaKind != kind ? 0.38 : 1)
    }

    private func toolbarText(
        _ text: String,
        weight: Font.Weight = .semibold,
        disabled: Bool = false,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(text)
                .font(Theme.heading(text == "AMA" ? 13 : 22, weight: weight))
                .foregroundStyle(toolbarColor(disabled: disabled, isActive: isActive))
                .frame(width: 44, height: 40)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
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

    private func uploadPickedMedia(_ item: PhotosPickerItem?, kind: ComposeLinkKind) {
        guard let item, kind == .image || kind == .video else { return }
        Task {
            await uploadPickedMedia(item, kind: kind)
        }
    }

    private func uploadPickedMedia(_ item: PhotosPickerItem, kind: ComposeLinkKind) async {
        uploadingMediaKind = kind
        defer {
            uploadingMediaKind = nil
            if kind == .image {
                imageSelection = nil
            } else if kind == .video {
                videoSelection = nil
            }
        }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                store.errorText = kind == .image ? "无法读取所选图片。" : "无法读取所选视频。"
                return
            }

            let fileInfo = mediaFileInfo(for: item, kind: kind)
            guard let upload = await store.uploadMedia(
                data: data,
                fileName: fileInfo.fileName,
                mimeType: fileInfo.mimeType
            ) else {
                return
            }

            guard let composerURLString = upload.composerURLString else {
                store.errorText = "上传成功，但没有拿到媒体地址。"
                return
            }

            mediaAttachments.append(
                ComposeMediaAttachment(
                    kind: kind,
                    label: upload.displayFilename,
                    composerURLString: composerURLString,
                    previewURL: previewURL(for: upload)
                )
            )
        } catch {
            store.errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func mediaFileInfo(for item: PhotosPickerItem, kind: ComposeLinkKind) -> (fileName: String, mimeType: String) {
        let type = preferredMediaContentType(for: item, kind: kind)
        let fileExtension = type.preferredFilenameExtension ?? (kind == .image ? "jpg" : "mov")
        let mimeType = type.preferredMIMEType ?? (kind == .image ? "image/jpeg" : "video/quicktime")
        let fileName = "nodeloc-\(kind.rawValue)-\(UUID().uuidString).\(fileExtension)"
        return (fileName, mimeType)
    }

    private func preferredMediaContentType(for item: PhotosPickerItem, kind: ComposeLinkKind) -> UTType {
        switch kind {
        case .image:
            item.supportedContentTypes.first { $0.conforms(to: .image) } ?? .jpeg
        case .video:
            item.supportedContentTypes.first { $0.conforms(to: .movie) } ?? .movie
        case .link:
            .data
        }
    }

    private func previewURL(for upload: DiscourseUpload) -> URL? {
        guard let urlString = upload.url else { return nil }
        if urlString.hasPrefix("http") {
            return URL(string: urlString)
        }
        if urlString.hasPrefix("/") {
            return URL(string: urlString, relativeTo: DiscourseConfig.baseURL)?.absoluteURL
        }
        return URL(string: urlString)
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

    private func composedBodyMarkdown() -> String {
        let bodyMarkdown = RichTextMarkdownRenderer.markdown(from: bodyText, mediaKindsByURL: [:])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mediaMarkdown = mediaAttachments
            .map(\.markdown)
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if bodyMarkdown.isEmpty { return mediaMarkdown }
        if mediaMarkdown.isEmpty { return bodyMarkdown }
        return "\(bodyMarkdown)\n\n\(mediaMarkdown)"
    }

    private func submit() {
        Task {
            if await store.submit(title: title, body: composedBodyMarkdown(), community: selectedCommunity) {
                closeOverlay(app)
            }
        }
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
            ForEach(store.apps.prefix(5)) { app in
                sidebarImageRow(
                    title: app.name,
                    subtitle: "应用",
                    imageURL: app.logoURL,
                    fallbackIcon: "cube.fill",
                    tint: Theme.accent,
                    badge: nil
                ) {
                    perform(.open(app.url ?? "/apps/\(app.slug)"))
                }
            }
            sidebarMenuRow(
                SidebarMenuItem(title: "浏览全部应用", subtitle: "Apps On NodeLoc", icon: "gamecontroller.fill", action: .open(store.appsBrowseURL))
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
}

// MARK: - Browse nodes

private struct NodeCardPair: Identifiable {
    let first: SidebarNodeSummary
    let second: SidebarNodeSummary?

    var id: Int { first.id }
}

struct BrowseNodesOverlay: View {
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var store = NodeBrowseStore()
    @State private var query = ""
    @State private var showsSearch = false
    @State private var showsGroupList = false
    private let headerIconFrame: CGFloat = 34
    private let headerContentHeight: CGFloat = 56

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
                Button { handleBack() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .frame(width: headerIconFrame, height: headerIconFrame)
                }
                .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
                .buttonBorderShape(.circle)
                .shadow(color: .black.opacity(0.08), radius: 9, y: 6)

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
                .font(Theme.heading(20, weight: .semibold))
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
                .font(Theme.heading(20, weight: .semibold))
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
                .font(Theme.body(16, weight: .medium))
                .foregroundStyle(isSelected ? Theme.bg : Theme.text)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 36)
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
                        .font(Theme.heading(18, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(memberText(for: node))
                        .font(Theme.body(13, weight: .medium))
                        .foregroundStyle(Theme.muted(0.62))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                joinButton(for: node)
            }

            Text(node.description)
                .font(Theme.body(13))
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
                        .font(Theme.heading(18, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(memberText(for: node))
                        .font(Theme.body(13, weight: .medium))
                        .foregroundStyle(Theme.muted(0.62))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                joinButton(for: node)
            }

            Text(node.description)
                .font(Theme.body(13))
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
                .font(Theme.body(18, weight: .semibold))
                .foregroundStyle(Theme.muted(0.62))
                .monospacedDigit()
                .frame(width: 34, height: 44, alignment: .center)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    NodeSummaryIcon(node: node, size: 44, cornerRadius: 22)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName(for: node))
                            .font(Theme.heading(19, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Text(memberText(for: node))
                            .font(Theme.body(14, weight: .medium))
                            .foregroundStyle(Theme.muted(0.62))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    joinButton(for: node)
                }

                Text(node.description)
                    .font(Theme.body(14))
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

    private func joinButton(for node: SidebarNodeSummary) -> some View {
        Button {
            openNode(node)
        } label: {
            Text(node.isJoined ? "已加入" : "加入")
                .font(Theme.body(15, weight: .semibold))
                .foregroundStyle(Theme.bg)
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(Theme.text, in: Capsule())
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
        guard let url = nodelocSiteURL(node.url ?? "/n/\(node.slug)") else { return }
        openURL(url)
        closeOverlay(app)
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

private struct NodeSummaryIcon: View {
    let node: SidebarNodeSummary
    var size: CGFloat = 42
    var cornerRadius: CGFloat = 13

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if let logoURL = node.logoURL {
                AsyncImage(url: logoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(nodeAccentColor(node.colorHex).opacity(0.16), in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Theme.divider, lineWidth: 1)
        }
    }

    private var fallback: some View {
        Text(node.name.first.map(String.init) ?? "#")
            .font(Theme.heading(size * 0.36, weight: .bold))
            .foregroundStyle(nodeAccentColor(node.colorHex))
            .frame(width: size, height: size)
    }
}

private func nodeAccentColor(_ hex: String) -> Color {
    let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard let value = UInt32(cleaned, radix: 16) else { return Theme.accent }
    return Color(hex: value)
}

extension Color {
    static let neutral900Scrim = Theme.neutral900.opacity(0.55)
}

// MARK: - Public profile

private struct PublicProfileOverlay: View {
    let target: UserProfileTarget
    let onClose: () -> Void
    @State private var store = PublicProfileStore()

    var body: some View {
        VStack(spacing: 0) {
            profileNav

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    profileHero
                    profileBadges
                    profileCategories
                    profileActivity
                }
                .padding(.bottom, 34)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.bg.ignoresSafeArea())
        .task(id: target.id) { await store.load(target: target) }
    }

    private var profileNav: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(light: 0x2F6DF6, dark: 0x7EA7FF))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Public Profile")
                .font(Theme.heading(18, weight: .semibold))
                .foregroundStyle(Theme.text)

            Spacer()

            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Theme.bg)
    }

    private var profileHero: some View {
        VStack(spacing: 0) {
            profileBanner
                .frame(height: 188)

            profileCard
                .padding(.horizontal, 16)
                .offset(y: -58)
                .padding(.bottom, -58)
        }
    }

    @ViewBuilder
    private var profileBanner: some View {
        if let backgroundURL = store.backgroundURL {
            AsyncImage(url: backgroundURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    profileBannerFallback
                }
            }
            .frame(maxWidth: .infinity)
            .clipped()
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

            VStack(spacing: 3) {
                if store.displayName != store.username {
                    Text(store.displayName)
                        .font(Theme.heading(21, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                }

                HStack(spacing: 5) {
                    Text("@")
                        .font(Theme.heading(22, weight: .bold))
                        .foregroundStyle(Color(light: 0x2F6DF6, dark: 0x7EA7FF))
                    Text(store.username)
                        .font(Theme.heading(20, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 17, height: 17)
                        .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 2))
                }
            }

            HStack(spacing: 8) {
                profilePill(store.lastSeen, dot: true)
                profilePill(store.joined)
            }

            if !store.roles.isEmpty {
                wrappingChips(store.roles) { role in
                    profileChip(role, color: roleColor(role))
                }
            }

            if let title = store.title, !title.isEmpty {
                Text(title)
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
            }

            if !store.bio.isEmpty {
                Text(store.bio)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.text.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
            }

            profileMeta

            HStack(spacing: 10) {
                Button {} label: {
                    Label("Message", systemImage: "envelope.badge")
                        .font(Theme.body(17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(light: 0x2F6DF6, dark: 0x2F6DF6))

                Button {} label: {
                    Label("Following", systemImage: "checkmark.circle")
                        .font(Theme.body(17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.bordered)
                .tint(Theme.success)
            }
            .padding(.top, 4)

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
        .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 18, y: 10)
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

    private var profileBadges: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionKicker(text: "BADGES · \(max(store.badges.count, 0))")
                .foregroundStyle(Theme.muted(0.62))

            if store.badges.isEmpty {
                Text("No badges yet")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.muted(0.48))
            } else {
                wrappingChips(store.badges) { badge in
                    profileChip(badge, color: Color(light: 0xF4C400, dark: 0xF8D34B), icon: "shield.fill")
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var profileCategories: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionKicker(text: "TOP CATEGORIES")
                .foregroundStyle(Theme.muted(0.62))

            wrappingChips(store.topCategories.map(\.name)) { name in
                profileChip(name.replacingOccurrences(of: "n/", with: ""), color: Theme.accent, icon: "circle.fill")
            }
        }
        .padding(.horizontal, 16)
    }

    private var profileActivity: some View {
        VStack(spacing: 0) {
            HStack {
                ForEach(["Topics", "Replies", "Likes"], id: \.self) { item in
                    VStack(spacing: 10) {
                        Text(item)
                            .font(Theme.body(15, weight: .semibold))
                            .foregroundStyle(item == "Topics" ? Theme.text : Theme.muted(0.58))
                        Rectangle()
                            .fill(item == "Topics" ? Color(light: 0x2F6DF6, dark: 0x7EA7FF) : .clear)
                            .frame(height: 3)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 12)

            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)

            HStack(spacing: 8) {
                ForEach(Array(store.stats.enumerated()), id: \.offset) { _, stat in
                    VStack(spacing: 2) {
                        Text(stat.value)
                            .font(Theme.heading(18, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text(stat.label)
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.muted(0.5))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
            }
        }
        .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        )
        .padding(.horizontal, 16)
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

    private func wrappingChips<Data: RandomAccessCollection, Content: View>(
        _ data: Data,
        @ViewBuilder content: @escaping (Data.Element) -> Content
    ) -> some View where Data.Element: Hashable {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
            ForEach(Array(data), id: \.self) { item in
                content(item)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
    }

    private let readerTopInset: CGFloat = 62
    private let readerHeaderControlHeight: CGFloat = 34
    private let readerNodePillWidth: CGFloat = 104
    private let readerHeaderHorizontalInset: CGFloat = 16
    private let readerHeaderGlassTint = Theme.bg.opacity(0.34)
    private let readerHeaderShadow = Color.black.opacity(0.08)

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

                Text(topic.body.isEmpty ? post.excerpt : topic.body)
                    .font(Theme.body(16))
                    .lineSpacing(6)
                    .foregroundStyle(Theme.text.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)

                if topic.isLoading && topic.body.isEmpty {
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

                if let url = post.imageURL {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Theme.neutral300
                    }
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
                    .padding(.top, 18)
                } else if post.hasImage {
                    ImagePlaceholder()
                        .frame(height: 180)
                        .padding(.top, 18)
                }

                postActions(for: post)
                    .padding(.top, 20)

                repliesSection(for: post)
                    .padding(.top, 28)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                            isCollapsed: collapsedCommentIDs.contains(comment.id)
                        ) {
                            toggleCollapse(comment)
                        } onOpenAuthor: { target in
                            openProfile(target)
                        }
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
                    Text(comment.text)
                        .font(Theme.body(14))
                        .lineSpacing(5)
                        .foregroundStyle(Theme.text.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)

                    actionBar
                }
            }
            .padding(.leading, contentLeading)
            .padding(.vertical, Self.verticalPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
