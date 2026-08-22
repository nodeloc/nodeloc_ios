//
//  ReplyComposer.swift
//  nodeloc
//
//  The "加入对话" reply bar at the bottom of a post. A simplified WYSIWYG
//  composer: rich text (real bold/italic/strike, not markdown tokens) exported
//  to markdown on submit, one image upload, and a Klipy GIF picker. Images and
//  GIFs ride as attachment chips since SwiftUI's rich editor can't inline them.
//

import PhotosUI
import SwiftUI

// MARK: - Emphasis attribute

/// A bitmask (bold=1, italic=2, strike=4) stored alongside the rendered font so
/// the exact styling can be recovered when exporting to markdown.
enum EmphasisAttribute: CodableAttributedStringKey {
    typealias Value = Int
    static let name = "nodeloc.emphasis"
}

extension AttributeScopes {
    struct NodelocAttributes: AttributeScope {
        let emphasis: EmphasisAttribute
    }
    var nodeloc: NodelocAttributes.Type { NodelocAttributes.self }
}

extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<AttributeScopes.NodelocAttributes, T>
    ) -> T {
        self[T.self]
    }
}

private enum Emphasis {
    static let bold = 1
    static let italic = 2
    static let strike = 4
}

/// Carries the reply text's natural height up so the editor can auto-grow.
private struct EditorHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ReplyComposer: View {
    /// The exported markdown, owned by the parent (used for submit + clear).
    @Binding var text: String
    let isSubmitting: Bool
    let isAuthenticated: Bool
    let onSubmit: () -> Void

    // Rich text is the source of truth while composing.
    @State private var rich = AttributedString()
    @State private var selection = AttributedTextSelection()
    @State private var attachments: [Attachment] = []

    @FocusState private var focused: Bool
    @State private var mode: Mode = .plain
    @State private var showGiphy = false
    @State private var expanded = false

    // Height / drag.
    @State private var tall = false
    @State private var isDragging = false
    @State private var previewHeight: CGFloat = 0
    @State private var naturalHeight: CGFloat = 44
    private let minHeight: CGFloat = 44
    private let maxHeight: CGFloat = 320
    private let collapseThreshold: CGFloat = 60

    // Media state.
    @State private var pickerItem: PhotosPickerItem?
    @State private var isUploadingImage = false
    @State private var gifQuery = ""
    @State private var gifs: [GifItem] = []
    @State private var isSearchingGifs = false
    @State private var gifSearchTask: Task<Void, Never>?

    private enum Mode { case plain, formatting }

    private var plainText: String { String(rich.characters) }
    private var hasImage: Bool { attachments.contains { !$0.isGif } }

    private var currentHeight: CGFloat {
        if isDragging { return previewHeight }
        return tall ? maxHeight : min(max(minHeight, naturalHeight), maxHeight)
    }

    private var canSubmit: Bool {
        isAuthenticated && !isSubmitting
            && (!plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty)
    }

    var body: some View {
        Group {
            if expanded {
                expandedComposer
            } else {
                collapsedBar
            }
        }
        .background(Theme.bg)
        .onChange(of: expanded) { _, isExpanded in
            focused = isExpanded
            if !isExpanded {
                showGiphy = false
                mode = .plain
                tall = false
            }
        }
        .onChange(of: text) { _, newValue in
            // Parent cleared the draft after a successful send → reset.
            if newValue.isEmpty {
                rich = AttributedString()
                attachments = []
                selection = AttributedTextSelection()
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await uploadImage(item) }
        }
    }

    // MARK: Collapsed bar

