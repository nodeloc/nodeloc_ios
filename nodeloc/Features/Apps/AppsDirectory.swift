//
//  AppsDirectory.swift
//  nodeloc
//
//  The apps directory and app detail, including the embedded game web view.
//

import SwiftUI
import WebKit

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
                                withAnimation(.quick) {
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
                withAnimation(.quick) { app.overlay = .appsDirectory }
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
        withAnimation(.expandCollapse) {
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
        .padding(.top, UIApplication.topSafeAreaInset)
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
