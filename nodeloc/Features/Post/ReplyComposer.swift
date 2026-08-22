//
//  ReplyComposer.swift
//  nodeloc
//
//  The "加入对话" reply bar at the bottom of a post. A simplified composer:
//  text with a formatting toolbar behind `Aa`, one image upload, and a Klipy
//  GIF picker. No poll / lottery / red envelope — those belong to new topics.
//

import PhotosUI
import SwiftUI

struct ReplyComposer: View {
    @Binding var text: String
    let isSubmitting: Bool
    let isAuthenticated: Bool
    let onSubmit: () -> Void

    @FocusState private var focused: Bool
    @State private var mode: Mode = .plain
    @State private var showGiphy = false
    /// Native auto-grow: the field starts at one line and grows to `maxLines`,
    /// then scrolls. The handle is only for pulling down to collapse.
    private let maxLines = 8
    @State private var pickerItem: PhotosPickerItem?
    @State private var isUploadingImage = false
    @State private var hasImage = false

    // Klipy GIF search state.
    @State private var gifQuery = ""
    @State private var gifs: [GifItem] = []
    @State private var isSearchingGifs = false
    @State private var gifSearchTask: Task<Void, Never>?

    /// Collapsed = just the tappable "加入对话" bar; expanded = full editor.
    @State private var expanded = false
    private let collapseThreshold: CGFloat = 60

    private enum Mode { case plain, formatting }

    private var canSubmit: Bool {
        isAuthenticated && !isSubmitting
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await uploadImage(item) }
        }
    }

    /// The resting bar: tap to open the editor. Shows the in-progress draft when
    /// there is one, so collapsing doesn't hide what you typed.
    private var collapsedBar: some View {
        Button {
            if isAuthenticated { withAnimation(.quicker) { expanded = true } }
        } label: {
            HStack {
                Text(collapsedText)
                    .font(Theme.body(15))
                    .foregroundStyle(text.isEmpty ? Theme.muted(0.45) : Theme.text)
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
        if !text.isEmpty { return text }
        return isAuthenticated ? "加入对话" : "登录后参与讨论"
    }

    private var expandedComposer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.divider).frame(height: 1)

            dragHandle

            hintLine

            editor

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

    /// Pull down past the threshold to collapse back into the resting bar.
    private var dragHandle: some View {
        Capsule()
            .fill(Theme.divider)
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 5)
                    .onEnded { value in
                        if value.translation.height > collapseThreshold {
                            withAnimation(.quicker) { expanded = false }
                        }
                    }
            )
    }

    private var editor: some View {
        TextField(
            isAuthenticated ? "加入对话" : "登录后参与讨论",
            text: $text,
            axis: .vertical
        )
        .font(Theme.body(15))
        .tint(Theme.accent)
        .lineLimit(1...maxLines)
        .focused($focused)
        .disabled(!isAuthenticated)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 4) {
            switch mode {
            case .plain:
                plainTools
            case .formatting:
                formattingTools
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
        HStack(spacing: 2) {
            iconTool("xmark") { withAnimation(.quicker) { mode = .plain } }
            iconTool("bold") { wrap("**", "**") }
            iconTool("italic") { wrap("*", "*") }
            iconTool("strikethrough") { wrap("~~", "~~") }
            iconTool("textformat.size") { prependLine("## ") }
            iconTool("exclamationmark.triangle") { wrap("[spoiler]", "[/spoiler]") }
            iconTool("link") { append("[链接](https://)") }
        }
    }

    private var submitButton: some View {
        Button(action: onSubmit) {
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

    private func iconTool(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: 38, height: 34)
        }
        .buttonStyle(.plain)
    }

    private var toolDivider: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(width: 1, height: 20)
            .padding(.horizontal, 4)
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

    // MARK: Text mutation

    private func wrap(_ prefix: String, _ suffix: String) {
        text = text.isEmpty ? prefix + suffix : prefix + text + suffix
        focused = true
    }

    private func prependLine(_ token: String) {
        text = token + text
        focused = true
    }

    private func append(_ token: String) {
        text += token
        focused = true
    }

    // MARK: Image

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
        ), let url = upload.url else { return }
        append("\n![image](\(url))\n")
        hasImage = true
    }

    // MARK: GIF search

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
        append("\n![\(gif.title)|\(gif.width)x\(gif.height)](\(gif.url.absoluteString))\n")
        withAnimation(.quicker) { showGiphy = false }
    }

    /// A flattened Klipy result: picks whatever format the response provides.
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