    private var collapsedBar: some View {
        Button {
            if isAuthenticated { withAnimation(.quicker) { expanded = true } }
        } label: {
            HStack {
                Text(collapsedText)
                    .font(Theme.body(15))
                    .foregroundStyle(plainText.isEmpty ? Theme.muted(0.45) : Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .disabled(!isAuthenticated)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    private var collapsedText: String {
        if !plainText.isEmpty { return plainText }
        if !attachments.isEmpty { return "已添加 \(attachments.count) 个附件" }
        return isAuthenticated ? "加入对话" : "登录后参与讨论"
    }

    // MARK: Expanded composer

    private var expandedComposer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            dragHandle
            hintLine
            editor
            if !attachments.isEmpty { attachmentRow }
            toolbar
            if showGiphy {
                giphyPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var hintLine: some View {
        HStack(spacing: 0) {
            Text("请在评论时遵守 ")
            Text("社区规则").foregroundStyle(Theme.accent)
            Text(" 评论时。")
        }
        .font(Theme.body(12))
        .foregroundStyle(Theme.muted(0.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var dragHandle: some View {
        Capsule()
            .fill(Theme.divider)
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            previewHeight = tall ? maxHeight : min(max(minHeight, naturalHeight), maxHeight)
                        }
                        let base = tall ? maxHeight : min(max(minHeight, naturalHeight), maxHeight)
                        previewHeight = min(max(minHeight - 30, base - value.translation.height), maxHeight + 20)
                    }
                    .onEnded { value in
                        let travel = value.translation.height
                        withAnimation(.snappy(duration: 0.28)) {
                            isDragging = false
                            if travel > collapseThreshold {
                                expanded = false
                                tall = false
                            } else if travel < -collapseThreshold {
                                tall = true
                            }
                        }
                    }
            )
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if plainText.isEmpty {
                Text(isAuthenticated ? "加入对话" : "登录后参与讨论")
                    .font(Theme.body(15))
                    .foregroundStyle(Theme.muted(0.4))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $rich, selection: $selection)
                .font(Theme.body(15))
                .tint(Theme.accent)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .disabled(!isAuthenticated)
        }
        .frame(height: currentHeight)
        .padding(.horizontal, 12)
        .background {
            Text(plainText.isEmpty ? " " : plainText)
                .font(Theme.body(15))
                .padding(.horizontal, 5)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: EditorHeightKey.self, value: geo.size.height)
                    }
                )
                .hidden()
        }
        .onPreferenceChange(EditorHeightKey.self) { naturalHeight = $0 }
    }

    // MARK: Attachments

    private var attachmentRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        CachedRemoteImage(url: attachment.previewURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Rectangle().fill(Theme.neutral300)
                        }
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white, .black.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .padding(4)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 4) {
            switch mode {
            case .plain: plainTools
            case .formatting: formattingTools
            }
            Spacer(minLength: 8)
            submitButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var plainTools: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.quicker) {
                    showGiphy.toggle()
                    if showGiphy { focused = false }
                }
            } label: {
                Text("GIF")
                    .font(Theme.body(13, weight: .heavy))
                    .foregroundStyle(showGiphy ? Theme.accent : Theme.text)
                    .frame(height: 34)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.plain)
            .disabled(!isAuthenticated || DiscourseConfig.klipyAPIKey.isEmpty)

            PhotosPicker(selection: $pickerItem, matching: .images) {
                Group {
                    if isUploadingImage {
                        ProgressView().tint(Theme.accent)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 17, weight: .medium))
                    }
                }
                .foregroundStyle(hasImage ? Theme.muted(0.35) : Theme.text)
                .frame(width: 34, height: 34)
            }
            .disabled(!isAuthenticated || isUploadingImage || hasImage)

            toolDivider

            Button {
                withAnimation(.quicker) { mode = .formatting }
            } label: {
                Text("Aa")
                    .font(Theme.body(16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 40, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(!isAuthenticated)
        }
    }

    private var formattingTools: some View {
        let active = currentEmphasis
        return HStack(spacing: 2) {
            iconTool("xmark") { withAnimation(.quicker) { mode = .plain } }
            iconTool("bold", isActive: active & Emphasis.bold != 0) { toggleEmphasis(Emphasis.bold) }
            iconTool("italic", isActive: active & Emphasis.italic != 0) { toggleEmphasis(Emphasis.italic) }
            iconTool("strikethrough", isActive: active & Emphasis.strike != 0) { toggleEmphasis(Emphasis.strike) }
        }
    }

    private var submitButton: some View {
        Button {
            text = exportMarkdown()
            onSubmit()
        } label: {
            Group {
                if isSubmitting {
                    ProgressView().tint(Theme.accent)
                } else {
                    Text("回复").font(Theme.body(14, weight: .semibold))
                }
            }
            .foregroundStyle(canSubmit ? Theme.bg : Theme.muted(0.5))
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(canSubmit ? Theme.accent : Theme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
    }

    private func iconTool(_ systemName: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isActive ? Theme.accent : Theme.text)
                .frame(width: 38, height: 34)
                .background(isActive ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var toolDivider: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(width: 1, height: 20)
            .padding(.horizontal, 4)
    }

    // MARK: Rich-text formatting

    private var currentEmphasis: Int {
        selection.typingAttributes(in: rich).emphasis ?? 0
    }

    private func toggleEmphasis(_ flag: Int) {
        let active = (currentEmphasis & flag) != 0
        rich.transformAttributes(in: &selection) { container in
            var mask = container.emphasis ?? 0
            mask = active ? (mask & ~flag) : (mask | flag)
            container.emphasis = mask == 0 ? nil : mask

            var font = Font.system(size: 15)
            if mask & Emphasis.bold != 0 { font = font.bold() }
            if mask & Emphasis.italic != 0 { font = font.italic() }
            container.font = font
            container.strikethroughStyle = (mask & Emphasis.strike != 0) ? Text.LineStyle.single : nil
        }
        focused = true
    }

    /// Serialises the rich text (plus attachments) to Discourse markdown.
    private func exportMarkdown() -> String {
        var out = ""
        for run in rich.runs {
            let piece = String(rich[run.range].characters)
            guard !piece.isEmpty else { continue }
            out += wrapEmphasis(piece, mask: run.emphasis ?? 0)
        }
        var result = out.trimmingCharacters(in: .whitespacesAndNewlines)
        for attachment in attachments {
            result += (result.isEmpty ? "" : "\n\n") + attachment.markdown
        }
        return result
    }

    /// Wraps a run in markdown, keeping surrounding whitespace outside the tokens.
    private func wrapEmphasis(_ text: String, mask: Int) -> String {
        guard mask != 0 else { return text }
        let leading = String(text.prefix { $0 == " " || $0 == "\n" })
        let trailing = String(text.reversed().prefix { $0 == " " || $0 == "\n" }.reversed())
        let core = String(text.dropFirst(leading.count).dropLast(trailing.count))
        guard !core.isEmpty else { return text }
        var wrapped = core
        if mask & Emphasis.strike != 0 { wrapped = "~~\(wrapped)~~" }
        if mask & Emphasis.italic != 0 { wrapped = "*\(wrapped)*" }
        if mask & Emphasis.bold != 0 { wrapped = "**\(wrapped)**" }
        return leading + wrapped + trailing
    }

    // MARK: Giphy panel

    private var giphyPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.5))
                TextField("搜索 GIF…", text: $gifQuery)
                    .font(Theme.body(15))
                    .tint(Theme.accent)
                    .autocorrectionDisabled()
                    .onChange(of: gifQuery) { _, _ in scheduleGifSearch() }
                if isSearchingGifs { ProgressView().tint(Theme.accent) }
                Button {
                    withAnimation(.quicker) { showGiphy = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Theme.surface, in: Capsule())
            .padding(.horizontal, 12)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(gifs) { gif in
                        Button { insertGif(gif) } label: {
                            CachedRemoteImage(url: gif.url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Rectangle().fill(Theme.neutral300)
                            }
                            .frame(width: 130, height: 130)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
            .frame(height: 138)

            if gifs.isEmpty, !isSearchingGifs {
                Text(gifQuery.count < 2 ? "输入关键词搜索 GIF" : "没有找到 GIF")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.muted(0.5))
                    .frame(maxWidth: .infinity)
                    .frame(height: 138)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: Media

    private func uploadImage(_ item: PhotosPickerItem) async {
        isUploadingImage = true
        defer { isUploadingImage = false; pickerItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let ext = isPNG ? "png" : "jpg"
        let mime = isPNG ? "image/png" : "image/jpeg"
        guard let upload = try? await DiscourseClient().uploadComposerMedia(
            data: data,
            fileName: "image-\(UUID().uuidString).\(ext)",
            mimeType: mime
        ), let raw = upload.url, let url = URL(string: raw) else { return }
        attachments.append(Attachment(previewURL: url, markdown: "![image](\(raw))", isGif: false))
    }

    private func scheduleGifSearch() {
        gifSearchTask?.cancel()
        let query = gifQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { gifs = []; return }
        gifSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await searchGifs(query)
        }
    }

    private func searchGifs(_ query: String) async {
        isSearchingGifs = true
        defer { isSearchingGifs = false }
        guard let response = try? await DiscourseClient().klipySearch(query: query) else {
            gifs = []
            return
        }
        gifs = (response.results ?? []).compactMap(GifItem.init)
    }

    private func insertGif(_ gif: GifItem) {
        attachments.append(
            Attachment(
                previewURL: gif.url,
                markdown: "![\(gif.title)|\(gif.width)x\(gif.height)](\(gif.url.absoluteString))",
                isGif: true
            )
        )
        withAnimation(.quicker) { showGiphy = false }
    }

    // MARK: Models

    struct Attachment: Identifiable {
        let id = UUID()
        let previewURL: URL
        let markdown: String
        let isGif: Bool
    }

    struct GifItem: Identifiable {
        let id = UUID()
        let title: String
        let url: URL
        let width: Int
        let height: Int

        init?(_ gif: KlipySearchResponse.KlipyGif) {
            let format = gif.mediaFormats?["gif"] ?? gif.mediaFormats?.values.first
            guard let raw = format?.url, let url = URL(string: raw) else { return nil }
            self.title = gif.title ?? "gif"
            self.url = url
            self.width = format?.dims?.first ?? 0
            self.height = format?.dims?.last ?? 0
        }
    }
}
