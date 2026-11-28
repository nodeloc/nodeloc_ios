//
//  AppsDirectory.swift
//  nodeloc
//
//  The apps directory and app detail, including the embedded game web view.
//

import SwiftUI
import WebKit

// MARK: - Apps

/// Grid of published apps from the discourse-apps directory. A page on the
/// routed page stack (`RoutedPage.Kind.appsDirectory`).
struct AppsDirectoryOverlay: View {
    @Environment(AppState.self) private var app
    @State private var store = AppsDirectoryStore()
    @State private var searching = false
    /// Decides the ‹: the system's once pushed, this page's own at the root.
    var navigation: PageNavigation = .stackRoot
    var onClose: () -> Void = {}

    // 小游戏和应用 (App-iOS-Apps): the games most played this week as large
    // cards, then every game, applet and bot as rows. Data: GET
    // /apps/directory.json (`kind`, `active_users`, logo, description).

    private var games: [DirectoryApp] {
        store.visibleApps.filter { $0.kind == "game" || $0.kind == nil }
            .sorted { ($0.activeUsers ?? 0) > ($1.activeUsers ?? 0) }
    }
    private var applets: [DirectoryApp] { store.visibleApps.filter { $0.kind == "applet" } }
    private var bots: [DirectoryApp] { store.visibleApps.filter { $0.kind == "bot" } }

    // 开始 runs the game here, without its detail page; the age prompt and
    // this game's consent still come first, exactly as on the detail page.
    @State private var launch: GameLaunch?
    @State private var showAgeGate = false
    @State private var consentFor: GameLaunch?
    @State private var startingID: Int?

    private struct GameLaunch: Identifiable {
        let item: DirectoryApp
        let installID: Int
        var id: Int { installID }
    }

    var body: some View {
        page
            .fullScreenCover(item: $launch) { target in
                AppWebViewOverlay(
                    app: target.item,
                    installID: target.installID,
                    url: DiscourseClient().appWebviewURL(installID: target.installID)
                ) { launch = nil }
            }
            .sheet(isPresented: $showAgeGate) { MiniAppAgeGateSheet() }
            .sheet(item: $consentFor) { pending in
                MiniAppConsentSheet(app: pending.item) {
                    MiniAppGate.recordConsent(for: pending.item.slug)
                    consentFor = nil
                    launch = pending
                }
            }
    }

    /// Starts a game from the list. Anything that can't run here (not a web
    /// game, mini apps switched off, no install found) opens its page instead.
    private func start(_ item: DirectoryApp) {
        guard item.isWebview, FeatureFlags.shared.miniAppsEnabled else { app.openApp(item); return }
        startingID = item.id
        Task {
            defer { startingID = nil }
            guard let installID = await AppDetailOverlay.resolveInstallID(for: item) else {
                app.openApp(item)
                return
            }
            guard MiniAppGate.isAgeSatisfied else { showAgeGate = true; return }
            let pending = GameLaunch(item: item, installID: installID)
            guard MiniAppGate.hasConsented(to: item.slug) else { consentFor = pending; return }
            launch = pending
        }
    }

