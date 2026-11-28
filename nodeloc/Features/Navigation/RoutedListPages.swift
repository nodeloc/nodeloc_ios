//
//  RoutedListPages.swift
//  nodeloc
//
//  Small list pages that only exist on the routed page stack: a home-feed
//  list on its own (the drawer's 热门) and a group's PM inbox (where
//  group-message links point). Both open from anywhere, a pushed topic
//  included, because the page stack is presented over everything.
//

import SwiftUI

// MARK: - Feed page

/// One `HomeFeed` list as a page, independent of the home tab's preference —
/// opening 热门 from the drawer must not change what the home tab shows.
struct HomeFeedPage: View {
    @Environment(AppState.self) private var app
    let feed: HomeFeed
    let navigation: PageNavigation
    let onClose: () -> Void

    @State private var store: FeedStore
    private var readingMode = NodeReadingModeStore.shared

    init(feed: HomeFeed, navigation: PageNavigation, onClose: @escaping () -> Void) {
        self.feed = feed
        self.navigation = navigation
        self.onClose = onClose
        _store = State(initialValue: FeedStore(fixedFeed: feed))
    }

    var body: some View {
        content
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(feed.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if navigation.drawsBackButton {
                    ToolbarItem(placement: .topBarLeading) {
                        PageBackButton(action: onClose)
                    }
                }
            }
            .inPageNavigation(navigation)
            .task { await store.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading, store.visiblePosts.isEmpty {
            ProgressView()
                .tint(Theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.visiblePosts.isEmpty {
            VStack(spacing: 12) {
                EmptyStateView(
                    icon: store.errorText == nil ? "flame" : "wifi.exclamationmark",
                    message: store.errorText ?? AppString("还没有主题")
                )
                if store.errorText != nil {
                    Button(AppString("重试")) {
                        Task { await store.load() }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.visiblePosts) { post in
                        NodeTopicRow(
                            post: post,
                            mode: readingMode.mode,
                            onTap: { app.openPostPage(post) }
                        )
                    }

                    if store.hasMore {
                        HStack {
                            ProgressView().tint(Theme.accent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .onScrollVisibilityChange(threshold: 0.1) { visible in
                            guard visible else { return }
                            Task { await store.loadMore() }
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .refreshable { await store.load() }
        }
    }
}

// MARK: - Group inbox page

/// A group's private-message inbox. Fetched on its own rather than through
/// `MessageCenterStore`, so opening it doesn't move the 私信 pane's filter
/// underneath.
struct GroupInboxPage: View {
    @Environment(AppState.self) private var app
    let group: String
    let navigation: PageNavigation
    let onClose: () -> Void

    @State private var conversations: [PMConversation] = []
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        content
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(group)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if navigation.drawsBackButton {
                    ToolbarItem(placement: .topBarLeading) {
                        PageBackButton(action: onClose)
                    }
                }
            }
            .inPageNavigation(navigation)
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if !isSignedIn {
            EmptyStateView(icon: "envelope", message: AppString("登录后查看消息"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isLoading, conversations.isEmpty {
            ProgressView()
                .tint(Theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if conversations.isEmpty {
            VStack(spacing: 12) {
                EmptyStateView(
                    icon: errorText == nil ? "envelope" : "wifi.exclamationmark",
                    message: errorText ?? AppString("暂无私信")
                )
                if errorText != nil {
                    Button(AppString("重试")) { Task { await load() } }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(conversations) { conversation in
                        Button {
                            MessageCenterStore.shared.markConversationRead(id: conversation.id)
                            if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
                                conversations[index].unread = false
                            }
                            app.openTopicPage(id: conversation.id)
                        } label: {
                            PMConversationRow(conversation: conversation)
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .refreshable { await load() }
        }
    }

    private var isSignedIn: Bool {
        DiscourseAuth.shared.isAuthenticated && DiscourseAuth.shared.username != nil
    }

    private func load() async {
        guard let username = DiscourseAuth.shared.username else {
            isLoading = false
            return
        }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        let client = DiscourseClient()
        do {
            let response = try await client.groupPrivateMessages(username: username, group: group)
            conversations = MessageCenterStore.conversations(from: response, client: client)
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