    private var page: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text(AppString("发现更多游戏"))
                    .font(Theme.body(28, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                if searching {
                    searchField.padding(.horizontal, 16)
                }

                if store.isLoading && store.apps.isEmpty {
                    skeleton
                } else if store.visibleApps.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Theme.textFaint)
                        Text(store.errorText ?? AppString("没有找到应用"))
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textMuted)
                            .multilineTextAlignment(.center)
                        if store.errorText != nil {
                            Button(AppString("重试")) { Task { await reload() } }
                                .font(Theme.body(13, weight: .semibold))
                                .foregroundStyle(Theme.accent700)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    if !games.isEmpty, store.query.isEmpty {
                        sectionHeader(AppString("热门游戏"), note: AppString("按近 7 天玩的人数"))
                        ScrollView(.horizontal) {
                            HStack(spacing: 12) {
                                ForEach(games.prefix(8)) { item in
                                    GameCard(app: item, isStarting: startingID == item.id) { start(item) }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .scrollIndicators(.hidden)
                        Divider().overlay(Theme.divider).padding(.horizontal, 16)
                    }
                    rows(AppString("全部游戏"), store.query.isEmpty ? Array(games.dropFirst(8)) : games, games: true)
                    rows(AppString("小程序"), applets)
                    rows(AppString("机器人"), bots)
                }
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await reload() }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(AppString("小游戏和应用"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if navigation.drawsBackButton {
                ToolbarItem(placement: .topBarLeading) {
                    PageBackButton(action: onClose)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.snappy) { searching.toggle() }
                    if !searching { store.query = "" }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel(AppString("搜索应用"))
            }
        }
        .inPageNavigation(navigation)
        .task { await store.load() }
    }

    /// The store loads once per instance, so a retry starts from a fresh one
    /// (keeping what was typed into the search field).
    private func reload() async {
        let fresh = AppsDirectoryStore()
        fresh.query = store.query
        await fresh.load()
        store = fresh
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
            TextField(AppString("搜索应用"), text: Binding(get: { store.query }, set: { store.query = $0 }))
                .font(Theme.body(15))
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
    }

    private func sectionHeader(_ title: String, note: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Theme.body(19, weight: .bold)).foregroundStyle(Theme.text)
            Spacer()
            if let note {
                Label(note, systemImage: "info.circle")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func rows(_ title: String, _ items: [DirectoryApp], games: Bool = false) -> some View {
        if !items.isEmpty {
            sectionHeader(title, note: nil)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().overlay(Theme.divider).padding(.leading, 76) }
                    // A game's 开始 runs it; tapping the row still opens its page.
                    AppRow(
                        app: item,
                        buttonTitle: games ? AppString("开始") : AppString("打开"),
                        isStarting: startingID == item.id,
                        onButton: { if games { start(item) } else { app.openApp(item) } }
                    ) { app.openApp(item) }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ForEach(["a", "b"], id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 20).fill(Theme.chip).frame(width: 150, height: 250)
                }
            }
            ForEach(["c", "d", "e"], id: \.self) { _ in
                RoundedRectangle(cornerRadius: 12).fill(Theme.chip).frame(height: 56)
            }
        }
        .padding(.horizontal, 16)
        .skeletonPulsing()
    }
}

/// A game in the carousel: its mark on a soft wash of its colour, name, the
/// line about it, how many play it, and 开始.
private struct GameCard: View {
    let app: DirectoryApp
    var isStarting = false
    let onStart: () -> Void

    private var tint: Color {
        let palette: [Color] = [Color(hex: 0xE8772E), Color(hex: 0x5B3FC4), Color(hex: 0x1F3A68), Color(hex: 0x0B7285), Color(hex: 0xB4530B)]
        return palette[abs(app.id) % palette.count]
    }

    var body: some View {
        VStack(spacing: 10) {
            AppLogo(app: app, size: 72, cornerRadius: 36)
                .padding(.top, 4)
            Text(app.name)
                .font(Theme.body(17, weight: .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(app.description ?? " ")
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 36, alignment: .top)
            Divider().overlay(Theme.divider)
            if let users = app.activeUsers {
                Label(AppString("\(users) 人在玩"), systemImage: "person.2")
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            Button(action: onStart) {
                Group {
                    if isStarting { ProgressView().tint(Theme.bg) } else { Text(AppString("开始")) }
                }
                    .font(Theme.body(15, weight: .bold))
                    .foregroundStyle(Theme.bg)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(Theme.text, in: Capsule())
            }
            .buttonStyle(.pressable)
        }
        .padding(14)
        .frame(width: 160)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// One applet, bot or further game as a row.
private struct AppRow: View {
    let app: DirectoryApp
    var buttonTitle = AppString("打开")
    var isStarting = false
    var onButton: (() -> Void)? = nil
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AppLogo(app: app, size: 52, cornerRadius: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(Theme.body(16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let description = app.description, !description.isEmpty {
                    Text(description)
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
                if let users = app.activeUsers, users > 0 {
                    Text(AppString("\(users) 人在用"))
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            Spacer(minLength: 6)
            Button(action: onButton ?? onOpen) {
                Group {
                    if isStarting { ProgressView().controlSize(.small) } else { Text(buttonTitle) }
                }
                    .font(Theme.body(14, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(Theme.chip, in: Capsule())
            }
            .buttonStyle(.pressable)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}

/// One app in the directory grid: logo, name, install count.
private struct AppTile: View {
    let app: DirectoryApp

    var body: some View {
        VStack(spacing: 6) {
            AppLogo(app: app, size: 64, cornerRadius: Theme.cornerLarge)

            Text(app.name)
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 32, alignment: .top)

            if let installs = app.installsCount {
                Text("\(installs) 次安装")
                    .font(Theme.body(10))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// App logo with a lettered fallback.
/// App detail: metadata plus entry points to play or to discuss. A page on
/// the routed page stack (`RoutedPage.Kind.app`), so `/apps/<slug>` opens it
/// from anywhere, a pushed topic included.
struct AppDetailOverlay: View {
    @Environment(AppState.self) private var app
    let slug: String
    var navigation: PageNavigation = .stackRoot
    var onClose: () -> Void = {}
    /// The app, from the opener or fetched by slug.
    @State private var item: DirectoryApp?
    @State private var loadFailed = false
    @State private var installID: Int?
    @State private var isResolving = true
    @State private var webviewTarget: WebviewTarget?
    /// Guideline 4.7.5 — the declared-age prompt.
    @State private var showAgeGate = false
    /// Guideline 4.7.3 — install id held while this app's scopes are reviewed.
    @State private var pendingLaunch: Int?

    /// `fullScreenCover(item:)` needs an Identifiable payload.
    private struct WebviewTarget: Identifiable {
        let url: URL
        let installID: Int
        var id: String { url.absoluteString }
    }

    private let client = DiscourseClient()

    init(
        slug: String,
        preloaded: DirectoryApp? = nil,
        navigation: PageNavigation = .stackRoot,
        onClose: @escaping () -> Void = {}
    ) {
        self.slug = slug
        self.navigation = navigation
        self.onClose = onClose
        _item = State(initialValue: preloaded)
    }

    var body: some View {
        VStack(spacing: 0) {
            if item == nil {
                Group {
                    if loadFailed {
                        EmptyStateView(icon: "square.grid.2x2", message: AppString("没有找到应用"))
                    } else {
                        ProgressView().tint(Theme.accent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

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
        .navigationTitle(item?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if navigation.drawsBackButton {
                ToolbarItem(placement: .topBarLeading) {
                    PageBackButton(action: onClose)
                }
            }
        }
        .inPageNavigation(navigation)
        .task {
            guard item == nil else { return }
            if let fetched = try? await client.app(slug: slug).directoryApp {
                item = fetched
            } else {
                loadFailed = true
            }
        }
        .task(id: item?.id) {
            await resolveInstall()
            if item != nil { autoStartIfAsked() }
        }
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
        .sheet(isPresented: $showAgeGate) {
            MiniAppAgeGateSheet()
        }
        .sheet(isPresented: pendingLaunchPresented) {
            if let item, let installID = pendingLaunch {
                MiniAppConsentSheet(app: item) {
                    MiniAppGate.recordConsent(for: item.slug)
                    pendingLaunch = nil
                    webviewTarget = WebviewTarget(
                        url: client.appWebviewURL(installID: installID),
                        installID: installID
                    )
                }
            }
        }
    }

    private var pendingLaunchPresented: Binding<Bool> {
        Binding(
            get: { pendingLaunch != nil },
            set: { if !$0 { pendingLaunch = nil } }
        )
    }

    private func summary(_ item: DirectoryApp) -> some View {
        HStack(alignment: .top, spacing: 14) {
            AppLogo(app: item, size: 76, cornerRadius: Theme.cornerLarge)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(Theme.heading(21, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)

                if let author = item.author?.username {
                    Text("@\(author)")
                        .font(Theme.body(13, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                }

                HStack(spacing: 6) {
                    if let installs = item.installsCount {
                        Text("\(installs) 次安装")
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.textMuted)
                    }
                    // Who actually plays it, not just who installed it.
                    if let active = item.activeUsers, active > 0 {
                        Text(verbatim: "·").foregroundStyle(Theme.textFaint)
                        Text(AppString("\(active) 人在玩"))
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.textMuted)
                    }
                    if let version = item.versionNumber {
                        Text(verbatim: "·").foregroundStyle(Theme.textFaint)
                        Text(verbatim: "v\(version)")
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.textMuted)
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
            if item.isWebview, FeatureFlags.shared.miniAppsEnabled {
                Button {
                    startGame(item)
                } label: {
                    HStack(spacing: 6) {
                        if isResolving {
                            ProgressView().controlSize(.mini).tint(Theme.onAccent)
                        } else {
                            Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
                        }
                        Text("开始游戏")
                    }
                }
                .buttonStyle(FilledButtonStyle(block: true))
                // The style has no disabled look of its own.
                .opacity(installID == nil ? 0.4 : 1)
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
            .buttonStyle(.pressable)
            .disabled(item.hostTopic?.id == nil)
        }
    }

    /// 开始游戏: guideline 4.7.5 then 4.7.3 — an age has to be declared, and
    /// this app's scopes accepted, before any of its code runs.
    private func startGame(_ item: DirectoryApp) {
        guard let installID else { return }
        guard MiniAppGate.isAgeSatisfied else {
            showAgeGate = true
            return
        }
        guard MiniAppGate.hasConsented(to: item.slug) else {
            pendingLaunch = installID
            return
        }
        webviewTarget = WebviewTarget(
            url: client.appWebviewURL(installID: installID),
            installID: installID
        )
    }

    /// Opened to play (a 最近玩过 row): start once the install resolves. One
    /// that can't run here just stays on its page.
    private func autoStartIfAsked() {
        guard app.autoStartAppSlug == slug else { return }
        app.autoStartAppSlug = nil
        guard let item, item.isWebview, FeatureFlags.shared.miniAppsEnabled, installID != nil else { return }
        startGame(item)
    }

    private func resolveInstall() async {
        guard let item, item.isWebview else {
            isResolving = false
            return
        }
        isResolving = true
        installID = await installID(for: item)
        isResolving = false
    }

    /// The install the app's host post embeds (`data-app-install="8"` in its
    /// HTML) — the one the web's 开始 goes to — read from the post `home_url`
    /// names rather than only the first.
    ///
    /// Read from the topic's raw JSON, not `client.topic(id:)`: the reader's
    /// markup pass (`NodelocMarkup`) replaces every app embed with a "open it
    /// on the web" note, install id included, so the shaped topic never has
    /// one to find and 开始游戏 stayed disabled for every app.
    private func installID(for item: DirectoryApp) async -> Int? {
        await Self.resolveInstallID(for: item)
    }

    /// Shared with the directory's 开始, which runs a game without this page.
    static func resolveInstallID(for item: DirectoryApp) async -> Int? {
        let client = DiscourseClient()
        guard let host = item.hostTopic,
              let data = try? await client.http.send("GET", "api/v1/topics/\(host.id)"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let posts = object["posts"] as? [[String: Any]] else { return nil }
        let wanted = host.postNumber ?? 1
        let post = posts.first { ($0["post_number"] as? Int) == wanted } ?? posts.first
        let html = (post?["html"] as? String) ?? (post?["cooked"] as? String) ?? ""
        return AppsDirectoryStore.installID(inCooked: html)
    }

    /// Opens the app's host topic through the existing post reader.
    private func openDiscussion(_ item: DirectoryApp) {
        guard let topicID = item.hostTopic?.id else { return }
        // Pushed on the page stack this page is on: the reader overlay draws
        // in `MainView`, underneath it.
        app.openPostPage(Post(
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
        ))
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
    @State private var showFlag = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AppWebView(url: url, isLoading: $isLoading)
                // Every way of starting a game ends here: remembered for the
                // sidebar's 最近玩过.
                .onAppear { RecentAppsStore.shared.record(app) }

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
        .sheet(isPresented: $showFlag) {
            if let topicID = app.hostTopic?.id {
                FlagSheet(
                    target: FlagTarget(
                        kind: .topic,
                        id: topicID,
                        authorUsername: app.author?.username
                    )
                )
            }
        }
    }

    @Environment(AppState.self) private var appState

    /// Leaves the game (it can't keep running under the app's pages) and
    /// opens its node.
    private func openDiscussionNode() async {
        guard let topicID = app.hostTopic?.id,
              let data = try? await DiscourseClient().http.send("GET", "api/v1/topics/\(topicID)", query: [URLQueryItem(name: "limit", value: "1")]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let topic = object["topic"] as? [String: Any],
              let slug = topic["node_slug"] as? String, !slug.isEmpty
        else {
            ToastCenter.shared.show(AppString("找不到这个游戏的节点"))
            return
        }
        onClose()
        try? await Task.sleep(for: .milliseconds(350))
        appState.openNode(slug: slug)
    }

    /// Ignoring the author hides their posts and stops notifications from
    /// them — the same call the post reader's 屏蔽作者 makes.
    private func block(_ username: String) async {
        // No post to report: a mini app isn't a topic, so this is the one block
        // that can't carry content to the moderators with it.
        await BlockedUsersStore.shared.blockAndConfirm(username: username, reportingPostID: nil)
        onClose()
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
                // The node the game's host topic is in: apps carry no node of
                // their own, so it is read from that topic (`node_slug`).
                if app.hostTopic?.id != nil {
                    Button {
                        Task { await openDiscussionNode() }
                    } label: {
                        Label(AppString("讨论"), systemImage: "bubble.left.and.bubble.right")
                    }
                }
                // Guideline 4.7.1 requires a way to report the software and to
                // block an abusive author. The report goes to the same
                // moderation queue as any flag, so staff already see it.
                if app.hostTopic?.id != nil {
                    Button {
                        showFlag = true
                    } label: {
                        Label("举报", systemImage: "flag")
                    }
                }
                if let author = app.author?.username {
                    Button(role: .destructive) {
                        Task { await block(author) }
                    } label: {
                        Label("屏蔽作者", systemImage: "hand.raised")
                    }
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
            .buttonStyle(.pressable)
        }
        .padding(.horizontal, 5)
        .frame(height: 34)
        .glassSurface(tint: Theme.bg.opacity(0.5))
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
                        AppLogo(app: app, size: 56, cornerRadius: Theme.cornerLarge)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name)
                                .font(Theme.heading(18, weight: .bold))
                                .foregroundStyle(Theme.text)
                            if let author = app.author?.username {
                                Text("@\(author)")
                                    .font(Theme.body(13, weight: .semibold))
                                    .foregroundStyle(Theme.textMuted)
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
                        factRow(AppString("作者"), app.author?.username ?? "—")
                        factRow(AppString("版本"), app.versionNumber.map { "v\($0)" } ?? "—")
                        factRow(AppString("安装"), "#\(installID)")
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                            .strokeBorder(Theme.divider, lineWidth: 1)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("此应用可以做什么")
                            .font(Theme.heading(15, weight: .semibold))
                            .foregroundStyle(Theme.text)

                        if permissions.isEmpty {
                            Text("除了在此面板上绘制内容以外，什么都不做。")
                                .font(Theme.body(13))
                                .foregroundStyle(Theme.textMuted)
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
                        .foregroundStyle(Theme.textMuted)
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
        .standardSheet()
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
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
            "kv": AppString("为你在此应用内保存数据"),
            "kv.shared": AppString("读取所有人在此应用中共享的内容，例如排行榜"),
            "ui": AppString("显示提示，并将你带到本站的其他页面"),
            "points": AppString("向你发放积分"),
            "realtime": AppString("在有内容变化时通知其他玩家"),
            "schedule": AppString("按计划定时运行"),
            "webview": AppString("绘制自己的界面，而不使用本站的组件")
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

// MARK: - Host topic

extension DirectoryApp {
    /// The topic (and floor) hosting the app, out of `home_url`. The server
    /// writes `/t/{id}?post={n}`, which `hostTopicID` — looking for an
    /// all-digit path segment after `t` — can't read, because the id segment
    /// arrives as "103048?post=1" once split on "/". Parsed as a URL here so
    /// the query is separated first; the older `/t/{slug}/{id}/{n}` form still
    /// works.
    var hostTopic: (id: Int, postNumber: Int?)? {
        guard let homeUrl, let components = URLComponents(string: homeUrl) else { return nil }
        let parts = components.path.split(separator: "/")
        guard let tIndex = parts.firstIndex(of: "t") else { return nil }
        let numbers = parts[parts.index(after: tIndex)...].compactMap { Int($0) }
        guard let id = numbers.first else { return nil }
        let post = components.queryItems?.first { $0.name == "post" }?.value.flatMap(Int.init)
        return (id, post ?? (numbers.count > 1 ? numbers[1] : nil))
    }
}

// MARK: - Guideline 4.7 gates

/// Declared-age prompt, required by guideline 4.7.5 before mini apps are
/// reachable.
///
/// The forum has no birthdate to read, so the age is declared here and kept on
/// the device. A year is enough — asking for a full date would collect more
/// than the check needs.
private struct MiniAppAgeGateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var year: Int = Calendar.current.component(.year, from: Date()) - MiniAppGate.minimumAge

    private var thisYear: Int { Calendar.current.component(.year, from: Date()) }
    private var declaredAge: Int { thisYear - year }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("出生年份", selection: $year) {
                        // 100 years is enough, and the upper bound is this year.
                        ForEach((thisYear - 100)...thisYear, id: \.self) { value in
                            Text(String(value)).tag(value)
                        }
                    }
                } header: {
                    Text("确认年龄")
                } footer: {
                    Text("小程序由社区成员开发，内容分级可能高于本应用。需满 \(MiniAppGate.minimumAge) 岁才能运行。这个信息只保存在本机，不会上传。")
                }

                if declaredAge < MiniAppGate.minimumAge {
                    Section {
                        Label("未满 \(MiniAppGate.minimumAge) 岁，无法运行小程序", systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
            .navigationTitle("年龄确认")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认") {
                        MiniAppGate.declaredBirthYear = year
                        dismiss()
                    }
                    .disabled(declaredAge < MiniAppGate.minimumAge)
                }
            }
        }
    }
}

/// Per-app consent, required by guideline 4.7.3 before any data or permission
/// is shared with an individual mini app. Recorded per slug, so each app is
/// approved on its own rather than once for the whole section.
private struct MiniAppConsentSheet: View {
    let app: DirectoryApp
    let onAgree: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(app.name)
                        .font(Theme.body(15, weight: .semibold))
                    if let author = app.author?.username {
                        LabeledContent("开发者", value: "@\(author)")
                    }
                } footer: {
                    Text("小程序由社区成员开发，运行在沙盒中，无法访问你的账号或设备数据，只能做下面列出的事情。")
                }

                Section("这个小程序可以") {
                    ForEach(scopeDescriptions, id: \.self) { line in
                        Label(line, systemImage: "checkmark.circle")
                            .font(Theme.body(13))
                    }
                }
            }
            .navigationTitle("运行前确认")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("同意并运行") {
                        onAgree()
                        dismiss()
                    }
                }
            }
        }
    }

    /// Falls back to an explicit "nothing but draw" when the server granted no
    /// scopes, rather than showing an empty list that reads like a mistake.
    private var scopeDescriptions: [String] {
        let described: [String: String] = [
            "read_public": AppString("读取所有人在此应用中共享的内容，例如排行榜"),
            "write_own": AppString("为你在此应用内保存数据"),
            "award_points": AppString("向你发放积分"),
            "notify": AppString("在有内容变化时通知其他玩家"),
            "schedule": AppString("按计划定时运行"),
            "custom_ui": AppString("绘制自己的界面，而不使用本站的组件"),
        ]
        let scopes = (app.approvedScopes ?? []).map { described[$0] ?? $0 }
        return scopes.isEmpty ? [AppString("除了在此面板上绘制内容以外，什么都不做。")] : scopes
    }
}
